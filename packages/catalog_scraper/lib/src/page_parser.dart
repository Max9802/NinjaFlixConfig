import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'models.dart';
import 'normalization.dart';

final class GoogleSitesPageParser {
  GoogleSitesPageParser({required this.siteRoot})
    : _allowedPrefix = _buildAllowedPrefix(siteRoot);

  final Uri siteRoot;
  final String _allowedPrefix;

  ParsedSitePage parse({required Uri url, required String html}) {
    final document = html_parser.parse(html);
    final links = _extractInternalLinks(document, url);
    final issues = <ScrapeIssue>[];
    final embeds = document.querySelectorAll('[data-embed-doc-id]');

    if (embeds.isEmpty) {
      return ParsedSitePage(
        url: url,
        internalLinks: links,
        issues: issues,
        infoPage: _informationPage(document, url),
      );
    }

    final pageTitle = _findPageTitle(document, url);
    final series = _seriesFor(pageTitle);
    final sourcePageKey = _pageKey(url);
    final seasonKey = '${series.key}/$sourcePageKey';
    final tokens = document.querySelectorAll(
      'h1, h2, h3, p, [data-embed-doc-id]',
    );
    final uniqueEmbeds = <String, Element>{};

    for (final embed in embeds) {
      final remoteId = collapseWhitespace(
        embed.attributes['data-embed-doc-id'] ?? '',
      );
      if (remoteId.isEmpty) {
        issues.add(ScrapeIssue(url: url, message: 'Embed de Drive sin ID.'));
        continue;
      }
      uniqueEmbeds.putIfAbsent(remoteId, () => embed);
    }

    final episodes = <ScrapedEpisode>[];
    final identityPriorityByBaseKey = <String, int>{};
    var ordinal = 0;
    for (final entry in uniqueEmbeds.entries) {
      ordinal++;
      final embed = entry.value;
      final fileName = _fileName(embed);
      final code = _episodeCode(fileName);
      final contextualText = _contextAfter(tokens, embed);
      final explicit = _explicitEpisode(contextualText);
      final episodeNumber = explicit?.number ?? code?.episode ?? ordinal;
      final title = collapseWhitespace(
        explicit?.title.isNotEmpty == true
            ? explicit!.title
            : stripFileName(fileName).isNotEmpty
            ? stripFileName(fileName)
            : 'Episodio $episodeNumber',
      );
      final synopsis = _episodeSynopsis(contextualText, title, explicit?.raw);
      final kind = _contentKind(pageTitle);
      final source = _mediaSource(embed, entry.key);
      final baseLogicalKey =
          '$seasonKey/e${episodeNumber.toString().padLeft(3, '0')}';
      final identityPriority = code != null
          ? 2
          : explicit != null ||
                RegExp(
                  r'\bep(?:isodio)?\s*\d+',
                  caseSensitive: false,
                ).hasMatch(fileName)
          ? 1
          : 0;
      var logicalKey = baseLogicalKey;
      final existingIndex = episodes.indexWhere(
        (episode) => episode.logicalKey == baseLogicalKey,
      );
      if (existingIndex >= 0) {
        final previousPriority = identityPriorityByBaseKey[baseLogicalKey] ?? 0;
        if (identityPriority > previousPriority) {
          final previous = episodes[existingIndex];
          final replacementKey = _uniqueExtraKey(
            baseLogicalKey,
            previous.title,
            episodes,
          );
          episodes[existingIndex] = _withLogicalKey(previous, replacementKey);
          identityPriorityByBaseKey[baseLogicalKey] = identityPriority;
        } else {
          logicalKey = _uniqueExtraKey(baseLogicalKey, title, episodes);
        }
      } else {
        identityPriorityByBaseKey[baseLogicalKey] = identityPriority;
      }
      final logicalHash = _episodeLogicalHash(
        logicalKey: logicalKey,
        title: title,
        synopsis: synopsis,
        kind: kind,
        availability: ScrapedAvailability.available,
      );

      episodes.add(
        ScrapedEpisode(
          logicalKey: logicalKey,
          number: episodeNumber,
          title: title,
          synopsis: synopsis,
          kind: kind,
          availability: ScrapedAvailability.available,
          sortOrder: ordinal,
          logicalHash: logicalHash,
          mediaSources: [source],
        ),
      );
    }

    if (episodes.length != uniqueEmbeds.length ||
        episodes.map((episode) => episode.logicalKey).toSet().length !=
            episodes.length) {
      issues.add(
        ScrapeIssue(
          url: url,
          message: 'No todos los embeds recibieron una identidad única.',
          isFatal: true,
        ),
      );
    }

    _appendAnnouncedEpisodes(
      document: document,
      episodes: episodes,
      seasonKey: seasonKey,
      kind: _contentKind(pageTitle),
    );

    final description = _pageDescription(tokens, uniqueEmbeds.values.first);
    final displayNumber = _displaySeasonNumber(pageTitle);
    final canonicalCode = episodes
        .expand((episode) => episode.mediaSources)
        .map((source) => _episodeCode(_fileNameForSource(source, embeds)))
        .whereType<_EpisodeCode>()
        .map((code) => code.season)
        .firstOrNull;
    _mergeStreamTapeSources(
      document: document,
      episodes: episodes,
      seasonKey: seasonKey,
      kind: _contentKind(pageTitle),
    );
    episodes.sort((left, right) => left.sortOrder.compareTo(right.sortOrder));
    final seasonHash = stableHash([
      1,
      seasonKey,
      pageTitle,
      description,
      displayNumber,
      ...episodes.map((episode) => episode.logicalHash),
    ]);

    return ParsedSitePage(
      url: url,
      internalLinks: links,
      issues: issues,
      seriesKey: series.key,
      seriesTitle: series.title,
      season: ScrapedSeason(
        logicalKey: seasonKey,
        sourceUrl: url,
        sourcePageKey: sourcePageKey,
        title: pageTitle,
        synopsis: description,
        displayNumber: displayNumber ?? canonicalCode,
        canonicalCode: canonicalCode,
        sortOrder: canonicalCode ?? displayNumber ?? 1000,
        logicalHash: seasonHash,
        episodes: List.unmodifiable(episodes),
      ),
    );
  }

