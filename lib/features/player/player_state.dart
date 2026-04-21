import 'package:flutter/foundation.dart';
import 'package:lauschi/features/player/player_error.dart';

/// Hero tag for the album art animation between now-playing bar and
/// full player screen.
const playerArtworkHeroTag = 'player-artwork';

/// Current track metadata.
///
/// [artist] and [album] are nullable because not all providers supply them.
/// ARD Audiothek episodes have no artist/album metadata; Spotify always does.
@immutable
class TrackInfo {
  const TrackInfo({
    required this.uri,
    required this.name,
    this.artist,
    this.album,
    this.artworkUrl,
  });

  final String uri;
  final String name;
  final String? artist;
  final String? album;
  final String? artworkUrl;

  /// Equality by uri + name + artist. Album and artworkUrl are excluded:
  /// the same track may appear on different albums (compilations, re-issues)
  /// and artwork URLs vary by CDN/resolution. Including them would cause
  /// spurious Riverpod rebuilds without visible UI changes.
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
    this.track,
    this.positionMs = 0,
    this.durationMs = 0,
    this.error,
    this.activeCardId,
    this.activeContextUri,
    this.activeGroupId,
    this.hasNextTrack = false,
    this.hasPrevTrack = false,
  });

  /// Player backend is ready for playback.
  final bool isReady;

  /// Backend is initializing (bridge connecting, device registering).
  /// UI shows a loading overlay while true.
  final bool isLoading;

  /// Audio is currently playing (not paused).
  final bool isPlaying;

  /// Currently playing track metadata.
  final TrackInfo? track;

  /// Current playback position in milliseconds.
  final int positionMs;

  /// Total track duration in milliseconds.
  final int durationMs;

  /// Last error, if any. Backend code sets the enum value; UI maps it
  /// to user-facing text.
  final PlayerError? error;

  /// ID of the card currently being played.
  final String? activeCardId;

  /// URI of the album/context currently being played. Used to highlight
  /// the active card in the grid.
  final String? activeContextUri;

  /// Group ID of the tile containing the active episode.
  /// Used for mark-heard and position clearing on completion.
  final String? activeGroupId;

  /// Whether there is a track after the current one in the queue.
  /// Used to disable/hide the next track button when false.
  final bool hasNextTrack;

  /// Whether there is a track before the current one in the queue.
  /// Used to disable/hide the previous track button when false.
  final bool hasPrevTrack;

  /// Copy with optional field clearing.
  ///
  /// [error] is always replaced (pass null to clear error).
  PlaybackState copyWith({
    bool? isPlaying,
    bool? isReady,
    bool? isLoading,
    TrackInfo? track,
    int? positionMs,
    int? durationMs,
    PlayerError? error,
    String? activeCardId,
    bool clearActiveCard = false,
    String? activeContextUri,
    bool clearActiveContextUri = false,
    String? activeGroupId,
    bool clearActiveGroupId = false,
    bool? hasNextTrack,
    bool? hasPrevTrack,
  }) {
    return PlaybackState(
      isPlaying: isPlaying ?? this.isPlaying,
      isReady: isReady ?? this.isReady,
      isLoading: isLoading ?? this.isLoading,
      track: track ?? this.track,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      error: error,
      activeCardId:
          clearActiveCard ? null : (activeCardId ?? this.activeCardId),
      activeContextUri:
          clearActiveContextUri
              ? null
              : (activeContextUri ?? this.activeContextUri),
      activeGroupId:
          clearActiveGroupId ? null : (activeGroupId ?? this.activeGroupId),
      hasNextTrack: hasNextTrack ?? this.hasNextTrack,
      hasPrevTrack: hasPrevTrack ?? this.hasPrevTrack,
    );
  }
}
