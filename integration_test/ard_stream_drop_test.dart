/// ARD Playback: the connection drops after an episode started playing.
///
/// just_audio 0.10 reports such a failure on `errorStream` only and leaves
/// its `playing` flag set. Missing it left the player claiming to play a
/// silent episode, and a tap on the same card was ignored as a repeat
/// until another card had played.
///
/// A local server stands in for the CDN: it serves the start of a real
/// episode, then drops every connection, as a network that goes away
/// mid-story would.
library;

import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest('a stream that drops mid-playback surfaces an error', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    await clearAppState($);

    final container = getContainer($);
    final episode = await getStableTestEpisode(container);
    final server = await _DroppingServer.start(episode.audioUrl);
    addTearDown(server.close);

    final itemId = await insertTestEpisode(
      $,
      TestArdEpisode(
        showId: episode.showId,
        showTitle: episode.showTitle,
        episodeTitle: episode.episodeTitle,
        audioUrl: server.url,
        durationSeconds: episode.durationSeconds,
        providerUri: episode.providerUri,
      ),
    );

    final notifier = container.read(playerProvider.notifier);
    unawaited(notifier.playCard(itemId));

    // The episode loads and plays from what the server sent.
    await waitForPlayback($);

    // Once the sent bytes run out, the failure reaches the parent as an
    // error and the player no longer claims to play.
    await waitForCondition(
      $,
      () async => container.read(playerProvider).error != null,
      description: 'an error after the stream dropped',
      timeout: const Duration(seconds: 90),
    );
    final failed = container.read(playerProvider);
    expect(failed.error, PlayerError.playbackFailed);
    expect(failed.isPlaying, isFalse);

    // A tap on the same card tries the episode again.
    notifier.clearError();
    final requestsBefore = server.requests;
    unawaited(notifier.playCard(itemId));
    await waitForCondition(
      $,
      () async => server.requests > requestsBefore,
      description: 'a new request for the episode',
      timeout: const Duration(seconds: 10),
    );

    await stopPlayback($);
  });
}

/// Serves the first [_budget] bytes of an episode across all requests,
/// honoring ranges, and drops every connection after that.
class _DroppingServer {
  _DroppingServer._(this._server, this._head, this._totalLength) {
    _server.listen(_serve);
  }

  /// About 12 seconds of a 128 kbit/s MP3: enough to load and start.
  static const _budget = 200 * 1024;

  static Future<_DroppingServer> start(String upstreamUrl) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(upstreamUrl));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${_budget - 1}');
      final response = await request.close();
      final head = await response.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      final contentRange = response.headers.value(
        HttpHeaders.contentRangeHeader,
      );
      final totalLength = int.parse(contentRange!.split('/').last);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      return _DroppingServer._(server, head, totalLength);
    } finally {
      client.close();
    }
  }

  final HttpServer _server;
  final List<int> _head;
  final int _totalLength;
  int _sent = 0;

  /// Requests the player made so far.
  int requests = 0;

  String get url => 'http://127.0.0.1:${_server.port}/episode.mp3';

  Future<void> _serve(HttpRequest request) async {
    requests++;
    final start = _rangeStart(request) ?? 0;
    final response =
        request.response
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..contentLength = _totalLength - start;
    if (start > 0) {
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${_totalLength - 1}/$_totalLength',
        );
    }
    final socket = await response.detachSocket();
    final end = (start + _budget - _sent).clamp(start, _head.length);
    if (end > start) {
      socket.add(_head.sublist(start, end));
      _sent += end - start;
      await socket.flush();
    }
    socket.destroy();
  }

  static int? _rangeStart(HttpRequest request) {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match = RegExp(r'bytes=(\d+)-').firstMatch(range ?? '');
    return match == null ? null : int.parse(match.group(1)!);
  }

  Future<void> close() => _server.close(force: true);
}
