import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [Cards])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'lauschi');
  }
}

@Riverpod(keepAlive: true)
AppDatabase appDatabase(AppDatabaseRef ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
}
