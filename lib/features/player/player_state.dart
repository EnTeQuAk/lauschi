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
    this.trackNumber = 0,
    this.nextTracksCount = 0,
    this.error,
    this.nextEpisodeTitle,
    this.nextEpisodeCoverUrl,
    this.activeCardId,
    this.activeContextUri,
    this.activeGroupId,
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

  /// 1-based position of the current track within the album.
  /// Approximate for very long albums where the SDK window is capped.
  final int trackNumber;

  /// Number of tracks remaining after the current one. Zero means this
  /// is the last track in the album/context.
  final int nextTracksCount;

  /// Last error message, if any.
  final String? error;

  /// Title of the next episode about to auto-play. Shown briefly during
  /// the advance delay. Null when no advance is pending.
  final String? nextEpisodeTitle;

  /// Cover art URL of the next episode (for non-reading kids).
  final String? nextEpisodeCoverUrl;

  /// ID of the card currently being played.
  final String? activeCardId;

  /// URI of the album/context currently being played. Used to highlight
  /// the active card in the grid.
  final String? activeContextUri;

  /// Group ID for auto-advance. When set, completing an episode
  /// auto-plays the next unheard episode in the series.
  final String? activeGroupId;

  /// Whether an auto-advance to the next episode is pending.
  bool get isAdvancing => nextEpisodeTitle != null;

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
    int? trackNumber,
    int? nextTracksCount,
    String? error,
    String? nextEpisodeTitle,
    String? nextEpisodeCoverUrl,
    bool clearNextEpisode = false,
    String? activeCardId,
    bool clearActiveCard = false,
    String? activeContextUri,
    bool clearActiveContextUri = false,
    String? activeGroupId,
    bool clearActiveGroupId = false,
  }) {
    return PlaybackState(
      isPlaying: isPlaying ?? this.isPlaying,
      isReady: isReady ?? this.isReady,
      isLoading: isLoading ?? this.isLoading,
      deviceId: clearDeviceId ? null : (deviceId ?? this.deviceId),
      track: clearTrack ? null : (track ?? this.track),
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      trackNumber: trackNumber ?? this.trackNumber,
      nextTracksCount: nextTracksCount ?? this.nextTracksCount,
      error: error,
      nextEpisodeTitle:
          clearNextEpisode ? null : (nextEpisodeTitle ?? this.nextEpisodeTitle),
      nextEpisodeCoverUrl:
          clearNextEpisode
              ? null
              : (nextEpisodeCoverUrl ?? this.nextEpisodeCoverUrl),
      activeCardId:
          clearActiveCard ? null : (activeCardId ?? this.activeCardId),
      activeContextUri: clearActiveContextUri
          ? null
          : (activeContextUri ?? this.activeContextUri),
      activeGroupId:
          clearActiveGroupId ? null : (activeGroupId ?? this.activeGroupId),
    );
  }
}
