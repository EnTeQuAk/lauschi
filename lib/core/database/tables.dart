import 'package:drift/drift.dart';

@DataClassName('CardGroup')
class Groups extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get coverUrl => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
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

  // Playback resume state
  TextColumn get lastTrackUri => text().nullable()();
  IntColumn get lastPositionMs => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
