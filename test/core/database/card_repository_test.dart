import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/card_repository.dart';

void main() {
  late AppDatabase db;
  late CardRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = CardRepository(db);
  });

  tearDown(() => db.close());

  test('insert and getAll returns the card', () async {
    final id = await repo.insert(
      title: 'Test Album',
      providerUri: 'spotify:album:abc123',
      cardType: 'album',
    );

    final cards = await repo.getAll();
    expect(cards, hasLength(1));
    expect(cards.first.id, id);
    expect(cards.first.title, 'Test Album');
    expect(cards.first.providerUri, 'spotify:album:abc123');
  });

  test('insertIfAbsent deduplicates by providerUri', () async {
    final id1 = await repo.insertIfAbsent(
      title: 'Album A',
      providerUri: 'spotify:album:abc123',
      cardType: 'album',
    );
    final id2 = await repo.insertIfAbsent(
      title: 'Album A Again',
      providerUri: 'spotify:album:abc123',
      cardType: 'album',
    );

    expect(id2, id1);
    final cards = await repo.getAll();
    expect(cards, hasLength(1));
  });

  test('sortOrder auto-increments', () async {
    await repo.insert(
      title: 'First',
      providerUri: 'spotify:album:1',
      cardType: 'album',
    );
    await repo.insert(
      title: 'Second',
      providerUri: 'spotify:album:2',
      cardType: 'album',
    );

    final cards = await repo.getAll();
    expect(cards[0].sortOrder, 0);
    expect(cards[1].sortOrder, 1);
  });

  test('delete removes the card', () async {
    final id = await repo.insert(
      title: 'To Delete',
      providerUri: 'spotify:album:del',
      cardType: 'album',
    );

    await repo.delete(id);
    final cards = await repo.getAll();
    expect(cards, isEmpty);
  });

  test('savePosition and getByProviderUri persist playback state', () async {
    final id = await repo.insert(
      title: 'Audiobook',
      providerUri: 'spotify:album:book1',
      cardType: 'album',
    );

    await repo.savePosition(
      cardId: id,
      trackUri: 'spotify:track:ch5',
      positionMs: 45000,
    );

    final card = await repo.getByProviderUri('spotify:album:book1');
    expect(card, isNotNull);
    expect(card!.lastTrackUri, 'spotify:track:ch5');
    expect(card.lastPositionMs, 45000);
    expect(card.lastPlayedAt, isNotNull);
  });

  test('lastPlayed returns most recently played card', () async {
    await repo.insert(
      title: 'Old',
      providerUri: 'spotify:album:old',
      cardType: 'album',
    );
    final newId = await repo.insert(
      title: 'New',
      providerUri: 'spotify:album:new',
      cardType: 'album',
    );

    await repo.savePosition(
      cardId: newId,
      trackUri: 'spotify:track:t1',
      positionMs: 1000,
    );

    final last = await repo.lastPlayed();
    expect(last, isNotNull);
    expect(last!.title, 'New');
  });

  test('reorder updates sortOrder for all cards', () async {
    final id1 = await repo.insert(
      title: 'A',
      providerUri: 'spotify:album:a',
      cardType: 'album',
    );
    final id2 = await repo.insert(
      title: 'B',
      providerUri: 'spotify:album:b',
      cardType: 'album',
    );

    // Reverse order
    await repo.reorder([id2, id1]);

    final cards = await repo.getAll();
    expect(cards[0].id, id2);
    expect(cards[1].id, id1);
  });

  test('spotifyArtistIds stored as comma-separated string', () async {
    final id = await repo.insert(
      title: 'Folge 38: Eile mit Weile',
      providerUri: 'spotify:album:yakari38',
      cardType: 'album',
      spotifyArtistIds: ['5BOhng5bYwJNOR8ckMWpUg', '2ndArtistId'],
    );

    final card = await repo.getById(id);
    expect(card!.spotifyArtistIds, '5BOhng5bYwJNOR8ckMWpUg,2ndArtistId');
  });

  test('spotifyArtistIds null when not provided', () async {
    final id = await repo.insert(
      title: 'Some Album',
      providerUri: 'spotify:album:noartist',
      cardType: 'album',
    );

    final card = await repo.getById(id);
    expect(card!.spotifyArtistIds, isNull);
  });

  test(
    'insertIfAbsent does not overwrite existing card on duplicate URI',
    () async {
      await repo.insertIfAbsent(
        title: 'Original Title',
        providerUri: 'spotify:album:dup',
        cardType: 'album',
        spotifyArtistIds: ['artist1'],
      );
      await repo.insertIfAbsent(
        title: 'New Title',
        providerUri: 'spotify:album:dup',
        cardType: 'album',
        spotifyArtistIds: ['artist2'],
      );

      final cards = await repo.getAll();
      expect(cards, hasLength(1));
      // Original card is preserved unchanged
      expect(cards.first.title, 'Original Title');
      expect(cards.first.spotifyArtistIds, 'artist1');
    },
  );
}
