import 'package:flutter/foundation.dart';

/// Current track metadata from Spotify playback.
@immutable
class TrackInfo {
  const TrackInfo({
    required this.uri,
    required this.name,
    required this.artist,
    required this.album,
    this.artworkUrl,
  });

  final String uri;
  final String name;
  final String artist;
  final String album;
  final String? artworkUrl;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackInfo &&
          runtimeType == other.runtimeType &&
          uri == other.uri &&
          name == other.name &&
          artist == other.artist;

  @override
  int get hashCode => Object.hash(uri, name, artist);
}

/// Playback state exposed to the UI.
@immutable
class PlaybackState {
  const PlaybackState({
    this.isPlaying = false,
    this.isReady = false,
    this.isLoading = false,
    this.deviceId,
    this.track,
    this.positionMs = 0,
    this.durationMs = 0,
    this.error,
  });

  /// Spotify Web Playback SDK is connected and has a device ID.
  final bool isReady;

  /// Audio is currently playing (not paused).
  final bool isPlaying;

  /// A play request is in progress (tap registered, waiting for response).
  final bool isLoading;

  /// Device ID assigned by Spotify SDK.
  final String? deviceId;

  /// Currently playing track metadata.
  final TrackInfo? track;

  /// Current playback position in milliseconds.
  final int positionMs;

  /// Total track duration in milliseconds.
  final int durationMs;

  /// Last error message, if any.
  final String? error;

  /// Normalized progress 0.0–1.0 for progress bar.
  double get progress =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  /// Copy with optional field clearing.
  ///
  /// [clearDeviceId] and [clearTrack] set the respective fields to null.
  /// [error] is always replaced (pass null to clear error).
  PlaybackState copyWith({
    bool? isPlaying,
    bool? isReady,
    bool? isLoading,
    String? deviceId,
    bool clearDeviceId = false,
    TrackInfo? track,
    bool clearTrack = false,
    int? positionMs,
    int? durationMs,
    String? error,
  }) {
    return PlaybackState(
      isPlaying: isPlaying ?? this.isPlaying,
      isReady: isReady ?? this.isReady,
      isLoading: isLoading ?? this.isLoading,
      deviceId: clearDeviceId ? null : (deviceId ?? this.deviceId),
      track: clearTrack ? null : (track ?? this.track),
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      error: error,
    );
  }
}
