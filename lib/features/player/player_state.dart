import 'package:flutter/foundation.dart';
import 'package:lauschi/features/player/player_error.dart';

/// Hero tag for the album art animation between now-playing bar and
/// full player screen.
const playerArtworkHeroTag = 'player-artwork';

/// Current track metadata.
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
    this.track,
    this.positionMs = 0,
    this.durationMs = 0,
    this.error,
    this.nextEpisodeTitle,
    this.nextEpisodeCoverUrl,
    this.activeCardId,
    this.activeContextUri,
    this.activeGroupId,
  });

  /// Player backend is ready for playback.
  final bool isReady;

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

  /// Copy with optional field clearing.
  ///
  /// [error] is always replaced (pass null to clear error).
  PlaybackState copyWith({
    bool? isPlaying,
    bool? isReady,
    TrackInfo? track,
    int? positionMs,
    int? durationMs,
    PlayerError? error,
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
      track: track ?? this.track,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      error: error,
      nextEpisodeTitle:
          clearNextEpisode ? null : (nextEpisodeTitle ?? this.nextEpisodeTitle),
      nextEpisodeCoverUrl:
          clearNextEpisode
              ? null
              : (nextEpisodeCoverUrl ?? this.nextEpisodeCoverUrl),
      activeCardId:
          clearActiveCard ? null : (activeCardId ?? this.activeCardId),
      activeContextUri:
          clearActiveContextUri
              ? null
              : (activeContextUri ?? this.activeContextUri),
      activeGroupId:
          clearActiveGroupId ? null : (activeGroupId ?? this.activeGroupId),
    );
  }
}