  String _uniqueExtraKey(
    String baseKey,
    String title,
    List<ScrapedEpisode> episodes,
  ) {
    final suffix = slugify(title).isEmpty ? 'extra' : slugify(title);
    var candidate = '$baseKey-$suffix';
    var sequence = 2;
    final used = episodes.map((episode) => episode.logicalKey).toSet();
    while (used.contains(candidate)) {
      candidate = '$baseKey-$suffix-$sequence';
      sequence++;
    }
    return candidate;
  }

  ScrapedEpisode _withLogicalKey(ScrapedEpisode episode, String logicalKey) {
    return ScrapedEpisode(
      logicalKey: logicalKey,
      number: episode.number,
      title: episode.title,
      synopsis: episode.synopsis,
      kind: episode.kind,
      availability: episode.availability,
      sortOrder: episode.sortOrder,
      logicalHash: _episodeLogicalHash(
        logicalKey: logicalKey,
        title: episode.title,
        synopsis: episode.synopsis,
        kind: episode.kind,
        availability: episode.availability,
      ),
      mediaSources: episode.mediaSources,
    );
  }

  String _episodeLogicalHash({
    required String logicalKey,
    required String title,
    required String synopsis,
    required ScrapedContentKind kind,
    required ScrapedAvailability availability,
  }) => stableHash([
    1,
    logicalKey,
    title,
    synopsis,
    kind.name,
    availability.name,
  ]);

  Set<Uri> _extractInternalLinks(Document document, Uri currentUrl) {
    final result = <Uri>{};
    for (final anchor in document.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href'];
      if (href == null || href.isEmpty) {
        continue;
      }
      final resolved = currentUrl.resolve(href);
      if (resolved.scheme != 'https' || resolved.host != siteRoot.host) {
        continue;
      }
      if (!resolved.path.startsWith(_allowedPrefix)) {
        continue;
      }
      result.add(canonicalPageUri(resolved));
    }
    return result;
  }

