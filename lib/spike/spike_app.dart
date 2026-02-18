import 'dart:async' show StreamSubscription, Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:spotify_sdk/models/player_state.dart';

import 'app_remote_client.dart';
import 'connect_client.dart';
import 'player_bridge.dart';
import 'spike_logger.dart';
import 'spotify_auth.dart';

const _testUris = [
  ('Die drei ???  (1)', 'spotify:album:4cTBMsO0dKN7aQrjOGVmb2'),
  ('Bibi Blocksberg (1)', 'spotify:album:3IWEpzF0gPPPNtyFiTXhT7'),
  ('Test track', 'spotify:track:4iV5W9uYEdYUVa79Axb7Rh'),
];

class SpikeApp extends StatefulWidget {
  const SpikeApp({super.key});

  @override
  State<SpikeApp> createState() => _SpikeAppState();
}

class _SpikeAppState extends State<SpikeApp> {
  SpotifyTokens? _tokens;

  // ── WebView SDK approach ─────────────────────────────────────────────────
  SpotifyPlayerBridge? _bridge;
  StreamSubscription<PlayerEvent>? _playerEventSub;
  PlayerStateChanged? _playerState;
  bool _playerReady = false;
  bool _bridgeInitialised = false;

  // ── Connect approach ─────────────────────────────────────────────────────
  final _connect = SpotifyConnectClient();
  List<ConnectDevice> _connectDevices = [];
  ConnectPlaybackState? _connectState;
  Timer? _connectPollTimer;

  // ── App Remote approach ───────────────────────────────────────────────────
  final _remote = AppRemoteClient();
  PlayerState? _remoteState;
  StreamSubscription<PlayerState>? _remoteStateSub;

  // ── Background test ──────────────────────────────────────────────────────
  Timer? _bgTimer;
  int _bgSecondsElapsed = 0;
  bool _bgTestRunning = false;

  // ── Logging ──────────────────────────────────────────────────────────────
  final _logs = <LogEntry>[];
  StreamSubscription<LogEntry>? _logSub;
  LogLevel _filterLevel = LogLevel.debug;

  @override
  void initState() {
    super.initState();
    _logSub = L.stream.listen((entry) {
      if (mounted) {
        setState(() {
          _logs.insert(0, entry);
          if (_logs.length > 300) _logs.removeLast();
        });
      }
    });
    _tryLoadStoredTokens();
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _bgTimer?.cancel();
    _connectPollTimer?.cancel();
    unawaited(_playerEventSub?.cancel());
    _bridge?.dispose();
    unawaited(_remoteStateSub?.cancel());
    _remote.dispose();
    super.dispose();
  }

  // ── Auth ──────────────────────────────────────────────────────────────────

  Future<void> _tryLoadStoredTokens() async {
    final tokens = await SpotifyAuth.loadStored();
    if (tokens != null) {
      setState(() {
        _tokens = tokens;
        _connect.tokens = tokens;
      });
      await _initBridge(tokens);
    }
  }

  Future<void> _login() async {
    L.info('app', 'Login tapped');
    try {
      final tokens = await SpotifyAuth.login();
      setState(() {
        _tokens = tokens;
        _connect.tokens = tokens;
      });
      await _initBridge(tokens);
    } catch (e) {
      L.error('app', 'Login failed', data: {'error': e.toString()});
    }
  }

  Future<void> _logout() async {
    L.info('app', 'Logout tapped');
    await SpotifyAuth.logout();
    _connectPollTimer?.cancel();
    await _playerEventSub?.cancel();
    _playerEventSub = null;
    _bridge?.dispose();
    await _remoteStateSub?.cancel();
    _remoteStateSub = null;
    if (_remote.connected) await _remote.disconnect();
    setState(() {
      _tokens = null;
      _connect.tokens = null;
      _playerReady = false;
      _bridgeInitialised = false;
      _playerState = null;
      _bridge = null;
      _connectDevices = [];
      _connectState = null;
      _remoteState = null;
    });
  }

  // ── WebView SDK ───────────────────────────────────────────────────────────

