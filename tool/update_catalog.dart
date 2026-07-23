import 'dart:convert';
import 'dart:io';

import 'package:catalog_scraper/catalog_scraper.dart';

const _schemaVersion = 1;
const _minimumPageCount = 40;
const _minimumEpisodeCount = 300;
const _siteRoot = 'https://sites.google.com/view/labibliotecaelementalninjago/';
const _temporaryPilotArtworkVersion = 'pilot4-test-20260723';
const _temporaryPilotSeasonId = 'ninjago/piloto-prueba-remota';
const _temporaryPilotArtworkPath =
    'thumbnails/1Cy_Bhqz9Tvt9QHoKYLEbVZz-RLaaTMkr.jpg';

Future<void> main() async {
  final projectDirectory = Directory.current;
  final publicDirectory = Directory('${projectDirectory.path}/public');
  final coversDirectory = Directory('${publicDirectory.path}/covers');
  final thumbnailsDirectory = Directory('${publicDirectory.path}/thumbnails');
  await publicDirectory.create(recursive: true);
  await coversDirectory.create(recursive: true);
  await thumbnailsDirectory.create(recursive: true);

  final siteRoot = Uri.parse(_siteRoot);
  final fetcher = _IoHtmlFetcher();
  final imageClient = HttpClient()
    ..userAgent = 'NinjaFlix catalog publisher/1.0'
    ..connectionTimeout = const Duration(seconds: 30);

  try {
    stdout.writeln('Consultando Biblioteca Elemental...');
    final catalog = await CatalogCrawler(
      fetcher: fetcher,
      parser: GoogleSitesPageParser(siteRoot: siteRoot),
    ).crawl(siteRoot.resolve('inicio'));

    _validateCatalog(catalog);

    final imageResult = await _downloadMissingThumbnails(
      catalog: catalog,
      outputDirectory: thumbnailsDirectory,
      client: imageClient,
    );
    if (imageResult.failedEpisodes.isNotEmpty) {
      throw StateError(
        'No se pudieron guardar localmente las miniaturas nuevas de: '
        '${imageResult.failedEpisodes.join(', ')}',
      );
    }

    final publishedLogicalHash = _publishedCatalogLogicalHash(
      catalog.logicalHash,
    );
    final version =
        '$_schemaVersion:$publishedLogicalHash:${catalog.locatorHash}';
    final manifestFile = File('${publicDirectory.path}/manifest.json');
    final previousVersion = await _readPublishedVersion(manifestFile);

    if (previousVersion == version) {
      stdout.writeln(
        'El catálogo no cambió. '
        'Miniaturas existentes: ${imageResult.existing}; '
        'nuevas: ${imageResult.downloaded}.',
      );
      return;
    }

    final generatedAt = catalog.fetchedAt.toUtc().toIso8601String();
    final catalogDocument = _catalogDocument(
      catalog: catalog,
      generatedAt: generatedAt,
      coversDirectory: coversDirectory,
      thumbnailsDirectory: thumbnailsDirectory,
    );
    final catalogText = const JsonEncoder.withIndent(
      '  ',
    ).convert(catalogDocument);
    final catalogBytes = utf8.encode('$catalogText\n');
    final catalogFile = File('${publicDirectory.path}/catalog.json');
    await catalogFile.writeAsBytes(catalogBytes, flush: true);

    final imageCount = await thumbnailsDirectory
        .list()
        .where((entry) => entry is File)
        .length;
    final manifestDocument = <String, Object?>{
      'schemaVersion': _schemaVersion,
      'catalogVersion': version,
      'generatedAt': generatedAt,
      'catalogPath': 'catalog.json',
      'catalogBytes': catalogBytes.length,
      'logicalHash': publishedLogicalHash,
      'locatorHash': catalog.locatorHash,
      'seriesCount': catalog.series.length,
      'seasonCount': catalog.series.fold<int>(
        0,
        (total, series) => total + series.seasons.length,
      ),
      'episodeCount': catalog.episodeCount,
      'pageCount': catalog.visitedPageCount,
      'imageCount': imageCount,
    };
    final manifestText = const JsonEncoder.withIndent(
      '  ',
    ).convert(manifestDocument);
    await manifestFile.writeAsString('$manifestText\n', flush: true);

    stdout.writeln(
      'Catálogo publicado localmente: ${catalog.episodeCount} videos, '
      '${catalog.visitedPageCount} páginas y $imageCount miniaturas.',
    );
  } finally {
    fetcher.close();
    imageClient.close(force: true);
  }
}