  String _findPageTitle(Document document, Uri url) {
    for (final heading in document.querySelectorAll('h1')) {
      final value = collapseWhitespace(heading.text);
      if (value.isNotEmpty &&
          normalizedText(value) != 'la biblioteca elemental') {
        return value;
      }
    }
    return _pageKey(url).replaceAll('-', ' ');
  }

  ScrapedInfoPage? _informationPage(Document document, Uri url) {
    final root = document.querySelector('.UtePc') ?? document.body;
    if (root == null) return null;

    final key = _pageKey(url);
    final title = key == 'inicio' ? 'Inicio' : _findPageTitle(document, url);
    final blocks = <String>[];
    for (final element in root.querySelectorAll('h1, h2, h3, p, li')) {
      final text = collapseWhitespace(element.text);
      if (!_isUsefulText(text) ||
          normalizedText(text) == normalizedText(title)) {
        continue;
      }
      if (blocks.isEmpty || blocks.last != text) blocks.add(text);
    }
    if (blocks.isEmpty) return null;

    final foundLinks = <String>{};
    final pageLinks = <ScrapedInfoLink>[];
    for (final anchor in root.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href'];
      if (href == null || href.isEmpty) continue;
      final resolved = url.resolve(href);
      if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
      final label = collapseWhitespace(anchor.text);
      if (label.isEmpty || !foundLinks.add(resolved.toString())) continue;
      pageLinks.add(ScrapedInfoLink(label: label, url: resolved));
    }

    final body = blocks.join('\n\n');
    final sortOrder = switch (key) {
      'inicio' => 0,
      'orden-cronologico' => 10,
      'comics' => 20,
      'cortos' => 30,
      _ => 100,
    };
    return ScrapedInfoPage(
      logicalKey: key,
      sourceUrl: url,
      title: title,
      body: body,
      links: List.unmodifiable(pageLinks),
      sortOrder: sortOrder,
      logicalHash: stableHash([
        1,
        key,
        title,
        body,
        ...pageLinks.map((link) => '${link.label}:${link.url}'),
      ]),
    );
  }

  String _fileName(Element embed) {
    final label = embed
        .querySelector('iframe[aria-label]')
        ?.attributes['aria-label'];
    final visible = embed.querySelector('.pB4Yfc')?.text;
    return collapseWhitespace(label ?? visible ?? '');
  }

  ScrapedMediaSource _mediaSource(Element embed, String remoteId) {
    final open = _uriOrFallback(
      embed.attributes['data-embed-open-url'],
      'https://drive.google.com/open?id=$remoteId',
    );
    final preview = _uriOrFallback(
      embed.querySelector('iframe')?.attributes['data-src'],
      'https://drive.google.com/file/d/$remoteId/preview',
    );
    final download = _uriOrFallback(
      embed.attributes['data-embed-download-url'],
      'https://drive.google.com/uc?id=$remoteId&export=download',
    );
    final thumbnail = _uriOrFallback(
      embed.attributes['data-embed-thumbnail-url'],
      'https://drive.google.com/thumbnail?id=$remoteId&sz=w640-h360-p-k-nu',
    );
    return ScrapedMediaSource(
      provider: 'google_drive',
      remoteId: remoteId,
      openUrl: open,
      previewUrl: preview,
      downloadUrl: download,
      thumbnailUrl: thumbnail,
      locatorHash: stableHash([
        1,
        'google_drive',
        remoteId,
        open,
        preview,
        download,
      ]),
    );
  }

