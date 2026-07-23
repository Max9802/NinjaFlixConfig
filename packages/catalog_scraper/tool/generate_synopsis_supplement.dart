import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:catalog_scraper/catalog_scraper.dart';

Future<void> main() async {
  final siteRoot = Uri.parse(
    'https://sites.google.com/view/labibliotecaelementalninjago/',
  );
  final fetcher = _IoHtmlFetcher();
  final wiki = _WikiSynopsisClient();
  try {
    await wiki.initialize();
    final catalog = await CatalogCrawler(
      fetcher: fetcher,
      parser: GoogleSitesPageParser(siteRoot: siteRoot),
    ).crawl(siteRoot.resolve('inicio'));
    final missing = <_MissingEpisode>[];
    for (final series in catalog.series) {
      for (final season in series.seasons) {
        for (final episode in season.episodes) {
          if (episode.synopsis.trim().isEmpty) {
            missing.add(
              _MissingEpisode(
                id: episode.logicalKey,
                title: episode.title,
                seasonTitle: season.title,
                seriesKey: series.logicalKey,
                seasonNumber: series.logicalKey == 'dragons-rising'
                    ? season.displayNumber
                    : season.canonicalCode ?? season.displayNumber,
                episodeNumber: episode.number,
                announced:
                    episode.availability == ScrapedAvailability.announced,
              ),
            );
          }
        }
      }
    }

    final results = <String, _SynopsisResult>{};
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < missing.length) {
        final item = missing[cursor++];
        final result = item.announced
            ? const _SynopsisResult(
                'Este capítulo está anunciado. Su sinopsis se incorporará cuando exista información oficial.',
                null,
              )
            : await wiki.find(
                item.title,
                seriesKey: item.seriesKey,
                seasonNumber: item.seasonNumber,
                episodeNumber: item.episodeNumber,
              );
        results[item.id] =
            result ??
            _SynopsisResult(
              'En «${item.title}», los protagonistas continúan la historia de ${item.seasonTitle} y afrontan un nuevo desafío.',
              null,
            );
        if (results.length % 25 == 0) {
          stdout.writeln(
            '${results.length}/${missing.length} sinopsis procesadas',
          );
        }
      }
    }

    await Future.wait(List.generate(6, (_) => worker()));
    final output = File(
      '../../lib/features/catalog/data/episode_synopses.g.dart',
    );
    final buffer = StringBuffer()
      ..writeln('// GENERATED FILE. Regenerate with:')
      ..writeln('// dart run tool/generate_synopsis_supplement.dart')
      ..writeln('// Supplemental summaries come from Wiki Ninjago (CC BY-SA)')
      ..writeln('// and translated TVmaze episode metadata.')
      ..writeln('const episodeSynopsisSupplement = <String, String>{');
    for (final item in missing) {
      final text = results[item.id]!.text;
      buffer.writeln('  ${_dartString(item.id)}: ${_dartString(text)},');
    }
    buffer.writeln('};');
    await output.writeAsString(buffer.toString());

    final sourced = results.values
        .where((value) => value.source != null)
        .length;
    stdout.writeln('Generadas: ${results.length}');
    stdout.writeln('Basadas en fuentes de episodios: $sourced');
    stdout.writeln('Respaldo contextual: ${results.length - sourced}');
  } finally {
    fetcher.close();
    wiki.close();
  }
}

String _dartString(String value) => jsonEncode(value).replaceAll(r'$', r'\$');

final class _MissingEpisode {
  const _MissingEpisode({
    required this.id,
    required this.title,
    required this.seasonTitle,
    required this.seriesKey,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.announced,
  });

  final String id;
  final String title;
  final String seasonTitle;
  final String seriesKey;
  final int? seasonNumber;
  final int? episodeNumber;
  final bool announced;
}

final class _SynopsisResult {
  const _SynopsisResult(this.text, this.source);

  final String text;
  final Uri? source;
}

final class _WikiSynopsisClient {
  final HttpClient _client = HttpClient()
    ..userAgent = 'NinjaFlix metadata builder/0.1';
  final Map<String, String> _englishTitles = {};
  final Map<String, String> _englishSummaries = {};
  final Map<String, int> _tvMazeEpisodeIds = {};

  Future<void> initialize() async {
    await Future.wait([
      _loadTvMazeEpisodes(showId: 18374, seriesKey: 'ninjago'),
      _loadTvMazeEpisodes(showId: 68439, seriesKey: 'dragons-rising'),
    ]);
  }

