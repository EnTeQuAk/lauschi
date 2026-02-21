import 'package:drift/drift.dart';

/// Tracks subscribed external shows for automated sync.
///
/// A subscription links an external show (e.g. ARD programSet) to a Group.
/// The sync service periodically checks for new episodes and adds them
/// as Cards to the linked Group.
@DataClassName('ShowSubscription')
class ShowSubscriptions extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Provider identifier: 'ard_audiothek', etc.
  TextColumn get provider => text()();

  /// External show/programSet ID (string for cross-provider compat).
  TextColumn get externalShowId => text()();

  /// Show title (cached from API for display without network).
  TextColumn get title => text()();

  /// Show artwork URL (cached).
  TextColumn get coverUrl => text().nullable()();

  /// Linked Group ID in the Groups table.
  /// Cascade delete: removing a group removes its subscriptions.
  TextColumn get groupId =>
      text().references(Groups, #id, onDelete: KeyAction.cascade)();

  /// Max episodes to keep. Null = all published.
  /// For rolling shows (Betthupferl, Sandmännchen), cap at e.g. 20.
  IntColumn get maxEpisodes => integer().nullable()();

  /// When we last synced this subscription.
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();

  /// Last known `lastItemAdded` from the external API.
  /// Used for change detection: if the API value is newer, fetch new episodes.
  DateTimeColumn get remoteLastItemAdded => dateTime().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('CardGroup')
class Groups extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get coverUrl => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Content type: 'hoerspiel' (default), 'music', 'audiobook'.
  /// Affects playback behaviour (auto-advance, shuffle, progress tracking).
  TextColumn get contentType =>
      text().withDefault(const Constant('hoerspiel'))();

  /// Provider for this group's content. Null for mixed/manual groups.
  /// Used to determine sync behaviour and show provider badges.
  /// Values: 'spotify', 'ard_audiothek', 'apple_music'.
  TextColumn get provider => text().nullable()();

  /// External show ID for sync. For ARD: programSet numeric ID.
  /// For Apple Music (future): show/station ID.
  /// Null for manually-curated groups.
  TextColumn get externalShowId => text().nullable()();

  /// When this group was last synced with its external show.
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('NfcTag')
class NfcTags extends Table {
  /// Auto-incrementing primary key.
  IntColumn get id => integer().autoIncrement()();

  /// Hardware UID of the NFC tag (hex string). Unique per physical tag.
  TextColumn get tagUid => text().unique()();

  /// What this tag points to: 'group' or 'card'.
  TextColumn get targetType => text()();

  /// ID of the group or card this tag triggers.
  TextColumn get targetId => text()();

  /// User-provided label (e.g. "Yakari-Figur").
  TextColumn get label => text().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('AudioCard')
class Cards extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get customTitle => text().nullable()();
  TextColumn get coverUrl => text().nullable()();
  TextColumn get customCoverPath => text().nullable()();

  // 'album' | 'playlist' | 'track' | 'podcast'
  TextColumn get cardType => text()();

  // 'spotify' | 'apple_music' | 'local'
  TextColumn get provider => text().withDefault(const Constant('spotify'))();

  // e.g. 'spotify:album:4aawyAB9vmqN3uQ7FjRGTy'
  TextColumn get providerUri => text()();

  // Comma-separated Spotify artist IDs as returned by the search API.
  // Stored at insert time so retroactive catalog matching can use artist ID
  // phase-2 even for albums whose titles omit the series name.
  TextColumn get spotifyArtistIds => text().nullable()();

  // Group membership (nullable — ungrouped cards appear at top level)
  TextColumn get groupId => text().nullable().references(Groups, #id)();
  IntColumn get episodeNumber => integer().nullable()();
  BoolColumn get isHeard => boolean().withDefault(const Constant(false))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Total number of tracks in this album (from Spotify at insert time).
  /// Used to compute playback progress and detect album completion.
  IntColumn get totalTracks => integer().withDefault(const Constant(0))();

  /// When this content expires and becomes unavailable.
  /// Null means permanent (Spotify, some ARD shows like Figarino/Kakadu).
  DateTimeColumn get availableUntil => dateTime().nullable()();

  /// Direct audio URL for non-SDK providers (ARD Audiothek, local, etc.).
  /// Null for Spotify/Apple Music (playback via SDK, not direct URL).
  TextColumn get audioUrl => text().nullable()();

  /// Total duration in milliseconds. For Spotify this comes from the SDK
  /// at runtime; for direct-play providers it's stored at insert time
  /// since there's no SDK to query.
  IntColumn get durationMs => integer().withDefault(const Constant(0))();

  // Playback resume state
  TextColumn get lastTrackUri => text().nullable()();

  /// 1-based track number within the album, stored alongside lastTrackUri
  /// so progress can be computed without an API lookup.
  IntColumn get lastTrackNumber => integer().withDefault(const Constant(0))();
  IntColumn get lastPositionMs => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