  void _mergeStreamTapeSources({
    required Document document,
    required List<ScrapedEpisode> episodes,
    required String seasonKey,
    required ScrapedContentKind kind,
  }) {
    final candidates = <String, _StreamTapeCandidate>{};
    for (final link in document.querySelectorAll('a[href]')) {
      final openUrl = _streamTapeUrl(link.attributes['href']);
      final remoteId = _streamTapeId(openUrl);
      if (openUrl == null || remoteId == null) continue;

      final linkText = collapseWhitespace(link.text);
      final fileName = openUrl.pathSegments.isEmpty
          ? ''
          : openUrl.pathSegments.last;
      final explicit = _explicitEpisode([linkText, stripFileName(fileName)]);
      final code = _episodeCode(fileName);
      final title = collapseWhitespace(
        explicit?.title.isNotEmpty == true
            ? explicit!.title
            : linkText.isNotEmpty
            ? linkText
            : stripFileName(fileName),
      );
      final thumbnail = Uri.tryParse(
        link.querySelector('img')?.attributes['src'] ?? '',
      );
      final previous = candidates[remoteId];
      candidates[remoteId] = _StreamTapeCandidate(
        remoteId: remoteId,
        openUrl: openUrl,
        number: explicit?.number ?? code?.episode ?? previous?.number,
        title: title.isNotEmpty ? title : previous?.title ?? '',
        thumbnailUrl: thumbnail?.hasScheme == true
            ? thumbnail!
            : previous?.thumbnailUrl,
      );
    }

    for (final candidate in candidates.values) {
      var episodeIndex = candidate.title.isEmpty
          ? -1
          : episodes.indexWhere(
              (episode) =>
                  _comparableTitle(episode.title) ==
                  _comparableTitle(candidate.title),
            );
      if (episodeIndex < 0 && candidate.number != null) {
        episodeIndex = episodes.indexWhere(
          (episode) => episode.number == candidate.number,
        );
      }

      if (episodeIndex >= 0) {
        final episode = episodes[episodeIndex];
        final oldSource = episode.mediaSource;
        final source = _streamTapeSource(
          candidate,
          fallbackThumbnail: oldSource?.thumbnailUrl,
        );
        final availability =
            episode.availability == ScrapedAvailability.announced
            ? ScrapedAvailability.available
            : episode.availability;
        episodes[episodeIndex] = ScrapedEpisode(
          logicalKey: episode.logicalKey,
          number: episode.number,
          title: episode.title,
          synopsis: episode.synopsis,
          kind: episode.kind,
          availability: availability,
          sortOrder: episode.sortOrder,
          logicalHash: _episodeLogicalHash(
            logicalKey: episode.logicalKey,
            title: episode.title,
            synopsis: episode.synopsis,
            kind: episode.kind,
            availability: availability,
          ),
          mediaSources: [
            source,
            ...episode.mediaSources.where(
              (existing) => existing.provider != source.provider,
            ),
          ],
        );
        continue;
      }

      final number = candidate.number;
      if (number == null || candidate.title.isEmpty) continue;
      final baseLogicalKey = '$seasonKey/e${number.toString().padLeft(3, '0')}';
      final logicalKey =
          episodes.any((episode) => episode.logicalKey == baseLogicalKey)
          ? _uniqueExtraKey(baseLogicalKey, candidate.title, episodes)
          : baseLogicalKey;
      episodes.add(
        ScrapedEpisode(
          logicalKey: logicalKey,
          number: number,
          title: candidate.title,
          synopsis: '',
          kind: kind,
          availability: ScrapedAvailability.available,
          sortOrder: number,
          logicalHash: _episodeLogicalHash(
            logicalKey: logicalKey,
            title: candidate.title,
            synopsis: '',
            kind: kind,
            availability: ScrapedAvailability.available,
          ),
          mediaSources: [_streamTapeSource(candidate)],
        ),
      );
    }
  }

