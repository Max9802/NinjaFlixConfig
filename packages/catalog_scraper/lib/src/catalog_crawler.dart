import 'html_fetcher.dart';
import 'models.dart';
import 'normalization.dart';
import 'page_parser.dart';

final class CatalogCrawler {
  CatalogCrawler({
    required this.fetcher,
    required this.parser,
    this.maxPages = 160,
    this.maxConcurrency = 4,
  }) : assert(maxPages > 0),
       assert(maxConcurrency > 0);

  final HtmlFetcher fetcher;
  final GoogleSitesPageParser parser;
  final int maxPages;
  final int maxConcurrency;

  Future<ScrapedCatalog> crawl(Uri startUrl) async {
    final queue = <Uri>[canonicalPageUri(startUrl)];
    final queued = <Uri>{...queue};
    final visited = <Uri>{};
    final successfulPages = <Uri>{};
    final failedPages = <Uri>{};
    final issues = <ScrapeIssue>[];
    final seasonsBySeries = <String, List<ScrapedSeason>>{};
    final seriesTitles = <String, String>{};
    final infoPages = <ScrapedInfoPage>[];

    while (queue.isNotEmpty && visited.length < maxPages) {
      final remaining = maxPages - visited.length;
      final batchSize = [
        maxConcurrency,
        queue.length,
        remaining,
      ].reduce((left, right) => left < right ? left : right);
      final batch = queue.take(batchSize).toList(growable: false);
      queue.removeRange(0, batchSize);

      final results = await Future.wait(
        batch.map((uri) async {
          try {
            final html = await fetcher.fetch(uri);
            return parser.parse(url: uri, html: html);
          } catch (error, stackTrace) {
            final trace = stackTrace.toString().split('\n').take(3).join(' | ');
            issues.add(
              ScrapeIssue(
                url: uri,
                message: 'No se pudo procesar la página: $error ($trace)',
              ),
            );
            return null;
          }
        }),
      );

      for (var index = 0; index < batch.length; index++) {
        final uri = batch[index];
        visited.add(uri);
        final page = results[index];
        if (page == null) {
          failedPages.add(uri);
          continue;
        }
        successfulPages.add(uri);
        issues.addAll(page.issues);
        if (page.infoPage case final infoPage?) infoPages.add(infoPage);
        for (final link in page.internalLinks) {
          if (visited.contains(link) || !queued.add(link)) continue;
          queue.add(link);
        }
        final season = page.season;
        final seriesKey = page.seriesKey;
        if (season == null || seriesKey == null) continue;
        seasonsBySeries.putIfAbsent(seriesKey, () => []).add(season);
        seriesTitles[seriesKey] = page.seriesTitle ?? seriesKey;
      }
    }

    if (queue.isNotEmpty) {
      issues.add(
        ScrapeIssue(
          url: startUrl,
          message: 'Se alcanzó el límite de $maxPages páginas.',
        ),
      );
    }

    final series = <ScrapedSeries>[];
    for (final entry in seasonsBySeries.entries) {
      final seasons = entry.value;
      seasons.sort((left, right) {
        final order = left.sortOrder.compareTo(right.sortOrder);
        return order != 0 ? order : left.title.compareTo(right.title);
      });
      final logicalHash = stableHash([
        1,
        entry.key,
        seriesTitles[entry.key],
        ...seasons.map((season) => season.logicalHash),
      ]);
      series.add(
        ScrapedSeries(
          logicalKey: entry.key,
          title: seriesTitles[entry.key]!,
          sortOrder: entry.key == 'ninjago' ? 0 : 1,
          logicalHash: logicalHash,
          seasons: List.unmodifiable(seasons),
        ),
      );
    }
    series.sort((left, right) => left.sortOrder.compareTo(right.sortOrder));
    infoPages.sort((left, right) {
      final order = left.sortOrder.compareTo(right.sortOrder);
      return order != 0 ? order : left.title.compareTo(right.title);
    });

    final episodes = series
        .expand((item) => item.seasons)
        .expand((season) => season.episodes)
        .toList(growable: false);
    final logicalHash = stableHash([
      1,
      ...episodes
          .map((episode) => '${episode.logicalKey}:${episode.logicalHash}')
          .toList()
        ..sort(),
      ...infoPages.map((page) => '${page.logicalKey}:${page.logicalHash}'),
    ]);
    final locatorHash = stableHash([
      1,
      ...episodes
          .expand(
            (episode) => episode.mediaSources.map(
              (source) => '${episode.logicalKey}:${source.locatorHash}',
            ),
          )
          .toList()
        ..sort(),
    ]);

    return ScrapedCatalog(
      fetchedAt: DateTime.now().toUtc(),
      logicalHash: logicalHash,
      locatorHash: locatorHash,
      visitedPageCount: visited.length,
      successfulPageUrls: Set.unmodifiable(successfulPages),
      failedPageUrls: Set.unmodifiable(failedPages),
      crawlComplete: queue.isEmpty && failedPages.isEmpty,
      series: List.unmodifiable(series),
      infoPages: List.unmodifiable(infoPages),
      issues: List.unmodifiable(issues),
    );
  }
}
