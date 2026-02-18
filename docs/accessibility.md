# lauschi — Kids Accessibility Guidelines

Target age range: **3–14 years**. This spans three distinct developmental groups with different motor, cognitive, and literacy capabilities. The app must work for a 3-year-old tapping cards AND a 12-year-old navigating independently.

## Age Groups & Design Implications

### Preschoolers (ages 3–5)
- **Pre-literate**: Cannot read. Rely entirely on images, icons, colors, sounds.
- **Motor skills**: Developing. Imprecise taps, no fine gestures (no pinch, no swipe accuracy).
- **Attention**: Very short (~2–5 minutes focused). Need immediate feedback on every interaction.
- **Mental model**: No understanding of hierarchy or navigation. Cause → effect must be instant and obvious.
- **lauschi impact**: The card grid with big album art + tap-to-play is ideal. No text-dependent UI in kid mode.

### School-age (ages 6–9)
- **Emerging literacy**: Can read short words and labels. Still image-first.
- **Motor skills**: Improved. Can tap targets ≥48dp reliably. Still struggle with small elements.
- **Attention**: 5–15 minutes focused. Can handle multi-step tasks if steps are clear.
- **Mental model**: Beginning to understand "back", "home", simple hierarchy.
- **lauschi impact**: Card titles provide useful context. Player controls are usable. Can navigate parent mode with help.

### Tweens (ages 10–14)
- **Fully literate**: Read fluently. Can process text-heavy UI.
- **Motor skills**: Adult-equivalent. Standard 48dp targets fine.
- **Attention**: Can sustain focus. Want to feel like they're using a "real" app, not a "baby" app.
- **Mental model**: Understand apps, navigation, settings. May want customization.
- **lauschi impact**: The clean, non-childish design serves this group well. Album art as hero (not cartoon UI) avoids the "baby app" rejection.

## Touch Targets

| Age group | Minimum target | Recommended target | Gap between targets |
|-----------|---------------|-------------------|-------------------|
| 3–5       | 60×60dp       | 72×72dp           | 12dp              |
| 6–9       | 48×48dp       | 56×56dp           | 8dp               |
| 10–14     | 44×44dp       | 48×48dp           | 8dp               |