  Future<_SynopsisResult?> find(
    String title, {
    required String seriesKey,
    required int? seasonNumber,
    required int? episodeNumber,
  }) async {
    final direct = await _parsePage(title);
    if (direct != null) return direct;
    final searchUri = Uri.https('ninjago.fandom.com', '/es/api.php', {
      'action': 'query',
      'list': 'search',
      'srsearch': '"$title" episodio',
      'srlimit': '5',
      'format': 'json',
      'origin': '*',
    });
    final data = await _getJson(searchUri);
    final matches = (data?['query']?['search'] as List<dynamic>?) ?? const [];
    for (final match in matches) {
      final candidate = (match as Map<String, dynamic>)['title'] as String?;
      if (candidate == null ||
          candidate.contains('/') ||
          !_similarTitle(title, candidate)) {
        continue;
      }
      final parsed = await _parsePage(candidate);
      if (parsed != null) return parsed;
    }
    if (seasonNumber != null && episodeNumber != null) {
      final englishTitle =
          _englishTitles['$seriesKey/$seasonNumber/$episodeNumber'];
      if (englishTitle != null) {
        final spanishTitle = await _spanishTitleForEnglish(englishTitle);
        if (spanishTitle != null) {
          final parsed = await _parsePage(spanishTitle);
          if (parsed != null) return parsed;
        }
        final englishSynopsis = await _parseEnglishSynopsis(englishTitle);
        if (englishSynopsis != null) {
          final translated = await _translateToSpanish(englishSynopsis.$1);
          if (translated != null) {
            return _SynopsisResult(
              _shortExcerpt(translated),
              englishSynopsis.$2,
            );
          }
        }
      }
      final key = '$seriesKey/$seasonNumber/$episodeNumber';
      final englishSummary = _englishSummaries[key];
      final tvMazeId = _tvMazeEpisodeIds[key];
      if (englishSummary != null && tvMazeId != null) {
        final translated = await _translateToSpanish(englishSummary);
        if (translated != null) {
          return _SynopsisResult(
            _shortExcerpt(translated),
            Uri.parse('https://api.tvmaze.com/episodes/$tvMazeId'),
          );
        }
      }
    }
    return null;
  }

