/// Data models for ARD Audiothek API responses.
///
/// Maps to GraphQL schema types: ProgramSet, Item, and nested
/// audio/image structures. Only fields relevant to lauschi are included.
library;

class ArdProgramSet {
  const ArdProgramSet({
    required this.id,
    required this.title,
    this.synopsis,
    this.numberOfElements = 0,
    this.lastItemAdded,
    this.feedUrl,
    this.imageUrl,
    this.publisher,
    this.showType,
    this.description,
    this.organizationName,
    this.brandingColor,
  });

  factory ArdProgramSet.fromJson(Map<String, dynamic> json) {
    final image = json['image'] as Map<String, dynamic>?;
    final pubService = json['publicationService'] as Map<String, dynamic>?;
    final org = pubService?['organization'] as Map<String, dynamic>?;

    return ArdProgramSet(
      id: '${json['id']}',
      title: json['title'] as String? ?? '',
      synopsis: json['synopsis'] as String?,
      numberOfElements: json['numberOfElements'] as int? ?? 0,
      lastItemAdded: _tryParseDateTime(json['lastItemAdded']),
      feedUrl: json['feedUrl'] as String?,
      imageUrl: (image?['url1X1'] ?? image?['url']) as String?,
      publisher: pubService?['title'] as String?,
      showType: json['showType'] as String?,
      description: json['description'] as String?,
      organizationName: org?['name'] as String?,
      brandingColor: pubService?['brandingColor'] as String?,
    );
  }

  final String id;
  final String title;
  final String? synopsis;
  final int numberOfElements;
  final DateTime? lastItemAdded;
  final String? feedUrl;
  final String? imageUrl;
  final String? publisher;

  /// ARD show type: INFINITE_SERIES, FINITE_SERIES, SEASON_SERIES, SINGLE.
  final String? showType;

  /// HTML description, richer than synopsis. May contain age ranges.
  final String? description;

  /// Short broadcaster name (e.g., "BR", "WDR", "NDR").
  final String? organizationName;

  /// Publisher hex brand color (e.g., "#FF6B00").
  final String? brandingColor;
}

class ArdItem {
  const ArdItem({
    required this.id,
    required this.title,
    required this.publishDate,
    this.titleClean,
    this.synopsis,
    this.duration = 0,
    this.episodeNumber,
    this.isPublished = true,
    this.endDate,
    this.imageUrl,
    this.programSetTitle,
    this.audios = const [],
  });

  factory ArdItem.fromJson(Map<String, dynamic> json) {
    final image = json['image'] as Map<String, dynamic>?;
    final programSet = json['programSet'] as Map<String, dynamic>?;

    final audioList = json['audios'] as List<dynamic>? ?? [];
    final audios =
        audioList
            .map((a) => ArdAudio.fromJson(a as Map<String, dynamic>))
            .toList();

    return ArdItem(
      id: '${json['id']}',
      title: json['title'] as String? ?? '',
      titleClean: json['titleClean'] as String?,
      synopsis: json['synopsis'] as String?,
      duration: json['duration'] as int? ?? 0,
      publishDate: _tryParseDateTime(json['publishDate']) ?? DateTime.now(),
      episodeNumber: json['episodeNumber'] as int?,
      isPublished: json['isPublished'] as bool? ?? true,
      endDate: _tryParseDateTime(json['endDate']),
      imageUrl: (image?['url1X1'] ?? image?['url']) as String?,
      programSetTitle: programSet?['title'] as String?,
      audios: audios,
    );
  }

  final String id;
  final String title;

  /// Title with suffixes stripped (age/broadcaster/genre info removed).
  /// Falls back to [title] when null.
  final String? titleClean;
  final String? synopsis;

  /// Duration in seconds.
  final int duration;
  final DateTime publishDate;
  final int? episodeNumber;
  final bool isPublished;

  /// When this content expires. Null means permanent or unspecified.
  final DateTime? endDate;
  final String? imageUrl;
  final String? programSetTitle;
  final List<ArdAudio> audios;

  /// Clean display title, stripping suffixes like age recommendations.
  String get displayTitle => titleClean ?? title;

  /// Duration in milliseconds (for lauschi's internal format).
  int get durationMs => duration * 1000;

  /// Best audio URL: prefer MP3 for widest compat, fallback to any.
  String? get bestAudioUrl {
    final mp3 = audios.where((a) => a.mimeType.contains('mp3')).toList();
    if (mp3.isNotEmpty) return mp3.first.url;
    return audios.isNotEmpty ? audios.first.url : null;
  }

  /// Provider URI for this item in lauschi's format.
  String get providerUri => 'ard:item:$id';
}

/// Audio asset from ARD Audiothek (AssetType in the GraphQL schema).
class ArdAudio {
  const ArdAudio({
    required this.url,
    required this.mimeType,
  });

  factory ArdAudio.fromJson(Map<String, dynamic> json) {
    return ArdAudio(
      url: json['url'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'audio/mp3',
    );
  }

  final String url;

  /// MIME type, e.g. 'audio/mp3', 'audio/mp4'.
  final String mimeType;
}

/// Paginated result of ArdItem queries.
class ArdItemPage {
  const ArdItemPage({
    required this.items,
    this.hasNextPage = false,
    this.endCursor,
    this.totalCount = 0,
  });

  final List<ArdItem> items;
  final bool hasNextPage;
  final String? endCursor;
  final int totalCount;
}

DateTime? _tryParseDateTime(Object? value) {
  if (value == null) return null;
  if (value is String) return DateTime.tryParse(value);
  return null;
}
