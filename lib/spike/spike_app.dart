import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'player_bridge.dart';
import 'spike_logger.dart';
import 'spotify_auth.dart';

// Well-known Spotify URIs for testing.
const _testUris = [
  ('Die drei ???  (Folge 1)', 'spotify:album:4cTBMsO0dKN7aQrjOGVmb2'),
  ('Bibi Blocksberg (Folge 1)', 'spotify:album:3IWEpzF0gPPPNtyFiTXhT7'),
  ('Test track', 'spotify:track:4iV5W9uYEdYUVa79Axb7Rh'),
];

class SpikeApp extends StatefulWidget {
  const SpikeApp({super.key});

  @override
  State<SpikeApp> createState() => _SpikeAppState();
}

class _SpikeAppState extends State<SpikeApp> {
  SpotifyTokens? _tokens;
  final _bridge = SpotifyPlayerBridge();
  final _logs = <LogEntry>[];
  StreamSubscription<LogEntry>? _logSub;

  PlayerStateChanged? _playerState;
  bool _playerReady = false;
  bool _bridgeInitialised = false;

  LogLevel _filterLevel = LogLevel.debug;

  // Background test
  Timer? _bgTimer;
  int _bgSecondsElapsed = 0;
  bool _bgTestRunning = false;

  @override
  void initState() {
    super.initState();
    _logSub = L.stream.listen((entry) {
      setState(() {
        _logs.insert(0, entry);
        if (_logs.length > 200) _logs.removeLast();
      });
    });
    _tryLoadStoredTokens();
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _bgTimer?.cancel();
    _bridge.dispose();
    super.dispose();
  }

  Future<void> _tryLoadStoredTokens() async {
    final tokens = await SpotifyAuth.loadStored();
    if (tokens != null) {
      setState(() => _tokens = tokens);
      await _initBridge(tokens);
    }
  }

  Future<void> _login() async {
    L.info('app', 'Login tapped');
    try {
      final tokens = await SpotifyAuth.login();
      setState(() => _tokens = tokens);
      await _initBridge(tokens);
    } catch (e) {
      L.error('app', 'Login failed', data: {'error': e.toString()});
    }
  }

