enum ScrapedContentKind { episode, short, special, movie }

enum ScrapedAvailability { available, announced }

final class ScrapedMediaSource {
  const ScrapedMediaSource({
    required this.provider,
    required this.remoteId,
    required this.openUrl,
    required this.previewUrl,
    required this.downloadUrl,
    required this.thumbnailUrl,
    required this.locatorHash,
  });

  final String provider;
  final String remoteId;
  final Uri openUrl;
  final Uri previewUrl;
  final Uri downloadUrl;
  final Uri thumbnailUrl;
  final String locatorHash;
}

final class ScrapedEpisode {
  const ScrapedEpisode({
    required this.logicalKey,
    required this.number,
    required this.title,
    required this.synopsis,
    required this.kind,
    required this.availability,
    required this.sortOrder,
    required this.logicalHash,
    this.mediaSources = const [],
  });

  final String logicalKey;
  final int? number;
  final String title;
  final String synopsis;
  final ScrapedContentKind kind;
  final ScrapedAvailability availability;
  final int sortOrder;
  final String logicalHash;
  final List<ScrapedMediaSource> mediaSources;

  ScrapedMediaSource? get mediaSource => mediaSources.firstOrNull;
}

final class ScrapedSeason {
  const ScrapedSeason({
    required this.logicalKey,
    required this.sourceUrl,
    required this.sourcePageKey,
    required this.title,
    required this.synopsis,
    required this.sortOrder,
    required this.logicalHash,
    required this.episodes,
    this.displayNumber,
    this.canonicalCode,
  });

  final String logicalKey;
  final Uri sourceUrl;
  final String sourcePageKey;
  final String title;
  final String synopsis;
  final int? displayNumber;
  final int? canonicalCode;
  final int sortOrder;
  final String logicalHash;
  final List<ScrapedEpisode> episodes;
}

final class ScrapedSeries {
  const ScrapedSeries({
    required this.logicalKey,
    required this.title,
    required this.sortOrder,
    required this.logicalHash,
    required this.seasons,
  });

  final String logicalKey;
  final String title;
  final int sortOrder;
  final String logicalHash;
  final List<ScrapedSeason> seasons;
}

final class ScrapeIssue {
  const ScrapeIssue({
    required this.url,
    required this.message,
    this.isFatal = false,
  });

  final Uri url;
  final String message;
  final bool isFatal;
}

final class ScrapedInfoLink {
  const ScrapedInfoLink({required this.label, required this.url});

  final String label;
  final Uri url;
}

final class ScrapedInfoPage {
  const ScrapedInfoPage({
    required this.logicalKey,
    required this.sourceUrl,
    required this.title,
    required this.body,
    required this.links,
    required this.sortOrder,
    required this.logicalHash,
  });

  final String logicalKey;
  final Uri sourceUrl;
  final String title;
  final String body;
  final List<ScrapedInfoLink> links;
  final int sortOrder;
  final String logicalHash;
}

final class ScrapedCatalog {
  const ScrapedCatalog({
    required this.fetchedAt,
    required this.logicalHash,
    required this.locatorHash,
    required this.visitedPageCount,
    required this.successfulPageUrls,
    required this.failedPageUrls,
    required this.crawlComplete,
    required this.series,
    required this.infoPages,
    required this.issues,
  });

  final DateTime fetchedAt;
  final String logicalHash;
  final String locatorHash;
  final int visitedPageCount;
  final Set<Uri> successfulPageUrls;
  final Set<Uri> failedPageUrls;
  final bool crawlComplete;
  final List<ScrapedSeries> series;
  final List<ScrapedInfoPage> infoPages;
  final List<ScrapeIssue> issues;

  int get episodeCount => series.fold(
    0,
    (seriesTotal, item) =>
        seriesTotal +
        item.seasons.fold(
          0,
          (seasonTotal, season) => seasonTotal + season.episodes.length,
        ),
  );
}

final class ParsedSitePage {
  const ParsedSitePage({
    required this.url,
    required this.internalLinks,
    required this.issues,
    this.seriesKey,
    this.seriesTitle,
    this.season,
    this.infoPage,
  });

  final Uri url;
  final Set<Uri> internalLinks;
  final List<ScrapeIssue> issues;
  final String? seriesKey;
  final String? seriesTitle;
  final ScrapedSeason? season;
  final ScrapedInfoPage? infoPage;
}
