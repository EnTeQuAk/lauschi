import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/ard/ard_availability_recheck.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/ard/audio_file_check.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';

/// Real HTTP clients, even where a widget test binding in the same isolate
/// installed its own overrides that answer every request with 400.
class _RealHttp extends HttpOverrides {}

/// Lists every episode as published with the audio URL in [urls], the way
/// ARD keeps listing episodes whose files are deleted.
class _FakeArdApi extends ArdApi {
  _FakeArdApi(this.urls);

  final Map<String, String> urls;

  @override
  Future<ArdItem?> getItem(String itemId) async => ArdItem(
    id: itemId,
    title: 'Folge $itemId',
    publishDate: DateTime(2022, 3),
    audios: [ArdAudio(url: urls[itemId]!, mimeType: 'audio/mp3')],
  );
}

void main() {
  late AppDatabase db;
  late TileItemRepository items;
  late HttpServer cdn;

  /// The CDN has the files under /present/ and nothing else.
  String url(String path) => 'http://127.0.0.1:${cdn.port}/$path';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    items = TileItemRepository(db);
    cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((request) async {
        request.response.statusCode =
            request.uri.path.startsWith('/present/')
                ? HttpStatus.ok
                : HttpStatus.notFound;
        await request.response.close();
      });
  });

  tearDown(() async {
    await cdn.close(force: true);
    await db.close();
  });

  /// An episode marked unavailable long enough ago to be rechecked.
  Future<String> markedEpisode(String ardId, String audioUrl) async {
    final id = await items.insertArdEpisode(
      title: 'Folge $ardId',
      providerUri: 'ard:item:$ardId',
      audioUrl: audioUrl,
    );
    await (db.update(db.cards)..where((t) => t.id.equals(id))).write(
      CardsCompanion(
        markedUnavailable: Value(
          DateTime.now().subtract(const Duration(days: 8)),
        ),
      ),
    );
    return id;
  }

  Future<void> recheck(Map<String, String> urls) =>
      HttpOverrides.runWithHttpOverrides(
        () => recheckArdAvailability(
          api: _FakeArdApi(urls),
          files: AudioFileCheck(),
          items: items,
        ),
        _RealHttp(),
      );

  test('an episode ARD lists but whose file is gone stays marked', () async {
    final id = await markedEpisode('1', url('gone/1.mp3'));

    await recheck({'1': url('gone/1.mp3')});

    expect((await items.getById(id))?.markedUnavailable, isNotNull);
  });

  test('an episode whose file is back is playable again', () async {
    final id = await markedEpisode('2', url('present/2.mp3'));

    await recheck({'2': url('present/2.mp3')});

    final item = await items.getById(id);
    expect(item?.markedUnavailable, isNull);
    expect(item?.audioUrl, url('present/2.mp3'));
  });

  test('an episode back at another URL keeps the new one', () async {
    final id = await markedEpisode('3', url('gone/3.mp3'));

    await recheck({'3': url('present/3-new.mp3')});

    final item = await items.getById(id);
    expect(item?.markedUnavailable, isNull);
    expect(item?.audioUrl, url('present/3-new.mp3'));
  });
}
