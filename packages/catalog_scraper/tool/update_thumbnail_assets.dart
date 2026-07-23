import 'dart:convert';
import 'dart:io';

import 'package:catalog_scraper/catalog_scraper.dart';

Future<void> main() async {
  final root = Uri.parse(
    'https://sites.google.com/view/labibliotecaelementalninjago/',
  );
  final fetcher = _IoHtmlFetcher();
  final client = HttpClient()
    ..userAgent = 'NinjaFlix artwork updater/0.1'
    ..connectionTimeout = const Duration(seconds: 20);
  try {
    final catalog = await CatalogCrawler(
      fetcher: fetcher,
      parser: GoogleSitesPageParser(siteRoot: root),
    ).crawl(root.resolve('inicio'));
    final output = Directory('../../assets/thumbnails');
    await output.create(recursive: true);

    var downloaded = 0;
    var existing = 0;
    var unavailable = 0;
    final episodes = catalog.series
        .expand((series) => series.seasons)
        .expand((season) => season.episodes);
    for (final episode in episodes) {
      final source = episode.mediaSource;
      if (source == null) continue;
      final target = File('${output.path}/${source.remoteId}.jpg');
      if (await target.exists()) {
        existing++;
        continue;
      }
      if (!source.thumbnailUrl.hasScheme) {
        unavailable++;
        stdout.writeln('Sin miniatura: ${episode.title}');
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
          throw const FormatException('La respuesta de imagen está vacía.');
        }
        await target.writeAsBytes(bytes, flush: true);
        downloaded++;
        stdout.writeln('+ ${episode.title} -> ${target.path}');
      } catch (error) {
        unavailable++;
        stderr.writeln('! ${episode.title}: $error');
      }
    }

    stdout.writeln(
      'Miniaturas: $downloaded nuevas, $existing existentes, '
      '$unavailable no disponibles.',
    );
  } finally {
    fetcher.close();
    client.close(force: true);
  }
}

final class _IoHtmlFetcher implements HtmlFetcher {
  final HttpClient _client = HttpClient()
    ..userAgent = 'NinjaFlix artwork updater/0.1';

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
