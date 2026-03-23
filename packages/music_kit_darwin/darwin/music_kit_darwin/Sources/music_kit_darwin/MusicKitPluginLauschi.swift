//
//  MusicKitPluginLauschi.swift
//  music_kit_darwin
//
//  lauschi additions: seek, queue-by-catalog-IDs, and a unified playback
//  state EventChannel that pushes position/duration/isPlaying/trackChanged
//  on a native timer. This avoids Dart-side polling and handles iOS
//  background suspension automatically (Timer suspends with the app).
//

import Foundation
import MusicKit

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

// MARK: - Seek

extension MusicKitPlugin {
  func setPlaybackTime(_ time: Double, result: @escaping FlutterResult) {
    musicPlayer.playbackTime = time
    result(nil)
  }
}

// MARK: - Queue by catalog IDs

extension MusicKitPlugin {
  /// Set the player queue using Apple Music catalog song IDs.
  ///
  /// IDs come from the lauschi catalog (matched via AppleMusicApi).
  /// MusicCatalogResourceRequest returns songs in undefined order,
  /// so we reorder to match the input ID sequence.
  func setQueueWithStoreIds(ids: [String], startingAt: Int?, result: @escaping FlutterResult) {
    Task {
      do {
        let musicIds = ids.map { MusicItemID($0) }
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: musicIds)
        let response = try await request.response()

        // Reorder songs to match input ID order. The catalog API
        // returns results in undefined order (server-determined).
        let idToSong = Dictionary(uniqueKeysWithValues: response.items.map { ($0.id, $0) })
        let orderedSongs = musicIds.compactMap { idToSong[$0] }

        guard !orderedSongs.isEmpty else {
          result(FlutterError(code: "ERR_SET_QUEUE", message: "No songs found for the given IDs"))
          return
        }

        let collection = MusicItemCollection(orderedSongs)
        let startItem: Song? = if let idx = startingAt, idx < orderedSongs.count {
          orderedSongs[idx]
        } else {
          nil
        }

        musicPlayer.queue = ApplicationMusicPlayer.Queue(for: collection, startingAt: startItem)
        result(nil)
      } catch {
        result(FlutterError(code: "ERR_SET_QUEUE", message: error.localizedDescription))
      }
    }
  }
}

// MARK: - Playback State EventChannel

/// Pushes unified playback state at 2Hz via EventChannel.
///
/// Event format (matches Android's drm_player_state for Dart compatibility):
///   {type: "state", isPlaying: bool, positionMs: int, durationMs: int}
///   {type: "trackChanged", songId: String}
///   {type: "trackEnded"}
///   {type: "error", message: String, errorCode: int}
///
/// The native Timer suspends when the app backgrounds (iOS power
/// management), so no wasted cycles. On foreground, the first tick
/// immediately pushes the current position.
extension MusicKitPlugin {
  class LauschiPlaybackStreamHandler: MusicKitPluginStreamHandler, FlutterStreamHandler {
    let musicPlayer: ApplicationMusicPlayer
    private var positionTimer: Timer?
    private var lastSongId: String?

    init(musicPlayer: ApplicationMusicPlayer) {
      self.musicPlayer = musicPlayer
      super.init()
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
      eventSink = events

      // Push position, state, and track changes at 2Hz.
      // Using a single timer avoids the objectWillChange race condition:
      // Combine's objectWillChange fires BEFORE the property changes,
      // so reading currentEntry in the sink would return the old value.
      // The timer reads state AFTER changes have settled.
      positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        self?.pushState()
        self?.checkTrackChange()
        self?.checkForErrors()
      }

      return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
      // Nil the sink first to prevent the timer's final tick from sending
      // events to a cancelled Dart stream.
      eventSink = nil
      positionTimer?.invalidate()
      positionTimer = nil
      lastSongId = nil
      return nil
    }

    private func pushState() {
      guard let sink = eventSink else { return }
      let isPlaying = musicPlayer.state.playbackStatus == .playing
      let positionMs = Int(musicPlayer.playbackTime * 1000)

      // Duration from the current queue entry. The entry's title is
      // always available; duration requires the underlying item to
      // be resolved (which it is after setQueueWithStoreIds).
      var durationMs = 0
      if let entry = musicPlayer.queue.currentEntry {
        // MusicPlayer.Queue.Entry exposes duration via its item.
        // Use the entry's underlying Song/Track duration.
        if let song = entry.item as? Song {
          durationMs = Int((song.duration ?? 0) * 1000)
        } else if let track = entry.item as? Track {
          durationMs = Int((track.duration ?? 0) * 1000)
        }
      }

      sink([
        "type": "state",
        "isPlaying": isPlaying,
        "positionMs": positionMs,
        "durationMs": durationMs,
      ] as [String: Any])
    }

    private func checkTrackChange() {
      let currentId = currentSongId()
      if let currentId = currentId, currentId != lastSongId {
        lastSongId = currentId
        eventSink?([
          "type": "trackChanged",
          "songId": currentId,
        ] as [String: Any])
      }

      // Detect end of playback: MusicKit enters .paused (not .stopped)
      // when the last track finishes. Check for paused/stopped with no
      // current entry, or paused after the last known track.
      let status = musicPlayer.state.playbackStatus
      let isStopped = status == .stopped || (status == .paused && currentId == nil)
      if isStopped && lastSongId != nil {
        eventSink?(["type": "trackEnded"] as [String: Any])
        lastSongId = nil
      }
    }

    private func checkForErrors() {
      if musicPlayer.state.playbackStatus == .interrupted {
        eventSink?([
          "type": "error",
          "message": "Playback interrupted (audio session lost)",
          "errorCode": 1,
        ] as [String: Any])
      }
    }

    private func currentSongId() -> String? {
      guard let entry = musicPlayer.queue.currentEntry else { return nil }
      // MusicPlayer.Queue.Entry wraps different item types.
      // Extract the catalog ID from the underlying Song or Track.
      if let song = entry.item as? Song {
        return song.id.rawValue
      } else if let track = entry.item as? Track {
        return track.id.rawValue
      }
      // Fallback: entry.id is a queue-internal ID, not a catalog ID.
      // This shouldn't happen if queue was set via setQueueWithStoreIds.
      return nil
    }
  }
}
