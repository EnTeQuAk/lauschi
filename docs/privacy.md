# Privacy & Data Protection

lauschi is designed as a privacy-first app. No analytics, no tracking, no cloud
services beyond Spotify's streaming API.

## Data inventory

### Stored locally on device

| Data | Storage | Purpose |
|------|---------|---------|
| Audio cards (title, cover URL, Spotify URI) | SQLite (Drift) | Card collection |
| Playback position (track URI, ms offset) | SQLite (Drift) | Resume where left off |
| Parent PIN hash | FlutterSecureStorage (Android Keystore) | Parent mode access |
| Spotify OAuth tokens | FlutterSecureStorage (Android Keystore) | API authentication |
| Onboarding complete flag | SharedPreferences | Skip onboarding on re-launch |

All data stays on the device. There is no lauschi backend, no user accounts,
no cloud sync.

### Network requests

| Destination | Data sent | Purpose |
|-------------|-----------|---------|
| `accounts.spotify.com` | PKCE auth code, refresh token | OAuth login + token refresh |
| `api.spotify.com` | Access token, search queries, play commands | Catalog search, playback control |
| `sdk.scdn.co` | HTTP request (no user data) | Load Web Playback SDK script |
| Spotify CDN (images) | HTTP request (no user data) | Album cover art |

lauschi does not send any user data to its own servers (it has none).

### What the Spotify SDK may collect

The Spotify Web Playback SDK runs in a sandboxed WebView. Spotify's SDK may
transmit telemetry to Spotify's servers (device fingerprint, playback events,
etc.). This is governed by [Spotify's Privacy Policy](https://www.spotify.com/privacy),
not by lauschi.

lauschi cannot inspect, intercept, or prevent SDK-internal network requests
within the WebView.

## GDPR considerations (EU/DACH market)

### Data controller

The parent who installs lauschi controls all data. lauschi itself does not
process personal data on behalf of anyone — all processing happens locally.

Spotify acts as a separate data controller for its streaming service.

### Lawful basis

- **PIN storage**: Legitimate interest (parental control).
- **Playback position**: Legitimate interest (resume functionality).
- **OAuth tokens**: Contractual necessity (Spotify API access requires authentication).

### Children's data (GDPR Art. 8 / GDPR-K)

lauschi does not collect, store, or transmit any data about the child user.
The child interacts with a local card grid and playback controls. No child
profile, no usage analytics, no behavioral data.

The Spotify account belongs to the parent. The child does not log in, does not
have a Spotify account, and does not interact with Spotify directly.

### Data subject rights

All data is local. To exercise GDPR rights:
- **Access / Export**: Data is in the app's SQLite database (standard Android file access).
- **Deletion**: Uninstalling the app removes all local data. Clearing app storage has the same effect.
- **Spotify data**: Exercise rights directly with Spotify via their privacy settings.

## COPPA considerations (US market)

lauschi does not currently target the US market. If distributed in the US:
- No personal information is collected from children under 13.
- The parent's Spotify account is the only account involved.
- No third-party analytics or advertising SDKs are present.
- Sentry error reporting (when configured) captures crash data but no PII.

## App Store requirements

### Google Play

- Privacy policy URL required in Play Console listing.
- Declare "no data collected" in Data Safety section (all storage is local).
- If targeting the "Family" category: must comply with Families Policy
  (no ads, no unnecessary permissions, age-appropriate content).

### Apple App Store

- Privacy policy URL required.
- App Privacy "nutrition label" should declare: no data collected.
- Kids Category has strict requirements around third-party SDKs — the Spotify
  WebView SDK may disqualify the app from this category. Consider "Music"
  category instead with parental gate.

## Privacy policy template

A user-facing privacy policy should be hosted at a public URL and linked from
app store listings. Key points to cover:

1. lauschi stores audio cards, playback position, and parent PIN locally on your device.
2. lauschi connects to Spotify to search and play audio. Spotify's privacy policy applies to their service.
3. lauschi does not collect, store, or share personal information.
4. lauschi does not use analytics, advertising, or tracking.
5. Uninstalling the app deletes all local data.
6. Contact: [maintainer email]