  Future<void> _logout() async {
    L.info('app', 'Logout tapped');
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
          L.info('app', 'Player READY', data: {'device_id': deviceId});
        case PlayerNotReady():
          setState(() => _playerReady = false);
          L.warn('app', 'Player NOT READY');
        case PlayerStateChanged():
          setState(() => _playerState = event);
        case PlayerError(:final type, :final message):
          L.error('app', 'Player error', data: {'type': type, 'message': message});
      }
    });
  }

  void _startBgTest() {
    _bgSecondsElapsed = 0;
    _bgTestRunning = true;
    L.info('app', 'Background test started — background the app NOW');
    _bgTimer?.cancel();
    _bgTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _bgSecondsElapsed += 5;
      final paused = _playerState?.paused ?? true;
      L.info('app', 'Background test tick', data: {
        'elapsed_s': _bgSecondsElapsed.toString(),
        'audio': paused ? 'PAUSED ❌' : 'playing ✅',
        'track': _playerState?.track?.name ?? 'none',
      });
      if (_bgSecondsElapsed >= 120) {
        _bgTimer?.cancel();
        setState(() => _bgTestRunning = false);
        L.info('app', 'Background test complete (120s)');
      }
    });
    setState(() {});
  }

  void _stopBgTest() {
    _bgTimer?.cancel();
    L.info('app', 'Background test stopped', data: {'elapsed_s': _bgSecondsElapsed.toString()});
    setState(() => _bgTestRunning = false);
  }

  List<LogEntry> get _filteredLogs =>
      _logs.where((e) => e.level.index >= _filterLevel.index).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('lauschi — Spotify spike'),
        backgroundColor: const Color(0xFF1DB954),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all, size: 20),
            tooltip: 'Copy logs',
            onPressed: () {
              final text = _filteredLogs.reversed.map((e) => e.toString()).join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs copied'), duration: Duration(seconds: 1)),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Clear logs',
            onPressed: () => setState(() => _logs.clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildAuthBar(),
          const Divider(height: 1),
          _buildPlayerState(),
          const Divider(height: 1),
          _buildControls(),
          const Divider(height: 1),
          _buildLevelFilter(),
          const Divider(height: 1),
          Expanded(child: _buildLogPanel()),
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
        dense: true,
        leading: const Icon(Icons.login, color: Color(0xFF1DB954)),
        title: const Text('Not connected'),
        trailing: ElevatedButton(
          onPressed: _login,
          child: const Text('Login with Spotify'),
        ),
      );
    }
    return ListTile(
      dense: true,
      leading: Icon(
        _playerReady ? Icons.check_circle : Icons.hourglass_empty,
        color: _playerReady ? Colors.green : Colors.orange,
        size: 20,
      ),
      title: Text(
        _playerReady ? 'Player ready' : 'Waiting for player…',
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        'Expires ${_tokens!.expiry.toLocal().toString().substring(0, 19)}',
        style: const TextStyle(fontSize: 10),
      ),
      trailing: TextButton(onPressed: _logout, child: const Text('Logout')),
    );
  }

  Widget _buildPlayerState() {
    final state = _playerState;
    if (state == null || state.track == null) {
      return const ListTile(
        dense: true,
        leading: Icon(Icons.music_off, color: Colors.grey, size: 20),
        title: Text('Nothing playing', style: TextStyle(fontSize: 13)),
      );
    }
    final track = state.track!;
    final pos = Duration(milliseconds: state.positionMs);
    final dur = Duration(milliseconds: state.durationMs);
    return ListTile(
      dense: true,
      leading: track.artworkUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(track.artworkUrl!, width: 40, height: 40, fit: BoxFit.cover),
            )
          : const Icon(Icons.album, size: 40),
      title: Text(track.name, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13)),
      subtitle: Text('${track.artist} · ${_fmt(pos)} / ${_fmt(dur)}',
          style: const TextStyle(fontSize: 11)),
      trailing: Icon(
        state.paused ? Icons.pause_circle : Icons.play_circle,
        color: const Color(0xFF1DB954),
        size: 28,
      ),
    );
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  Widget _buildControls() {
    return Column(
      children: [
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
              iconSize: 44,
              color: const Color(0xFF1DB954),
              onPressed: _playerReady ? _bridge.togglePlay : null,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              onPressed: _playerReady ? _bridge.nextTrack : null,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Wrap(
            spacing: 6,
            children: [
              for (final (label, uri) in _testUris)
                OutlinedButton(
                  onPressed: _playerReady ? () => _bridge.play(uri) : null,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(label, style: const TextStyle(fontSize: 11)),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.timer_outlined, size: 16),
              const SizedBox(width: 4),
              const Text('BG test:', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 6),
              if (!_bgTestRunning)
                SizedBox(
                  height: 28,
                  child: ElevatedButton(
                    onPressed: _playerReady && !(_playerState?.paused ?? true)
                        ? _startBgTest
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    child: const Text('Start (play audio first)'),
                  ),
                )
              else
                Row(children: [
                  Text('${_bgSecondsElapsed}s / 120s',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.orange, fontSize: 12)),
                  const SizedBox(width: 6),
                  SizedBox(
                    height: 24,
                    child: TextButton(
                      onPressed: _stopBgTest,
                      child: const Text('Stop', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ]),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLevelFilter() {
    const levels = [
      (LogLevel.debug, 'All', Colors.grey),
      (LogLevel.info, 'Info', Colors.blue),
      (LogLevel.warn, 'Warn', Colors.orange),
      (LogLevel.error, 'Error', Colors.red),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const Text('Show:', style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(width: 6),
          for (final (level, label, color) in levels)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ChoiceChip(
                label: Text(label, style: const TextStyle(fontSize: 11)),
                selected: _filterLevel == level,
                selectedColor: color.withValues(alpha: 0.2),
                onSelected: (_) => setState(() => _filterLevel = level),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          const Spacer(),
          Text(
            '${_filteredLogs.length} entries',
            style: const TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildLogPanel() {
    final logs = _filteredLogs;
    if (logs.isEmpty) {
      return const Center(
        child: Text('No logs yet', style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    return ListView.builder(
      itemCount: logs.length,
      itemBuilder: (ctx, i) {
        final entry = logs[i];
        return _LogRow(entry: entry);
      },
    );
  }
}

class _LogRow extends StatelessWidget {
  final LogEntry entry;
  const _LogRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final (color, bgColor) = switch (entry.level) {
      LogLevel.error => (Colors.red[700]!, Colors.red[50]!),
      LogLevel.warn  => (Colors.orange[800]!, Colors.orange[50]!),
      LogLevel.info  => (Colors.blue[800]!, Colors.transparent),
      LogLevel.debug => (Colors.grey[600]!, Colors.transparent),
    };

    final ts = '${entry.time.hour.toString().padLeft(2, '0')}:'
        '${entry.time.minute.toString().padLeft(2, '0')}:'
        '${entry.time.second.toString().padLeft(2, '0')}.'
        '${(entry.time.millisecond ~/ 10).toString().padLeft(2, '0')}';

    return Container(
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ts, style: TextStyle(fontSize: 10, color: Colors.grey[500], fontFamily: 'monospace')),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              entry.source,
              style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.message,
                  style: TextStyle(fontSize: 11, color: color, fontFamily: 'monospace'),
                ),
                if (entry.data != null && entry.data!.isNotEmpty)
                  Text(
                    entry.data!.entries
                        .map((e) {
                          final v = e.value?.toString() ?? 'null';
                          return '${e.key}: ${v.length > 120 ? '${v.substring(0, 117)}…' : v}';
                        })
                        .join('  '),
                    style: TextStyle(
                      fontSize: 10,
                      color: color.withValues(alpha: 0.8),
                      fontFamily: 'monospace',
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
