# Security Notes

## WebView Bridge Protocol

The Spotify Web Playback SDK runs in an Android WebView. Communication between
JS and Dart uses a `JavaScriptChannel` named `SpotifyBridge`.

### Message validation

All messages from JS are validated before processing:

1. **Size limit**: Messages >64KB are dropped.
2. **JSON parsing**: Invalid JSON is rejected with error log.
3. **Type allowlist**: Only known message types are accepted:
   `sdk_ready`, `ready`, `not_ready`, `state_changed`, `token_request`,
   `play_request`, `error`, `log`.
4. **Field validation**: String fields are sanitized (control chars stripped,
   length capped). Numeric fields are clamped to valid ranges. Required fields
   are null-checked.
5. **No code execution**: Dart never evaluates or executes string content from
   JS messages. Data flows are read-only (track metadata, position, device ID).

### Spotify SDK CDN loading

`player.html` loads the SDK from `https://sdk.scdn.co/spotify-player.js`
without Subresource Integrity (SRI).

**Why no SRI**: Spotify serves the SDK from a versionless URL that receives
silent updates. An SRI hash would break on every SDK update, requiring manual
hash rotation. Spotify does not publish SDK checksums or version-specific URLs.

**Mitigations**:
- The WebView is sandboxed — JS cannot access native device APIs, filesystem,
  or other apps.
- The bridge protocol validates all inbound messages (see above).
- The WebView has no access to sensitive app state beyond the OAuth access token
  (which the SDK requires by design).
- Tokens are short-lived (1 hour) and scoped to streaming + read permissions.

**Alternative considered**: Bundling the SDK as a local asset. Rejected because:
- The SDK initializes EME/Widevine which requires an HTTPS origin.
- A bundled copy would go stale silently, potentially causing playback failures.
- Spotify's terms don't explicitly permit redistribution of the SDK file.

### WebView isolation

The WebView is positioned off-screen (300×300px at -500,-500) and only loads
the player HTML page. Navigation is not permitted to other origins. The WebView
does not render any user-visible content.

## Token handling

- OAuth tokens are stored in `FlutterSecureStorage` (Android Keystore / iOS Keychain).
- PKCE flow with S256 challenge — no client secret.
- Tokens are refreshed proactively (2 minutes before expiry).
- The access token is passed to the WebView via `runJavaScript()`, not via URL
  parameters or cookies.

## PIN storage

- Parent PIN is stored as a bcrypt hash (cost factor 10) in secure storage.
- Hash and verify operations run in a background isolate to avoid blocking the UI.
- PIN is never stored in plaintext.