void _validateCatalog(ScrapedCatalog catalog) {
  final failures = <String>[];
  if (!catalog.crawlComplete) {
    failures.add('el rastreo no terminó completamente');
  }
  if (catalog.failedPageUrls.isNotEmpty) {
    failures.add('${catalog.failedPageUrls.length} páginas fallaron');
  }
  if (catalog.visitedPageCount < _minimumPageCount) {
    failures.add(
      'solo se encontraron ${catalog.visitedPageCount} páginas '
      '(mínimo $_minimumPageCount)',
    );
  }
  if (catalog.episodeCount < _minimumEpisodeCount) {
    failures.add(
      'solo se encontraron ${catalog.episodeCount} videos '
      '(mínimo $_minimumEpisodeCount)',
    );
  }
  final fatalIssues = catalog.issues.where((issue) => issue.isFatal).toList();
  if (fatalIssues.isNotEmpty) {
    failures.add('${fatalIssues.length} errores fatales');
  }
  final unavailableEpisodes = catalog.series
      .expand((series) => series.seasons)
      .expand((season) => season.episodes)
      .where(
        (episode) =>
            episode.availability == ScrapedAvailability.available &&
            episode.mediaSources.isEmpty,
      )
      .length;
  if (unavailableEpisodes > 0) {
    failures.add('$unavailableEpisodes videos disponibles no tienen fuente');
  }
  if (failures.isNotEmpty) {
    throw StateError(
      'Se conserva la última versión válida porque ${failures.join('; ')}.',
    );
  }
}

Future<_ImageDownloadResult> _downloadMissingThumbnails({
  required ScrapedCatalog catalog,
  required Directory outputDirectory,
  required HttpClient client,
}) async {
  var downloaded = 0;
  var existing = 0;
  final failedEpisodes = <String>[];
  final processedIds = <String>{};

  for (final series in catalog.series) {
    for (final season in series.seasons) {
      for (final episode in season.episodes) {
        final source = episode.mediaSource;
        if (source == null || !processedIds.add(source.remoteId)) {
          continue;
        }
        final target = File('${outputDirectory.path}/${source.remoteId}.jpg');
        if (await target.exists() && await target.length() > 0) {
          existing++;
          continue;
        }
        try {
          final request = await client.getUrl(source.thumbnailUrl);
          request.headers.set(HttpHeaders.acceptHeader, 'image/*');
          final response = await request.close();
          if (response.statusCode != HttpStatus.ok) {
            await response.drain<void>();
            throw HttpException(
              'HTTP ${response.statusCode}',
              uri: source.thumbnailUrl,
            );
          }
          final bytes = await response.fold<List<int>>(
            <int>[],
            (buffer, chunk) => buffer..addAll(chunk),
          );
          if (bytes.isEmpty) {
            throw const FormatException('La imagen está vacía.');
          }
          await target.writeAsBytes(bytes, flush: true);
          downloaded++;
          stdout.writeln('+ Miniatura: ${episode.title}');
        } catch (error) {
          stderr.writeln('! ${episode.title}: $error');
          failedEpisodes.add('${season.title} / ${episode.title}');
        }
      }
    }
  }

  return _ImageDownloadResult(
    downloaded: downloaded,
    existing: existing,
    failedEpisodes: failedEpisodes,
  );
}

Map<String, Object?> _catalogDocument({
  required ScrapedCatalog catalog,
  required String generatedAt,
  required Directory coversDirectory,
  required Directory thumbnailsDirectory,
}) {
  return <String, Object?>{
    'schemaVersion': _schemaVersion,
    'generatedAt': generatedAt,
    'source': _siteRoot,
    'logicalHash': _publishedCatalogLogicalHash(catalog.logicalHash),
    'locatorHash': catalog.locatorHash,
    'series': catalog.series
        .map(
          (series) => <String, Object?>{
            'id': series.logicalKey,
            'title': series.title,
            'sortOrder': series.sortOrder,
            'logicalHash': series.logicalHash,
            'seasons': series.seasons
                .map(
                  (season) => _seasonDocument(
                    season,
                    coversDirectory,
                    thumbnailsDirectory,
                  ),
                )
                .toList(growable: false),
          },
        )
        .toList(growable: false),
    'informationPages': catalog.infoPages
        .map(
          (page) => <String, Object?>{
            'id': page.logicalKey,
            'sourceUrl': page.sourceUrl.toString(),
            'title': page.title,
            'body': page.body,
            'sortOrder': page.sortOrder,
            'logicalHash': page.logicalHash,
            'links': page.links
                .map(
                  (link) => <String, String>{
                    'label': link.label,
                    'url': link.url.toString(),
                  },
                )
                .toList(growable: false),
          },
        )
        .toList(growable: false),
  };
}

