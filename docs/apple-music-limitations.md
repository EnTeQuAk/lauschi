# Apple Music on Android: Known Limitations

## MusicKit Android SDK

lauschi uses Apple's MusicKit Android SDK via a forked `music_kit` Flutter plugin
(`packages/music_kit`). The SDK communicates with the Apple Music app via IPC.

### Startup Latency (~30-60 seconds)

The `MediaPlayerController.prepare()` call takes 30-60 seconds before audio
starts playing. This is a [known issue](https://developer.apple.com/forums/thread/131269)
with the MusicKit Android SDK, reported since 2020, never fixed by Apple.

During this time the app shows "Wird geladen..." (loading). The user must wait.

### Requires Apple Music App

The SDK delegates actual audio playback to the Apple Music Android app.
It must be installed. Auth works without it (web-based flow), but playback
requires the app's background service.

### Subscription Stream Not Implemented

`onSubscriptionUpdated` throws `MissingPluginException` on Android. The plugin
catches this and assumes the user can play (they went through the auth flow).

### Process Death

If Android kills the app process while Apple Music is playing, playback state
is lost. The saved position (from periodic 10-second saves) is restored on
next launch, but the user must tap play again.

### Background Behavior

The `MediaPlayerController` continues playing when the app is backgrounded.
Audio focus handling is delegated to the Apple Music app. If another app
takes audio focus, Apple Music pauses. Resuming from the notification or
app should work, but this is not extensively tested.

### Storefront

The user's storefront (catalog region) is fetched asynchronously from Apple's
`/me/storefront` endpoint. If this times out (common on slow connections),
the app defaults to `de` (Germany). Austrian and Swiss users may see slightly
different content availability but playback still works.

## Developer Token

The developer JWT is generated on-device from the .p8 private key embedded
in the AndroidManifest (injected by gradle from `android/app/AuthKey_*.p8`).
A fresh token is created on every app launch, so the 150-day expiry per-token
is never reached in practice.

## Forked Plugin

The `music_kit` Flutter plugin (`packages/music_kit`) is forked from
[misiio/flutter_music_kit](https://github.com/misiio/flutter_music_kit)
commit 3e0b688 (unreleased). Our additions:

- `playbackTime`: position tracking via `MediaPlayerController.getCurrentPosition()`
- `setPlaybackTime`: seek via `seekToPosition()`
- `currentItemDuration`: duration via `getDuration()`
- `isPreparedToPlay`: controller readiness check
- On-device JWT generation from AndroidManifest metadata
- Async storefront fetch (non-blocking, defaults to 'de')
- Thread safety: `@Volatile` on shared fields, `@Synchronized` on controller creation
- Playback error forwarding to Flutter via `eventSink.error()`

The `music_kit_platform_interface` is also forked to add `setPlaybackTime`.
