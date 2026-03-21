# Apple Music via MusicKit JS WebView: Research

## Problem

The MusicKit Android SDK (native) has ~30-60s startup latency per album.
This is a known unfixed issue (Apple Developer Forums thread/131269, since 2020).
The latency is in the DRM handshake and Apple Music app IPC pipeline.
Every new album triggers a full DRM cycle. The Apple Music Android app
itself has the same latency on initial load.

## Proposed Solution: MusicKit JS in WebView

Use Apple's MusicKit JS (web SDK) in an Android WebView instead of the
native Android SDK. Same architecture as our Spotify integration.

### Why it should work

1. **Proven pattern**: Our Spotify bridge already plays DRM content through
   a WebView (loads `player.html` via HTTPS, Spotify SDK handles Widevine DRM)
2. **Apple Music web player works on Chrome Android**: Apple's own web player
   at music.apple.com works in Chrome on Android, confirming MusicKit JS +
   Widevine works on Android browsers
3. **Widevine in WebView**: Android WebView supports Widevine DRM when loaded
   from an HTTPS origin (secure context requirement met)
4. **MusicKit JS is actively maintained**: v3 is current, well-documented,
   supports playback, queue management, seek, position tracking

### Expected benefits

- **No Apple Music app dependency**: Users don't need the Apple Music app
  installed (just a subscription)
- **No 30-60s latency**: Web player starts in 2-5 seconds (browser audio
  pipeline, not native IPC)
- **Consistent architecture**: Both Spotify and Apple Music use the same
  WebView bridge pattern
- **Better seek/position**: MusicKit JS has `seekToTime()` and real-time
  position reporting built in

### Architecture

```
Dart (AppleMusicPlayer)
  ↕ JavaScript bridge (postMessage)
WebView (player.html)
  ↕ MusicKit JS v3
Apple Music servers (Widevine DRM)
```

Mirrors the existing Spotify architecture:
```
Dart (SpotifyPlayer)
  ↕ JavaScript bridge (postMessage)
WebView (player.html)
  ↕ Spotify Web Playback SDK
Spotify servers (Widevine DRM)
```

### MusicKit JS API surface needed

```javascript
// Configure
MusicKit.configure({ developerToken: '...', app: { name: 'lauschi' } });
const music = MusicKit.getInstance();

// Auth
await music.authorize();  // User grants access

// Playback
await music.setQueue({ album: 'albumId' });
await music.play();
music.pause();
music.skipToNextItem();
music.skipToPreviousItem();
music.seekToTime(seconds);

// State
music.playbackState  // playing, paused, stopped, etc.
music.currentPlaybackTime  // seconds
music.currentPlaybackDuration  // seconds
music.nowPlayingItem  // track metadata

// Events
music.addEventListener('playbackStateDidChange', handler);
music.addEventListener('playbackTimeDidChange', handler);
music.addEventListener('nowPlayingItemDidChange', handler);
```

### Implementation plan

1. Create `apple_music_player.html` (hosted on our server, like Spotify's)
2. Include MusicKit JS v3 CDN script
3. Build a bridge layer (postMessage protocol) mirroring `SpotifyWebViewBridge`
4. Create `AppleMusicWebViewBridge` in Dart
5. Rewrite `AppleMusicPlayer` to use the bridge instead of native MusicKit
6. Remove the native `music_kit` plugin dependency for playback
   (keep for auth if needed, or use MusicKit JS auth)

### Open questions

- Does MusicKit JS auth work in an Android WebView? (Apple may restrict
  to Safari/Chrome browser only)
- Does the WebView maintain the DRM session across page navigations?
- What's the actual playback startup time in a WebView vs Chrome?
- Does background playback work (WebView in a foreground service)?
- Can we share the auth token between native MusicKit (for catalog API)
  and MusicKit JS (for playback)?

### References

- MusicKit JS docs: https://developer.apple.com/documentation/musickitjs
- MusicKit JS v3 reference: https://js-cdn.music.apple.com/musickit/v3/docs/
- Open source web player: https://github.com/zachomedia/apple-music-webplayer
- Apple Music web player: https://music.apple.com
- Apple Developer Forum (latency): https://developer.apple.com/forums/thread/131269
- DRM in WebView: https://amokranechentir.hashnode.dev/android-play-drm-protected-content-inside-a-webview
- tiini (competitor, uses Apple Music): https://tiini.app

### Competitors using Apple Music on Android

- **tiini**: Hamburg startup, kids Hörspiel player with Spotify + Apple Music.
  Their tech stack is unknown but they have Apple Music playback working.
  Worth testing their app to see if they have the same latency issue.
- **Shazam**: Uses Apple Music for "play in Apple Music" feature on Android
- **Apple Music app itself**: Has the same ~30-60s latency on first song