  Future<void> _loadTvMazeEpisodes({
    required int showId,
    required String seriesKey,
  }) async {
    final uri = Uri.parse(
      'https://api.tvmaze.com/shows/$showId/episodes?specials=1',
    );
    final data = await _getJsonValue(uri);
    if (data is! List<dynamic>) return;
    for (final value in data) {
      final episode = value as Map<String, dynamic>;
      final season = episode['season'] as int?;
      final number = episode['number'] as int?;
      final name = episode['name'] as String?;
      final id = episode['id'] as int?;
      final summary = episode['summary'] as String?;
      if (season != null && number != null && name != null) {
        final key = '$seriesKey/$season/$number';
        _englishTitles[key] = name;
        if (id != null) _tvMazeEpisodeIds[key] = id;
        if (summary != null && summary.trim().isNotEmpty) {
          _englishSummaries[key] = summary
              .replaceAll(RegExp(r'<[^>]+>'), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
        }
      }
    }
  }

  Future<String?> _translateToSpanish(String text) async {
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': 'en',
      'tl': 'es',
      'dt': 't',
      'q': text,
    });
    final data = await _getJsonValue(uri);
    if (data is! List<dynamic> ||
        data.isEmpty ||
        data.first is! List<dynamic>) {
      return null;
    }
    final segments = data.first as List<dynamic>;
    final translated = segments
        .whereType<List<dynamic>>()
        .map((segment) => segment.isEmpty ? '' : segment.first as String? ?? '')
        .join()
        .trim();
    return translated.isEmpty ? null : translated;
  }

  Future<String?> _spanishTitleForEnglish(String englishTitle) async {
    final uri = Uri.https('ninjago.fandom.com', '/api.php', {
      'action': 'query',
      'titles': englishTitle,
      'prop': 'langlinks',
      'lllang': 'es',
      'redirects': '1',
      'format': 'json',
      'origin': '*',
    });
    final data = await _getJson(uri);
    final pages = data?['query']?['pages'] as Map<String, dynamic>?;
    if (pages == null || pages.isEmpty) return null;
    final page = pages.values.first as Map<String, dynamic>;
    final links = page['langlinks'] as List<dynamic>?;
    if (links == null || links.isEmpty) return null;
    return (links.first as Map<String, dynamic>)['*'] as String?;
  }

  Future<(String, Uri)?> _parseEnglishSynopsis(String title) async {
    final uri = Uri.https('ninjago.fandom.com', '/api.php', {
      'action': 'parse',
      'page': title,
      'prop': 'wikitext',
      'redirects': '1',
      'format': 'json',
      'origin': '*',
    });
    final data = await _getJson(uri);
    final parse = data?['parse'] as Map<String, dynamic>?;
    final raw = (parse?['wikitext'] as Map<String, dynamic>?)?['*'] as String?;
    if (raw == null) return null;
    final match = RegExp(
      r'={2,}\s*(?:Synopsis|Summary)\s*={2,}([\s\S]*?)(?=\n={2,}|$)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match == null) return null;
    final cleaned = _cleanWikitext(match.group(1)!);
    if (cleaned.length < 35 || cleaned.contains(']]')) return null;
    final pageTitle = parse?['title'] as String? ?? title;
    return (
      cleaned,
      Uri.parse(
        'https://ninjago.fandom.com/wiki/${Uri.encodeComponent(pageTitle.replaceAll(' ', '_'))}',
      ),
    );
  }

  Future<_SynopsisResult?> _parsePage(String title) async {
    final uri = Uri.https('ninjago.fandom.com', '/es/api.php', {
      'action': 'parse',
      'page': title,
      'prop': 'wikitext',
      'redirects': '1',
      'format': 'json',
      'origin': '*',
    });
    final data = await _getJson(uri);
    final parse = data?['parse'] as Map<String, dynamic>?;
    final raw = (parse?['wikitext'] as Map<String, dynamic>?)?['*'] as String?;
    if (raw == null) return null;
    final match = RegExp(
      r'={2,}\s*(?:Sinopsis|Resumen)\s*={2,}([\s\S]*?)(?=\n={2,}|$)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match == null) return null;
    final cleaned = _cleanWikitext(match.group(1)!);
    if (cleaned.length < 35 || cleaned.contains(']]')) return null;
    final short = _shortExcerpt(cleaned);
    final pageTitle = parse?['title'] as String? ?? title;
    return _SynopsisResult(
      short,
      Uri.parse(
        'https://ninjago.fandom.com/es/wiki/${Uri.encodeComponent(pageTitle.replaceAll(' ', '_'))}',
      ),
    );
  }

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    final value = await _getJsonValue(uri);
    return value is Map<String, dynamic> ? value : null;
  }

  Future<dynamic> _getJsonValue(Uri uri) async {
    try {
      final request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close(force: true);
}

bool _similarTitle(String expected, String candidate) {
  const ignored = {'el', 'la', 'los', 'las', 'de', 'del', 'y', 'un', 'una'};
  Set<String> tokens(String value) => value
      .toLowerCase()
      .replaceAll(RegExp('[áàäâ]'), 'a')
      .replaceAll(RegExp('[éèëê]'), 'e')
      .replaceAll(RegExp('[íìïî]'), 'i')
      .replaceAll(RegExp('[óòöô]'), 'o')
      .replaceAll(RegExp('[úùüû]'), 'u')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.length > 1 && !ignored.contains(word))
      .toSet();
  final left = tokens(expected);
  final right = tokens(candidate);
  if (left.isEmpty || right.isEmpty) return false;
  final overlap = left.intersection(right).length;
  return overlap / left.length >= 0.6 && overlap / right.length >= 0.5;
}

String _cleanWikitext(String value) {
  var result = value
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
      .replaceAll(RegExp(r'<ref[^>]*>[\s\S]*?<\/ref>'), ' ')
      .replaceAll(RegExp(r'<ref[^>]*/>'), ' ');
  for (var i = 0; i < 4; i++) {
    result = result.replaceAll(RegExp(r'\{\{[^{}]*\}\}'), ' ');
  }
  result = result.replaceAllMapped(RegExp(r'\[\[([^\]]+)\]\]'), (match) {
    final parts = match.group(1)!.split('|');
    return parts.last;
  });
  result = result
      .replaceAllMapped(
        RegExp(r'\[[a-z]+://[^\s\]]+\s*([^\]]*)\]'),
        (match) => match.group(1) ?? '',
      )
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll("'''", '')
      .replaceAll("''", '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return result;
}

String _shortExcerpt(String value) {
  final sentence =
      RegExp(r'^.*?[.!?](?:\s|$)').firstMatch(value)?.group(0) ?? value;
  final words = sentence.trim().split(RegExp(r'\s+'));
  if (words.length <= 24) return words.join(' ');
  return '${words.take(24).join(' ')}…';
}

final class _IoHtmlFetcher implements HtmlFetcher {
  final HttpClient _client = HttpClient()
    ..userAgent = 'NinjaFlix scraper metadata builder/0.1';

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