  Future<void> _initBridge(SpotifyTokens tokens) async {
    if (_bridgeInitialised) return;
    _bridgeInitialised = true;

    final bridge = SpotifyPlayerBridge();
    setState(() => _bridge = bridge);

    await bridge.init(tokens);

    _playerEventSub = bridge.events.listen((event) {
      switch (event) {
        case PlayerReady(:final deviceId):
          setState(() => _playerReady = true);
          L.info('app', 'WebView SDK player READY', data: {'device_id': deviceId});
        case PlayerNotReady():
          setState(() => _playerReady = false);
          L.warn('app', 'WebView SDK player NOT READY');
        case PlayerStateChanged():
          setState(() => _playerState = event);
        case PlayerError(:final type, :final message):
          L.error('app', 'WebView SDK error', data: {'type': type, 'message': message});
      }
    });
  }

  // ── Connect ───────────────────────────────────────────────────────────────

  Future<void> _connectListDevices() async {
    final devices = await _connect.getDevices();
    setState(() => _connectDevices = devices);
    if (devices.isEmpty) {
      L.warn('app', 'No Connect devices found — open Spotify app on the phone first');
    }
  }

  Future<void> _connectPlay(String deviceId, String uri) async {
    await _connect.transferPlayback(deviceId, play: false);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _connect.play(uri, deviceId: deviceId);
    _startConnectPoll();
  }