  ScrapedMediaSource _streamTapeSource(
    _StreamTapeCandidate candidate, {
    Uri? fallbackThumbnail,
  }) {
    final thumbnail = candidate.thumbnailUrl ?? fallbackThumbnail ?? Uri();
    return ScrapedMediaSource(
      provider: 'streamtape',
      remoteId: candidate.remoteId,
      openUrl: candidate.openUrl,
      previewUrl: candidate.openUrl,
      downloadUrl: candidate.openUrl,
      thumbnailUrl: thumbnail,
      locatorHash: stableHash([
        1,
        'streamtape',
        candidate.remoteId,
        candidate.openUrl,
      ]),
    );
  }

  Uri? _streamTapeUrl(String? value) {
    final parsed = value == null ? null : Uri.tryParse(value);
    if (parsed == null) return null;
    if (parsed.host.toLowerCase() == 'streamtape.com') return parsed;
    if (parsed.host.toLowerCase() == 'www.google.com' &&
        parsed.path == '/url') {
      final target = Uri.tryParse(parsed.queryParameters['q'] ?? '');
      if (target?.host.toLowerCase() == 'streamtape.com') return target;
    }
    return null;
  }

  String? _streamTapeId(Uri? url) {
    if (url == null || url.host.toLowerCase() != 'streamtape.com') return null;
    final segments = url.pathSegments.where((part) => part.isNotEmpty).toList();
    if (segments.length < 2 ||
        !const {'e', 'v'}.contains(segments.first.toLowerCase())) {
      return null;
    }
    return segments[1];
  }

  String _comparableTitle(String value) => normalizedText(
    value,
  ).replaceFirst(RegExp(r'^(?:el|la|los|las|un|una)\s+'), '');

  List<String> _contextAfter(List<Element> tokens, Element embed) {
    final start = tokens.indexWhere((element) => identical(element, embed));
    if (start < 0) return const [];
    final result = <String>[];
    for (var index = start + 1; index < tokens.length; index++) {
      final token = tokens[index];
      if (token.attributes.containsKey('data-embed-doc-id')) break;
      final text = collapseWhitespace(token.text);
      if (_isUsefulText(text)) result.add(text);
    }
    return result;
  }

  String _pageDescription(List<Element> tokens, Element firstEmbed) {
    final end = tokens.indexWhere((element) => identical(element, firstEmbed));
    if (end < 0) return '';
    final paragraphs = <String>[];
    for (var index = 0; index < end; index++) {
      final token = tokens[index];
      if (token.localName != 'p') continue;
      final text = collapseWhitespace(token.text);
      if (_isUsefulText(text) && text.length >= 40) paragraphs.add(text);
    }
    return paragraphs.take(3).join('\n\n');
  }

  String _episodeSynopsis(
    List<String> blocks,
    String title,
    String? explicitTitleLine,
  ) {
    final normalizedTitle = normalizedText(title);
    return blocks
        .where((block) => block != explicitTitleLine)
        .where(
          (block) => normalizedText(stripFileName(block)) != normalizedTitle,
        )
        .where((block) => !_looksLikeEpisodeLabel(block))
        .where((block) => block.length >= 40)
        .join('\n\n');
  }

  void _appendAnnouncedEpisodes({
    required Document document,
    required List<ScrapedEpisode> episodes,
    required String seasonKey,
    required ScrapedContentKind kind,
  }) {
    final existingNumbers = episodes.map((episode) => episode.number).toSet();
    final pattern = RegExp(
      r'^\s*Ep(?:isodio)?\s*(\d{1,3})\s*[:.-]\s*(PR[ÓO]XIMAMENTE)\s*$',
      caseSensitive: false,
    );
    for (final paragraph in document.querySelectorAll('p')) {
      final text = collapseWhitespace(paragraph.text);
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final number = int.parse(match.group(1)!);
      if (existingNumbers.contains(number)) continue;
      final logicalKey = '$seasonKey/e${number.toString().padLeft(3, '0')}';
      episodes.add(
        ScrapedEpisode(
          logicalKey: logicalKey,
          number: number,
          title: 'Próximamente',
          synopsis: '',
          kind: kind,
          availability: ScrapedAvailability.announced,
          sortOrder: number,
          logicalHash: stableHash([
            1,
            logicalKey,
            'Próximamente',
            kind.name,
            ScrapedAvailability.announced.name,
          ]),
        ),
      );
    }
  }

