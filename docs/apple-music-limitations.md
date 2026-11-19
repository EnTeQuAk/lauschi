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

The app holds no MusicKit key. On iOS, MusicKit makes the developer token
from the app's MusicKit service. On Android, the lauschi server signs a
30-day token every week with `tool/sign_apple_music_token.py` and serves it
at `https://auth.lauschi.app/apple_music_token`. `AppleMusicDeveloperToken`
fetches it, keeps it in secure storage and fetches a new one when fewer
than 14 days are left, on start and on app resume. If the server is down,
the stored token still works until it runs out.

The token itself isn't secret, the app sends it with every Apple Music
request. The key that signs it is, and it lives only on the server (and on
your machine for the catalog tools).

## Forked Plugin

The `music_kit` Flutter plugin (`packages/music_kit`) is forked from
[misiio/flutter_music_kit](https://github.com/misiio/flutter_music_kit)
commit 3e0b688 (unreleased). Our additions:

- `playbackTime`: position tracking via `MediaPlayerController.getCurrentPosition()`
- `setPlaybackTime`: seek via `seekToPosition()`
- `currentItemDuration`: duration via `getDuration()`
- `isPreparedToPlay`: controller readiness check
- Async storefront fetch (non-blocking, defaults to 'de')
- Thread safety: `@Volatile` on shared fields, `@Synchronized` on controller creation
- Playback error forwarding to Flutter via `eventSink.error()`

The `music_kit_platform_interface` is also forked to add `setPlaybackTime`.

## iOS: What's Needed

When building for iOS, the upstream split their iOS support into a separate
`music_kit_darwin` package (Swift Package Manager). Steps to add iOS:

1. **Fork `music_kit_darwin`** into `packages/music_kit_darwin`
2. **Apply PR #3's `setPlaybackTime`** from XMitja's fork:
   - `MusicKitPluginPlayer.swift`: `musicPlayer.playbackTime = TimeInterval(time)`
   - `MusicKitPluginMethodKeys.swift`: add `.setPlaybackTime` case
   - `SwiftMusicKitPlugin.swift`: route `setPlaybackTime` to player
3. **Apply PR #3's subscription dispatch fix**:
   - `MusicKitPluginSubscription.swift`: wrap `eventSink?()` in `DispatchQueue.main.async`
4. **MusicKit capability** in Xcode: the iOS MusicKit entitlement auto-generates
   the developer token, no .p8 key needed
5. **`playbackTime` already works on iOS** (native MusicKit framework implements it)
6. **`currentItemDuration`**: may need a direct method channel like Android, or
   use the queue entry's `durationInMillis` from metadata

See upstream PR: https://github.com/misiio/flutter_music_kit/pull/3
See upstream fork: https://github.com/rubymarketing/apple_music_kit (seekTo on iOS)
