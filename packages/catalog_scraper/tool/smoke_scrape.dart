import 'dart:convert';
import 'dart:io';

import 'package:catalog_scraper/catalog_scraper.dart';

Future<void> main() async {
  final root = Uri.parse(
    'https://sites.google.com/view/labibliotecaelementalninjago/',
  );
  final fetcher = _IoHtmlFetcher();
  final crawler = CatalogCrawler(
    fetcher: fetcher,
    parser: GoogleSitesPageParser(siteRoot: root),
  );

  try {
    final catalog = await crawler.crawl(root.resolve('inicio'));
    stdout.writeln('Páginas: ${catalog.visitedPageCount}');
    stdout.writeln('Series: ${catalog.series.length}');
    stdout.writeln('Capítulos: ${catalog.episodeCount}');
    stdout.writeln('Advertencias: ${catalog.issues.length}');
    final episodes = catalog.series
        .expand((series) => series.seasons)
        .expand((season) => season.episodes)
        .toList(growable: false);
    final missingSynopsis = episodes
        .where((episode) => episode.synopsis.trim().isEmpty)
        .toList(growable: false);
    final missingMedia = episodes
        .where((episode) => episode.mediaSource == null)
        .toList(growable: false);
    final thumbnailDirectory = Directory('../../assets/thumbnails');
    final bundledThumbnailIds = thumbnailDirectory.existsSync()
        ? thumbnailDirectory
              .listSync()
              .whereType<File>()
              .map((file) => file.uri.pathSegments.last.split('.').first)
              .toSet()
        : <String>{};
    final missingBundledThumbnails = episodes
        .where(
          (episode) =>
              episode.mediaSource != null &&
              !bundledThumbnailIds.contains(episode.mediaSource!.remoteId),
        )
        .toList(growable: false);
    stdout.writeln('Sin sinopsis: ${missingSynopsis.length}');
    stdout.writeln('Sin video/miniatura: ${missingMedia.length}');
    stdout.writeln(
      'Videos sin miniatura local: ${missingBundledThumbnails.length}',
    );
    for (final episode in missingBundledThumbnails) {
      stdout.writeln(
        '~ ${episode.title} (${episode.mediaSource!.provider}: ${episode.mediaSource!.remoteId})',
      );
    }
    for (final series in catalog.series) {
      stdout.writeln(
        '- ${series.title}: ${series.seasons.length} colecciones, '
        '${series.seasons.fold(0, (total, season) => total + season.episodes.length)} capítulos',
      );
    }
    for (final issue in catalog.issues.take(20)) {
      stdout.writeln('! ${issue.url}: ${issue.message}');
    }
    for (final series in catalog.series) {
      for (final season in series.seasons) {
        for (final episode in season.episodes) {
          if (episode.synopsis.trim().isEmpty) {
            stdout.writeln(
              '? ${series.title} | ${season.title} | ${episode.number ?? '-'} | ${episode.title}',
            );
          }
        }
      }
    }
  } finally {
    fetcher.close();
  }
}

final class _IoHtmlFetcher implements HtmlFetcher {
  final HttpClient _client = HttpClient()
    ..userAgent = 'NinjaFlix scraper smoke test/0.1';

  @override
  Future<String> fetch(Uri uri) async {
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'text/html');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    return response.transform(utf8.decoder).join();
  }

  void close() => _client.close(force: true);
}