  void _startConnectPoll() {
    _connectPollTimer?.cancel();
    _connectPollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final state = await _connect.getPlaybackState();
      if (mounted) setState(() => _connectState = state);
    });
  }

  // ── App Remote ────────────────────────────────────────────────────────────

  Future<void> _connectRemote() async {
    final ok = await _remote.connect();
    if (ok) {
      await _remoteStateSub?.cancel();
      _remoteStateSub = _remote.playerState.listen((state) {
        setState(() => _remoteState = state);
      });
    }
  }

  // ── Background test (Connect version) ────────────────────────────────────

  void _startBgTest() {
    _bgSecondsElapsed = 0;
    _bgTestRunning = true;
    L.info('app', 'Background test started — background the app NOW');
    _bgTimer?.cancel();
    _bgTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      _bgSecondsElapsed += 5;
      // Poll Connect state for background test (works even when app is backgrounded
      // because the Spotify app handles playback independently).
      final state = await _connect.getPlaybackState();
      if (mounted) setState(() => _connectState = state);
      L.info('app', 'BG test tick', data: {
        'elapsed_s': _bgSecondsElapsed.toString(),
        'audio': state == null
            ? 'no state'
            : state.paused
                ? 'PAUSED ❌'
                : 'playing ✅',
        'device': state?.deviceName ?? 'none',
        'track': state?.trackName ?? 'none',
      });
      if (_bgSecondsElapsed >= 120) {
        _bgTimer?.cancel();
        if (mounted) setState(() => _bgTestRunning = false);
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

  // ── UI ────────────────────────────────────────────────────────────────────

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
          Expanded(
            child: CustomScrollView(
              slivers: [
                // ── WebView SDK section ──────────────────────────────────
                _sectionHeader('WebView SDK (EME/DRM)', subtitle: 'Widevine L3 · no Spotify app needed'),
                SliverToBoxAdapter(child: _buildSdkSection()),

                // ── Connect section ──────────────────────────────────────
                _sectionHeader('Spotify Connect', subtitle: 'Uses Spotify app as audio engine — no DRM needed'),
                SliverToBoxAdapter(child: _buildConnectSection()),

                // ── App Remote section ───────────────────────────────────
                _sectionHeader('App Remote SDK',
                    subtitle: 'Native IPC — launches Spotify automatically'),
                SliverToBoxAdapter(child: _buildAppRemoteSection()),

                // ── Log panel ────────────────────────────────────────────
                _sectionHeader('Logs'),
                SliverToBoxAdapter(child: _buildLevelFilter()),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) => _LogRow(entry: _filteredLogs[i]),
                    childCount: _filteredLogs.length,
                  ),
                ),
              ],
            ),
          ),
          if (_bridge != null)
            SizedBox(width: 1, height: 1, child: WebViewWidget(controller: _bridge!.controller)),
        ],
      ),
    );
  }

  Widget _buildAuthBar() {
    if (_tokens == null) {
      return Container(
        color: Colors.grey[100],
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.login, color: Color(0xFF1DB954)),
          title: const Text('Not connected to Spotify'),
          trailing: ElevatedButton(onPressed: _login, child: const Text('Login')),
        ),
      );
    }
    return Container(
      color: Colors.green[50],
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.check_circle, color: Colors.green, size: 20),
        title: Text(
          'Connected · token expires ${_tokens!.expiry.toLocal().toString().substring(11, 19)}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: TextButton(onPressed: _logout, child: const Text('Logout')),
      ),
    );
  }

  SliverToBoxAdapter _sectionHeader(String title, {String? subtitle}) {
    return SliverToBoxAdapter(
      child: Container(
        color: Colors.grey[200],
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Text(subtitle, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
          ],
        ]),
      ),
    );
  }

  // ── WebView SDK section ───────────────────────────────────────────────────

  Widget _buildSdkSection() {
    final state = _playerState;
    return Column(
      children: [
        // Status
        ListTile(
          dense: true,
          leading: Icon(
            _playerReady ? Icons.check_circle : Icons.error_outline,
            color: _playerReady ? Colors.green : Colors.red,
            size: 20,
          ),
          title: Text(
            _playerReady ? 'Player ready (device: ${_bridge?.hasDevice == true ? "✓" : "–"})' : 'Initialising…',
            style: const TextStyle(fontSize: 12),
          ),
          subtitle: state?.track != null
              ? Text('${state!.track!.name} — ${state.paused ? "paused" : "playing"}',
                  style: const TextStyle(fontSize: 11))
              : null,
        ),
        // Controls
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            for (final (label, uri) in _testUris)
              OutlinedButton(
                onPressed: _playerReady ? () => _bridge!.play(uri) : null,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(label, style: const TextStyle(fontSize: 11)),
              ),
            IconButton(
              icon: const Icon(Icons.skip_previous, size: 20),
              onPressed: _playerReady ? _bridge!.prevTrack : null,
            ),
            IconButton(
              icon: Icon(
                (_playerState?.paused ?? true) ? Icons.play_arrow : Icons.pause,
                size: 20,
              ),
              onPressed: _playerReady
                  ? () => (_playerState?.paused ?? true)
                      ? _bridge!.resume()
                      : _bridge!.pause()
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next, size: 20),
              onPressed: _playerReady ? _bridge!.nextTrack : null,
            ),
          ]),
        ),
      ],
    );
  }

  // ── Connect section ───────────────────────────────────────────────────────

  Widget _buildConnectSection() {
    final cs = _connectState;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Connect playback state
        if (cs != null)
          ListTile(
            dense: true,
            leading: Icon(
              cs.paused ? Icons.pause_circle : Icons.play_circle,
              color: const Color(0xFF1DB954),
              size: 28,
            ),
            title: Text(cs.trackName ?? 'Unknown', style: const TextStyle(fontSize: 12)),
            subtitle: Text(
              '${cs.artistName ?? ''} · ${cs.deviceName} · ${_fmt(Duration(milliseconds: cs.progressMs))}',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: cs.artworkUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(cs.artworkUrl!, width: 36, height: 36, fit: BoxFit.cover),
                  )
                : null,
          )
        else if (_tokens != null)
          const ListTile(
            dense: true,
            leading: Icon(Icons.phonelink_off, size: 20, color: Colors.grey),
            title: Text('Open Spotify on your phone, then tap List Devices',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),

        // Device list + content buttons
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            // List devices
            ElevatedButton.icon(
              onPressed: _tokens != null ? _connectListDevices : null,
              icon: const Icon(Icons.devices, size: 16),
              label: const Text('List Devices', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
            ),

            // Play buttons — one per device
            for (final device in _connectDevices)
              for (final (label, uri) in _testUris)
                OutlinedButton(
                  onPressed: () => _connectPlay(device.id, uri),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: BorderSide(
                      color: device.isActive ? Colors.green : Colors.grey,
                    ),
                  ),
                  child: Text(
                    '▶ $label on ${device.name}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),

            // Connect/pause/next controls
            if (_connectState != null) ...[
              IconButton(
                icon: Icon(_connectState!.paused ? Icons.play_arrow : Icons.pause, size: 20),
                onPressed: () async {
                  if (_connectState!.paused) {
                    await _connect.resume();
                  } else {
                    await _connect.pause();
                  }
                  _startConnectPoll();
                },
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, size: 20),
                onPressed: () async {
                  await _connect.nextTrack();
                  _startConnectPoll();
                },
              ),
            ],
          ]),
        ),

        // Background test
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            const Icon(Icons.timer_outlined, size: 16),
            const SizedBox(width: 4),
            const Text('BG test:', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 6),
            if (!_bgTestRunning)
              SizedBox(
                height: 28,
                child: ElevatedButton(
                  onPressed: _connectState != null && !_connectState!.paused ? _startBgTest : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                  child: const Text('Start (Connect playing first)'),
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
                      child: const Text('Stop', style: TextStyle(fontSize: 12))),
                ),
              ]),
          ]),
        ),
      ],
    );
  }

  // ── App Remote section ────────────────────────────────────────────────────

  Widget _buildAppRemoteSection() {
    final rs = _remoteState;
    final track = rs?.track;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Status + current track
        ListTile(
          dense: true,
          leading: Icon(
            _remote.connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: _remote.connected ? Colors.green : Colors.grey,
            size: 20,
          ),
          title: Text(
            _remote.connected
                ? (track != null
                    ? '${track.name} — ${track.artist.name}'
                    : 'Connected, nothing playing')
                : 'Not connected',
            style: const TextStyle(fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: rs != null && track != null
              ? Text(
                  '${rs.isPaused ? "paused" : "playing"} · ${_fmt(Duration(milliseconds: rs.playbackPosition))} / ${_fmt(Duration(milliseconds: track.duration))}',
                  style: const TextStyle(fontSize: 11),
                )
              : null,
        ),

        // Controls
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            // Connect button
            if (!_remote.connected)
              ElevatedButton.icon(
                onPressed: _tokens != null ? _connectRemote : null,
                icon: const Icon(Icons.link, size: 16),
                label: const Text('Connect to Spotify', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1DB954),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
              )
            else
              TextButton.icon(
                onPressed: () async {
                  await _remote.disconnect();
                  setState(() => _remoteState = null);
                },
                icon: const Icon(Icons.link_off, size: 16),
                label: const Text('Disconnect', style: TextStyle(fontSize: 12)),
              ),

            // Playback controls
            if (_remote.connected) ...[
              IconButton(
                icon: const Icon(Icons.skip_previous, size: 20),
                onPressed: _remote.skipPrevious,
              ),
              IconButton(
                icon: Icon(
                  (rs?.isPaused ?? true) ? Icons.play_arrow : Icons.pause,
                  size: 24,
                  color: const Color(0xFF1DB954),
                ),
                onPressed: () => _remote.togglePlay(rs?.isPaused ?? true),
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, size: 20),
                onPressed: _remote.skipNext,
              ),
            ],

            // Play URI buttons
            if (_remote.connected)
              for (final (label, uri) in _testUris)
                OutlinedButton(
                  onPressed: () => _remote.play(uri),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: const BorderSide(color: Color(0xFF1DB954)),
                  ),
                  child: Text('▶ $label', style: const TextStyle(fontSize: 11)),
                ),
          ]),
        ),

        // Note
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(
            '⚠ Spotify Dashboard: add package app.lauschi.lauschi + SHA-1 5F:BF:4A:A5:BB:0B:E8:77:FD:39:CB:40:69:8A:F6:AE:BE:1F:B7:B9 before connecting.',
            style: TextStyle(fontSize: 10, color: Colors.orange),
          ),
        ),
      ],
    );
  }

  // ── Log panel ─────────────────────────────────────────────────────────────

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
          Text('${_filteredLogs.length}',
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
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
          Text(ts,
              style: TextStyle(fontSize: 10, color: Colors.grey[500], fontFamily: 'monospace')),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(entry.source,
                style: TextStyle(
                    fontSize: 9, color: color, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.message,
                    style: TextStyle(
                        fontSize: 11, color: color, fontFamily: 'monospace')),
                if (entry.data != null && entry.data!.isNotEmpty)
                  Text(
                    entry.data!.entries.map((e) {
                      final v = e.value?.toString() ?? 'null';
                      return '${e.key}: ${v.length > 100 ? '${v.substring(0, 97)}…' : v}';
                    }).join('  '),
                    style: TextStyle(
                        fontSize: 10,
                        color: color.withValues(alpha: 0.8),
                        fontFamily: 'monospace'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