**lauschi decisions:**
- Card grid images: ~110dp square → exceeds all minimums ✓
- Player controls (play/pause): 72dp → meets preschooler target ✓
- Skip prev/next: 56dp → meets school-age target ✓
- PIN numpad keys: 72dp → meets preschooler target ✓
- Now-playing bar: 64dp height, full-width tap → exceeds all minimums ✓
- Parent mode button: 44dp (intentionally small — kids shouldn't notice it)

## Typography

| Age group | Minimum font size | Recommended | Weight     |
|-----------|------------------|-------------|------------|
| 3–5       | 16sp             | 18sp+       | Bold (700) |
| 6–9       | 14sp             | 16sp        | Semi (600) |
| 10–14     | 13sp             | 14sp        | Regular+   |

**lauschi decisions:**
- Card titles: 14sp, 700 weight — readable for 6+ age group
- Player track name: 22sp, 700 weight — readable for all ages
- Body text: 15sp, 400 weight — parent mode primarily
- No text-dependent UI in kid mode (album art carries meaning)

## Color & Contrast

**WCAG 2.2 AA requirements apply:**
- Normal text: 4.5:1 contrast ratio minimum
- Large text (≥18sp bold or ≥24sp regular): 3:1 minimum
- UI components and graphics: 3:1 minimum against adjacent colors

**lauschi palette verification:**
- Text primary (#1A1E1C) on background (#F6F3EE): ~14:1 ✓
- Text primary on surface (#FFFFFF): ~16:1 ✓
- Text secondary (#6B706D) on background: ~4.6:1 ✓ (AA pass)
- White text on primary (#2D7A54): ~4.8:1 ✓ (AA pass)
- Primary button on background: ~5.2:1 ✓

**Color-independence:** No information conveyed by color alone. The "playing" indicator uses green border AND a ▶ badge. Error states use red color AND icon/text.

## Audio & Feedback

### Every tap needs feedback
For ages 3–5, tapping without response feels "broken." All interactive elements must provide:
1. **Visual feedback**: Scale animation (0.96→1.0) or color change
2. **Haptic feedback** (optional): Light vibration on card tap and play/pause
3. **Audio feedback** (optional, future): Subtle sound on card tap — defer to #24

### Now-playing state
The currently playing card must be distinguishable without reading text:
- Green border on the playing card in the grid
- Small ▶ overlay badge on the card image
- Now-playing bar visible at bottom with album art thumbnail

### Audio interruptions
When audio stops unexpectedly (call, other app), the player bar should show a clear paused state. The child should be able to resume by tapping the bar or the card again.

## Navigation & Information Architecture

### Kid mode: Zero navigation
- **One screen only**: Card grid + player overlay
- **No hamburger menus**: Preschoolers don't understand hidden navigation
- **No tabs**: Adds cognitive load without benefit
- **No back button**: Nothing to go back to (grid is home, player is overlay)
- **No text-only buttons**: Every action has a visual affordance (icon, image)

### Parent mode: Standard navigation
- Linear flow: Dashboard → sub-screens → back
- Standard Android back behavior
- Text labels acceptable (adults read)

### The boundary
- Parent mode button: subtle icon in top-right of kid home. Not labeled. 
  Small enough that a 3yo won't accidentally trigger it, recognizable enough
  that a parent finds it.
- PIN gate: prevents accidental access. Custom numpad, not system keyboard.

## Gestures

| Gesture       | Kid mode | Parent mode | Notes |
|---------------|----------|-------------|-------|
| Tap           | ✅ Primary | ✅         | All interactive elements |
| Scroll        | ✅ Vertical | ✅         | Card grid, lists |
| Swipe down    | ✅ Player close | ✅      | Close expanded player |
| Swipe left    | ❌       | ✅ Delete   | Too easy to trigger accidentally for small kids |
| Long press    | ❌       | ✅ Reorder  | No context menus in kid mode |
| Pinch/zoom    | ❌       | ❌          | Not needed anywhere |
| Double tap    | ❌       | ❌          | Unreliable for young children |

## Loading & Error States

### Shimmer placeholders
When cards are loading, show shimmer rectangles in the grid layout. Same size/shape as real cards. Kids understand "something is coming" from the animation.

### Errors in kid mode
- **No error text**: A 4-year-old can't read "Network error."
- **Visual indicator**: Sad face icon or muted card appearance
- **Auto-retry**: Attempt recovery silently in the background
- **Tap-to-retry**: If a card failed to load, tapping it tries again

### Errors in parent mode
- Standard text-based error messages
- Actionable: "Verbindung fehlgeschlagen. Erneut versuchen?"

## Offline Behavior

- Cards that were previously loaded show cached album art
- Tapping a card without connectivity: show brief visual indicator that it can't play, no error dialog
- No "offline mode" banner — just graceful degradation

## Screen Time & Safety

### No addictive patterns
- No autoplay next (parent configures in card what plays)
- No infinite scroll (finite card grid)
- No push notifications (kids don't need them)
- No rewards/gamification (this is a player, not a game)
- No social features

### Sleep timer (future, #21)
- Parent-configured
- Gentle fade-out
- Visual cue (dimming?) before stopping

### Screen lock (kiosk mode)
- Child cannot exit the app (Android: app pinning / kiosk mode)
- No system navigation visible when locked
- Parent PIN required to unlock

## Platform-Specific Notes

### Android (primary)
- Material 3 components with accessibility defaults
- `contentDescription` on all interactive elements for TalkBack
- `importantForAccessibility` set correctly
- Minimum touch targets enforced via theme (already in `app_theme.dart`)
- System font scale respected (but capped at 1.3× to prevent layout breakage)
- Dark theme: not supported in kid mode (always light)

### iOS (next phase)
- Human Interface Guidelines for children's apps
- Dynamic Type support (capped)
- VoiceOver labels on all interactive elements
- Safe area insets respected
- App Store kids category requirements (no external links, no ads)
- Guided Access support for kiosk mode

## Content Model & Card Types

The test audiobooks reveal different content structures:

| Content | Spotify type | Card behavior |
|---------|-------------|---------------|
| Yakari Folge 1 | Album (11 tracks = chapters) | Tap → plays from track 1, continuous |
| Schnecke und Buckelwal | Album (7 tracks) | Tap → plays from track 1 |
| Paw Patrol Folgen 1-4 | Album (bundled episodes) | Tap → plays from track 1 |
| Paw Patrol Kinofilm | Album (movie audiobook) | Tap → plays from track 1 |
| SimsalaGrimm | Album (per-story) | Tap → plays from track 1 |
| Ninjago Folge 1 | Album | Tap → plays from track 1 |
| Spidey Folge 1 | Album | Tap → plays from track 1 |

**Key insight:** Everything maps to "album" on Spotify. A card = one album. Tap = play album from track 1. Player shows current track within the album. Previous/next skip tracks within the album.

**Series handling:** A parent adds individual albums (episodes) as separate cards. Yakari Folge 1 is one card, Yakari Folge 2 is another. The child sees familiar cover art and taps the one they want. No series/season navigation needed in the MVP.

## Test Content — Spotify URIs

Seed data for development and testing:

| Title | Spotify URI | Type | Notes |
|-------|-------------|------|-------|
| Yakari - Folge 1 | `spotify:album:6cW515exmfZuwkDA6Poxlr` | Album (11 tracks) | Classic, distinct cover art |
| LEGO Ninjago - Folge 1 | `spotify:album:7MJxrA8d1DHowkJtvIUrsk` | Album | Action-oriented, older kids |
| Die Schnecke und der Buckelwal (Hörspiel) | `spotify:album:5O8o7vJ8WCFM9l0CBFWLkx` | Album (7 tracks) | Short, younger kids |
| Die Schnecke und der Buckelwal (ungekürzt) | `spotify:album:3ufkKdzYUCnOplUlzPHeHQ` | Album (5 tracks) | Audiobook version |
| PAW Patrol - Folgen 1-4 | `spotify:album:3ITUJBzcS3OzO2YIJKXRbA` | Album (bundled) | Series content |
| PAW Patrol - Der Mighty Kinofilm | `spotify:album:1YF2DKgFdvXItvrZmdxssn` | Album | Long-form movie audiobook |
| Spidey - Folge 1 | `spotify:album:2CRvRuBjaCYAvtTtTen8Z5` | Album (17 tracks) | Marvel, action |
| SimsalaGrimm - Die Bremer Stadtmusikanten | `spotify:album:5cPNQ63oqUjhbkOpTJ3kgS` | Album | Fairy tale, all ages |

This set covers:
- Age range: 3yo (Schnecke) through 12yo (Ninjago, Spidey)
- Content types: short audiobook, series episode, movie audiobook, fairy tale
- Different cover art styles: cartoon, photo, illustration
- Different episode structures: few tracks vs many tracks