Map<String, Object?> _seasonDocument(
  ScrapedSeason season,
  Directory coversDirectory,
  Directory thumbnailsDirectory,
) {
  final isTemporaryPilot = season.logicalKey == 'ninjago/piloto';
  final coverName = '${season.logicalKey.replaceAll('/', '__')}.webp';
  final cover = File('${coversDirectory.path}/$coverName');
  final firstThumbnail = season.episodes
      .map(
        (episode) =>
            _localThumbnailPath(episode.mediaSource, thumbnailsDirectory),
      )
      .whereType<String>()
      .firstOrNull;

  return <String, Object?>{
    'id': isTemporaryPilot ? _temporaryPilotSeasonId : season.logicalKey,
    'sourceUrl': season.sourceUrl.toString(),
    'sourcePageKey': season.sourcePageKey,
    'title': season.title,
    'synopsis': season.synopsis,
    'displayNumber': season.displayNumber,
    'canonicalCode': season.canonicalCode,
    'sortOrder': season.sortOrder,
    'logicalHash': isTemporaryPilot
        ? '$_temporaryPilotArtworkVersion-${season.logicalHash}'
        : season.logicalHash,
    'artworkPath': isTemporaryPilot
        ? _temporaryPilotArtworkPath
        : (cover.existsSync() ? 'covers/$coverName' : firstThumbnail),
    'episodes': season.episodes
        .map(
          (episode) => <String, Object?>{
            'id': isTemporaryPilot
                ? episode.logicalKey.replaceFirst(
                    season.logicalKey,
                    _temporaryPilotSeasonId,
                  )
                : episode.logicalKey,
            'number': episode.number,
            'title': episode.title,
            'synopsis': episode.synopsis,
            'kind': episode.kind.name,
            'availability': episode.availability.name,
            'sortOrder': episode.sortOrder,
            'logicalHash': episode.logicalHash,
            'thumbnailPath': _localThumbnailPath(
              episode.mediaSource,
              thumbnailsDirectory,
            ),
            'mediaSources': episode.mediaSources
                .map(
                  (source) => <String, Object?>{
                    'provider': source.provider,
                    'remoteId': source.remoteId,
                    'openUrl': source.openUrl.toString(),
                    'previewUrl': source.previewUrl.toString(),
                    'downloadUrl': source.downloadUrl.toString(),
                    'thumbnailUrl': source.thumbnailUrl.toString(),
                    'thumbnailPath': _localThumbnailPath(
                      source,
                      thumbnailsDirectory,
                    ),
                    'locatorHash': source.locatorHash,
                  },
                )
                .toList(growable: false),
          },
        )
        .toList(growable: false),
  };
}

String _publishedCatalogLogicalHash(String sourceHash) =>
    '$_temporaryPilotArtworkVersion-$sourceHash';

String? _localThumbnailPath(
  ScrapedMediaSource? source,
  Directory thumbnailsDirectory,
) {
  if (source == null) return null;
  final file = File('${thumbnailsDirectory.path}/${source.remoteId}.jpg');
  return file.existsSync() ? 'thumbnails/${source.remoteId}.jpg' : null;
}

Future<String?> _readPublishedVersion(File manifestFile) async {
  if (!await manifestFile.exists()) return null;
  try {
    final document =
        jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>;
    return document['catalogVersion'] as String?;
  } on FormatException {
    return null;
  }
}

final class _ImageDownloadResult {
  const _ImageDownloadResult({
    required this.downloaded,
    required this.existing,
    required this.failedEpisodes,
  });

  final int downloaded;
  final int existing;
  final List<String> failedEpisodes;
}

final class _IoHtmlFetcher implements HtmlFetcher {
  final HttpClient _client = HttpClient()
    ..userAgent = 'NinjaFlix catalog publisher/1.0'
    ..connectionTimeout = const Duration(seconds: 30);

  @override
  Future<String> fetch(Uri uri) async {
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'text/html');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    return response.transform(utf8.decoder).join();
  }

  void close() => _client.close(force: true);
}
