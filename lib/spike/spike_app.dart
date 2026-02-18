import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'player_bridge.dart';
import 'spotify_auth.dart';

// Well-known Spotify URIs for testing.
const _testUris = [
  ('Die drei ???  (Folge 1)', 'spotify:album:4cTBMsO0dKN7aQrjOGVmb2'),
  ('Bibi Blocksberg (Folge 1)', 'spotify:album:3IWEpzF0gPPPNtyFiTXhT7'),
  ('Test: single track', 'spotify:track:4iV5W9uYEdYUVa79Axb7Rh'),
];

class SpikeApp extends StatefulWidget {
  const SpikeApp({super.key});

  @override
  State<SpikeApp> createState() => _SpikeAppState();
}

class _SpikeAppState extends State<SpikeApp> {
  SpotifyTokens? _tokens;
  final _bridge = SpotifyPlayerBridge();
  final _logs = <String>[];
  PlayerStateChanged? _playerState;
  bool _playerReady = false;
  bool _bridgeInitialised = false;

  // Background test
  Timer? _bgTimer;
  int _bgSecondsElapsed = 0;
  bool _bgTestRunning = false;

  @override
  void initState() {
    super.initState();
    _tryLoadStoredTokens();
  }

  Future<void> _tryLoadStoredTokens() async {
    final tokens = await SpotifyAuth.loadStored();
    if (tokens != null) {
      setState(() => _tokens = tokens);
      _log('Loaded stored tokens (expiry: ${tokens.expiry})');
      await _initBridge(tokens);
    }
  }

  Future<void> _login() async {
    try {
      _log('Starting Spotify OAuth...');
      final tokens = await SpotifyAuth.login();
      setState(() => _tokens = tokens);
      _log('Auth success. Expiry: ${tokens.expiry}');
      await _initBridge(tokens);
    } catch (e) {
      _log('Auth error: $e');
    }
  }

  Future<void> _logout() async {
    await SpotifyAuth.logout();
    setState(() {
      _tokens = null;
      _playerReady = false;
      _bridgeInitialised = false;
      _playerState = null;
    });
  }

  Future<void> _initBridge(SpotifyTokens tokens) async {
    if (_bridgeInitialised) return;
    _bridgeInitialised = true;

    await _bridge.init(tokens);

    _bridge.events.listen((event) {
      switch (event) {
        case PlayerReady(:final deviceId):
          setState(() => _playerReady = true);
          _log('✅ Player READY. device_id: $deviceId');
        case PlayerNotReady():
          setState(() => _playerReady = false);
          _log('⚠️  Player NOT READY');
        case PlayerStateChanged():
          setState(() => _playerState = event);
          // Log only on meaningful changes to avoid spam.
          if (event.track != null) {
            _log('▶ ${event.paused ? "⏸" : "▶"} ${event.track!.name} — ${event.track!.artist}');
          }
        case PlayerError(:final type, :final message):
          _log('❌ Error [$type]: $message');
        case PlayerLog(:final message):
          _log('[js] $message');
      }
    });
  }

  void _log(String msg) {
    setState(() {
      _logs.insert(0, '[${_timestamp()}] $msg');
      if (_logs.length > 80) _logs.removeLast();
    });
  }

