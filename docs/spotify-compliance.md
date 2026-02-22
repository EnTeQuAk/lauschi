# Spotify Developer Terms Compliance

Status: **Under review** — contact Spotify Developer Support before public release.

## Architecture

lauschi uses the [Spotify Web Playback SDK](https://developer.spotify.com/documentation/web-playback-sdk)
inside an Android WebView to play audio. Playback control uses the
[Spotify Web API](https://developer.spotify.com/documentation/web-api).
Authentication uses PKCE (public client, no client secret).

## Terms questions

### 1. Web Playback SDK in a native app WebView

The SDK documentation describes it as a "browser-based" SDK. Using it inside
a native Android WebView is not explicitly addressed. The SDK functions
correctly in a WebView with Widevine support (Chrome-based WebView on Android).

**Risk**: Spotify could argue this is outside the SDK's intended use.

**Mitigation**: The WebView is a standard Chromium-based browser engine. The
SDK performs the same operations as in a desktop browser tab. No SDK internals
are modified or bypassed.

### 2. Commercial use

Spotify's policy prohibits "the sale of a Streaming SDA" and "e-commerce
initiated via a Streaming SDA."

lauschi is:
- Free and open source (GPL-3.0 license)
- No in-app purchases, subscriptions, or monetization
- No advertising
- Distributed via GitHub and potentially app stores (free)

**Risk**: "Commercial use" definition is ambiguous. Distributing a free app
on the App Store may or may not constitute commercial use.

**Mitigation**: Contact Spotify for written clarification before app store
submission.

### 3. Premium requirement

The Web Playback SDK requires Spotify Premium. lauschi communicates this
during onboarding ("Spotify Premium wird benötigt").

No issues identified.

### 4. Dev Mode limitations (February 2026)

Spotify's new Dev Mode limits apps to 5 users until an extension request is
approved. The existing `tuneloop` app (client ID `33f475f8...`) was
grandfathered until March 9, 2026.

**Action needed**: Submit an extension request before the deadline if the app
will have more than 5 users.

### 5. Required attributions

Spotify's branding guidelines require visible attribution when using their
content or APIs. The app should display:
- "Powered by Spotify" or Spotify logo where content is shown
- Spotify attribution in the app's About/Settings screen

**Status**: Not yet implemented. Add before public release.

### 6. User data handling

Spotify's policy requires that apps:
- Do not store Spotify Content (audio streams) — lauschi does not.
- Do not cache metadata beyond 24 hours — lauschi stores album titles and
  cover URLs indefinitely. May need a cache-refresh mechanism.
- Handle token revocation gracefully — lauschi detects auth failures and
  redirects to re-login.

## Action items

- [ ] Email `developer@spotify.com` describing the use case:
  - Open source kids audio player
  - Web Playback SDK in Android WebView
  - Free distribution, no monetization
  - Ask for written confirmation
- [ ] Submit Dev Mode extension request before March 9, 2026
- [ ] Add Spotify attribution to the UI (About screen + player screen)
- [ ] Review metadata caching policy (24-hour cache guideline)
- [ ] Document Spotify's response in this file

## References

- [Spotify Developer Policy](https://developer.spotify.com/policy)
- [Spotify Design Guidelines](https://developer.spotify.com/documentation/design)
- [Web Playback SDK Documentation](https://developer.spotify.com/documentation/web-playback-sdk)
- [Dev Mode Announcement](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api)