  _SeriesIdentity _seriesFor(String pageTitle) {
    if (normalizedText(pageTitle).contains('dragons rising')) {
      return const _SeriesIdentity('dragons-rising', 'Dragons Rising');
    }
    return const _SeriesIdentity('ninjago', 'Ninjago');
  }

  ScrapedContentKind _contentKind(String pageTitle) {
    final normalized = normalizedText(pageTitle);
    if (normalized.contains('corto')) return ScrapedContentKind.short;
    if (normalized.contains('pelicula')) return ScrapedContentKind.movie;
    if (normalized.contains('especial') ||
        normalized.contains('cumpleanos') ||
        normalized.contains('crossover')) {
      return ScrapedContentKind.special;
    }
    return ScrapedContentKind.episode;
  }

  _ExplicitEpisode? _explicitEpisode(List<String> blocks) {
    final pattern = RegExp(
      r'^\s*Ep(?:isodio)?\s*(\d{1,3})\s*[:.-]\s*(.+)$',
      caseSensitive: false,
    );
    for (final block in blocks) {
      final match = pattern.firstMatch(block);
      if (match == null) continue;
      return _ExplicitEpisode(
        int.parse(match.group(1)!),
        collapseWhitespace(match.group(2)!),
        block,
      );
    }
    return null;
  }

  _EpisodeCode? _episodeCode(String value) {
    final match = RegExp(r'(\d{1,3})\s*[xX×]\s*(\d{1,3})').firstMatch(value);
    if (match == null) return null;
    return _EpisodeCode(int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  int? _displaySeasonNumber(String title) {
    final match = RegExp(
      r'temporada\s*(\d{1,3})',
      caseSensitive: false,
    ).firstMatch(title);
    return match == null ? null : int.parse(match.group(1)!);
  }

  bool _looksLikeEpisodeLabel(String value) => RegExp(
    r'^\s*Ep(?:isodio)?\s*\d{1,3}\s*[:.-]',
    caseSensitive: false,
  ).hasMatch(value);

  bool _isUsefulText(String value) {
    if (value.isEmpty || value == '#' || value == '##') return false;
    const ignored = {
      'Google Sites',
      'Report abuse',
      'Page details',
      'Page updated',
      'Skip to main content',
      'Skip to navigation',
    };
    return !ignored.contains(value);
  }

  Uri _uriOrFallback(String? value, String fallback) {
    final candidate = value == null ? null : Uri.tryParse(value);
    return candidate?.hasScheme == true ? candidate! : Uri.parse(fallback);
  }

  String _fileNameForSource(ScrapedMediaSource source, List<Element> embeds) {
    for (final embed in embeds) {
      if (embed.attributes['data-embed-doc-id'] == source.remoteId) {
        return _fileName(embed);
      }
    }
    return '';
  }

  String _pageKey(Uri uri) {
    if (uri.pathSegments.isEmpty) return 'inicio';
    return slugify(uri.pathSegments.last);
  }

  static String _buildAllowedPrefix(Uri root) {
    final path = root.path.endsWith('/')
        ? root.path.substring(0, root.path.length - 1)
        : root.path;
    return '$path/';
  }
}

final class _SeriesIdentity {
  const _SeriesIdentity(this.key, this.title);

  final String key;
  final String title;
}

final class _EpisodeCode {
  const _EpisodeCode(this.season, this.episode);

  final int season;
  final int episode;
}

final class _ExplicitEpisode {
  const _ExplicitEpisode(this.number, this.title, this.raw);

  final int number;
  final String title;
  final String raw;
}

final class _StreamTapeCandidate {
  const _StreamTapeCandidate({
    required this.remoteId,
    required this.openUrl,
    required this.number,
    required this.title,
    required this.thumbnailUrl,
  });

  final String remoteId;
  final Uri openUrl;
  final int? number;
  final String title;
  final Uri? thumbnailUrl;
}