  String _timestamp() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
  }

  void _startBgTest() {
    _bgSecondsElapsed = 0;
    _bgTestRunning = true;
    _log('⏱ Background test started. Background the app NOW.');
    _bgTimer?.cancel();
    _bgTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _bgSecondsElapsed += 5;
      final paused = _playerState?.paused ?? true;
      final status = paused ? '❌ PAUSED' : '✅ playing';
      _log('⏱ ${_bgSecondsElapsed}s elapsed — audio: $status');
      if (_bgSecondsElapsed >= 120) {
        _bgTimer?.cancel();
        setState(() => _bgTestRunning = false);
        _log('⏱ Background test complete (120s)');
      }
    });
    setState(() {});
  }

  void _stopBgTest() {
    _bgTimer?.cancel();
    setState(() => _bgTestRunning = false);
    _log('⏱ Background test stopped at ${_bgSecondsElapsed}s');
  }

  @override
  void dispose() {
    _bgTimer?.cancel();
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('lauschi — Spotify spike'),
        backgroundColor: const Color(0xFF1DB954),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          _buildAuthBar(),
          const Divider(height: 1),
          _buildPlayerState(),
          const Divider(height: 1),
          _buildControls(),
          const Divider(height: 1),
          Expanded(child: _buildLogPanel()),
          // Hidden WebView — must stay in the widget tree.
          if (_bridgeInitialised)
            SizedBox(
              width: 1,
              height: 1,
              child: WebViewWidget(controller: _bridge.controller),
            ),
        ],
      ),
    );
  }

  Widget _buildAuthBar() {
    if (_tokens == null) {
      return ListTile(
        leading: const Icon(Icons.login, color: Color(0xFF1DB954)),
        title: const Text('Not connected'),
        trailing: ElevatedButton(
          onPressed: _login,
          child: const Text('Login with Spotify'),
        ),
      );
    }
    return ListTile(
      leading: Icon(
        _playerReady ? Icons.check_circle : Icons.hourglass_empty,
        color: _playerReady ? Colors.green : Colors.orange,
      ),
      title: Text(_playerReady ? 'Player ready' : 'Waiting for player...'),
      subtitle: Text(
        'Token expires ${_tokens!.expiry.toLocal()}',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: TextButton(onPressed: _logout, child: const Text('Logout')),
    );
  }

  Widget _buildPlayerState() {
    final state = _playerState;
    if (state == null || state.track == null) {
      return const ListTile(
        leading: Icon(Icons.music_off, color: Colors.grey),
        title: Text('Nothing playing'),
      );
    }
    final track = state.track!;
    final pos = Duration(milliseconds: state.positionMs);
    final dur = Duration(milliseconds: state.durationMs);
    return ListTile(
      leading: track.artworkUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(track.artworkUrl!, width: 48, height: 48, fit: BoxFit.cover),
            )
          : const Icon(Icons.album),
      title: Text(track.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${track.artist} • ${_fmt(pos)} / ${_fmt(dur)}'),
      trailing: Icon(state.paused ? Icons.pause_circle : Icons.play_circle,
          color: const Color(0xFF1DB954), size: 32),
    );
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _buildControls() {
    return Column(
      children: [
        // Playback controls
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous),
              onPressed: _playerReady ? _bridge.prevTrack : null,
            ),
            IconButton(
              icon: Icon((_playerState?.paused ?? true)
                  ? Icons.play_circle_filled
                  : Icons.pause_circle_filled),
              iconSize: 48,
              color: const Color(0xFF1DB954),
              onPressed: _playerReady ? _bridge.togglePlay : null,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              onPressed: _playerReady ? _bridge.nextTrack : null,
            ),
          ],
        ),
        // Test content buttons
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 8,
            children: [
              for (final (label, uri) in _testUris)
                OutlinedButton(
                  onPressed: _playerReady ? () => _bridge.play(uri) : null,
                  child: Text(label, style: const TextStyle(fontSize: 11)),
                ),
            ],
          ),
        ),
        // Background test controls
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              const Icon(Icons.timer_outlined, size: 16),
              const SizedBox(width: 4),
              const Text('Background test:', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              if (!_bgTestRunning)
                ElevatedButton.icon(
                  onPressed: _playerReady && !(_playerState?.paused ?? true)
                      ? _startBgTest
                      : null,
                  icon: const Icon(Icons.play_arrow, size: 14),
                  label: const Text('Start', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                )
              else
                Row(
                  children: [
                    Text('${_bgSecondsElapsed}s',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange)),
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: _stopBgTest,
                      child: const Text('Stop', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              const Spacer(),
              const Text(
                'Start playback → tap Start → background the app',
                style: TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLogPanel() {
    return ListView.builder(
      reverse: true,
      itemCount: _logs.length,
      itemBuilder: (ctx, i) {
        // reverse: index 0 = most recent
        final log = _logs[i];
        final isError = log.contains('❌');
        final isSuccess = log.contains('✅');
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: Text(
            log,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: isError ? Colors.red[700] : isSuccess ? Colors.green[700] : null,
            ),
          ),
        );
      },
    );
  }
}
