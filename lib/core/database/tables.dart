import 'package:drift/drift.dart';

// ignore_for_file: prefer_mixin

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

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
