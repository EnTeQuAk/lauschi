# lauschi — App Design

## Design Direction

**Creative North Star: "The Listening Fox"**

The lauschi mascot is a watercolor fox — green fur, terracotta headphones, cream belly, eyes closed in contentment. The entire design system is derived from this character. The app should feel like handing a child that fox: calm, warm, trustworthy, and already listening.

The kid experience is one screen, one decision. Album art is the hero; the UI recedes. Parent mode shifts to a slightly cooler, more information-dense tone, but the same fox DNA runs through both. There is no dark mode. There are no tabs, no feeds, no algorithms. Just curated cards and a calm listening room.

### Aesthetic DNA
The fox's character drives every choice:
- **Warmth and generosity of space** — Headspace's unhurried calm, translated into big touch targets, generous gaps, and rounded organic shapes
- **Green as the identity color** — confident but not aggressive; the fox's fur, not a brand stamp
- **Editorial restraint** — the fox sits quietly, eyes closed. The UI should feel the same. Minimal text, no chrome, no density
- **Tactile softness** — rounded terminals on Nunito, spring-curve press animations, no sharp edges anywhere
- **Content-forward** — album art dominates every screen. The fox doesn't compete with the stories; the UI shouldn't either

### What we're NOT
- Spotify's dark density — too much chrome, too many options
- Over-colorful toy-store energy — garish, overstimulating
- Flat, characterless Material defaults — generic, no warmth
- Algorithmic feeds, autoplay queues, "up next" strips — any pattern that removes parent control
- Continuous motion — pulsing, spinning, bouncing loops. The fox is still; motion is breathing, not performing

---

## Color System

Forest green as the identity color — confident, fresh, positive. Paired with warm cream backgrounds and a terracotta/amber accent that brings warmth without competing with album art.

```
Background:       #F0EDE0    warm cream, paper-like. The fox's paper.
Surface:          #FFFFFF    cards, sheets
Surface Dim:      #E7E3CE    secondary surfaces, dividers
Surface Tinted:   #E8F2EB    green-tinted surface (active states, badges)

Parent Background:#EAE8DD    parent mode scaffold — same room, different light
Parent Surface:   #F4F3EF    parent mode cards — more neutral, less playful

Primary:          #2D7A54    forest green — the fox's fur. Buttons, active indicators, links
Primary Soft:     #5BA37D    lighter green — hover, secondary buttons, paused borders
Primary Pale:     #D4EDDF    pale green tint — backgrounds, selected states

Accent:           #D4845A    warm terracotta — the headphones. Now-playing highlight, warmth
Accent Pale:      #FAEEE6    terracotta tint — subtle warm backgrounds

Text:             #1A1E1C    near-black, warm. Never pure black.
Text Secondary:   #555A57    muted, for labels and metadata
Text Tertiary:    #9CA09E    disabled text, hints
Text Hint:        #ABAFAD    placeholder text
Text On Primary:  #FFFFFF    white on green

Error:            #C44B3B    muted red — wrong PIN, expired content
Warning:          #AA7A18    rare cautionary states
Success:          #2D7A54    reuses primary
```

**Why this palette works for a kids audio player:**
- Album art is the wildcard — cover images range from neon cartoon to muted photography. The neutral warm background and restrained UI colors let every cover pop equally.
- Green reads as safe, calm, natural. Parents trust it. Kids don't notice it (they notice the album art).
- Terracotta as accent adds human warmth without the childishness of yellow or the aggression of red.

**The Album Art Rule.** UI colors are intentionally restrained so every album cover pops equally. If a screen feels busy, the UI is stealing from the art. Remove, don't add.

---

## Typography

**Nunito** (Google Fonts) — not Nunito Sans. Nunito has fully rounded terminals that feel friendly and approachable. It's the typographic equivalent of Headspace's rounded illustrations.

| Role            | Weight | Size  | Tracking | Use                           |
|-----------------|--------|-------|----------|-------------------------------|
| Screen title    | 800    | 28sp  | -0.02em  | "Meine Hörspiele"            |
| Section head    | 700    | 20sp  | -0.01em  | Category labels               |
| Card title      | 700    | 13sp  | 0        | Below card, 2 lines max       |
| Now playing     | 700    | 15sp  | 0        | Track name in player bar      |
| Body            | 400    | 15sp  | 0        | Settings, descriptions        |
| Caption         | 600    | 12sp  | 0.02em   | "4 Folgen", metadata          |
| Button          | 700    | 15sp  | 0.01em   | Primary actions               |

**The No-Em-Dash Rule.** Typography follows the same voice as copy: commas, colons, semicolons, periods, or parentheses. Never em-dashes or en-dashes.

---

## Screens

### 1. Kid Home — Card Grid

The entire kid experience is one screen. No tabs, no navigation hierarchy, no menus. A grid of album art cards. Tap → play.

```
┌──────────────────────────────┐
│                              │
│  Meine Hörspiele    [👤]     │  ← warm greeting, parent button (subtle)
│                              │
│  ┌───────┐ ┌───────┐ ┌───────┐
│  │       │ │       │ │       │
│  │  art  │ │  art  │ │  art  │  ← square, 16dp radius
│  │       │ │       │ │       │     fills available width
│  └───────┘ └───────┘ └───────┘
│  Bibi &     Die drei   Paw
│  Tina       ???        Patrol
│                              │
│  ┌───────┐ ┌───────┐ ┌───────┐
│  │       │ │       │ │       │
│  │  art  │ │  art  │ │  art  │
│  │       │ │       │ │       │
│  └───────┘ └───────┘ └───────┘
│  Bummel-    DIKKA      Conni
│  kasten                      │
│                              │
│  ┌───────┐ ┌───────┐        │
│  │       │ │       │        │
│  └───────┘ └───────┘        │
│                              │
│                              │
├──────────────────────────────┤
│ [art] Bibi & Tina · F23  ▶ ││  ← now-playing bar
└──────────────────────────────┘
```

**Grid:**
- 3 columns phone, 4 large phone, 5 tablet
- Gap: 12dp horizontal, 16dp vertical (tight — the art is the star)
- Card = image only (rounded), title below in regular weight
- Padding: 20dp horizontal, generous top padding for "Meine Hörspiele"

**Card visual treatment:**
- Default: rounded square image, subtle shadow (elevation 1)
- Playing: forest green border (3dp), small ▶ badge overlay bottom-right
- Pressed: scale 0.96 with spring curve (200ms)
- No card "container" — just the image floating on the cream background

**Empty state:**
When no cards exist yet (fresh install), show a centered illustration + "Füge dein erstes Hörspiel hinzu" with a green button → parent mode.

**Now-playing bar:**
- Appears only when something is playing
- Slides up with ease-out (300ms)
- Height: 64dp
- Contents: 44dp rounded album art, track + artist name, play/pause circle button
- Background: Surface (#FFF) with subtle top border
- Tap anywhere on bar → expand to full player

### 2. Full Player

Expands from the now-playing bar with a hero animation on the album art.

```
┌──────────────────────────────┐
│                              │
│            [▾]               │  ← collapse handle (pill shape)
│                              │
│                              │
│      ┌──────────────┐        │
│      │              │        │
│      │              │        │
│      │  album art   │        │  ← 280dp, 20dp radius
│      │              │        │     subtle shadow
│      │              │        │
│      └──────────────┘        │
│                              │
│      Bibi und Tina           │  ← 700 weight, 22sp
│      Folge 23                │  ← 400 weight, 15sp, secondary color
│                              │
│      ━━━━━━━━━━○─────────    │  ← green track, 6dp height
│      12:34            45:01  │
│                              │
│          ⏮    ▶    ⏭        │  ← play/pause 72dp, skip 56dp
│                              │
│                              │
└──────────────────────────────┘
```

**Player details:**
- Background: warm cream (#F6F3EE), or: extract album art dominant color, use as 5% tint on cream
- Album art: large, centered, with soft shadow (y: 8, blur: 24, opacity: 0.1)
- Progress bar: rounded capsule, green fill, 6dp height — thick enough for kid fingers to drag
- Controls: play/pause is a filled green circle (72dp) with white icon. Previous/next are ghost circles.
- No shuffle, no repeat, no queue — just previous, play/pause, next
- Collapse: swipe down or tap the pill handle

### 3. PIN Entry

```
┌──────────────────────────────┐
│                              │
│                              │
│           🔒                 │  ← lock icon, 48dp, forest green
│                              │
│      Eltern-Bereich          │  ← 700 weight, 24sp
│      PIN eingeben            │  ← 400 weight, 15sp, secondary
│                              │
│       ●  ●  ○  ○            │  ← dots, 16dp, green when filled
│                              │
│      ┌───┬───┬───┐          │
│      │ 1 │ 2 │ 3 │          │  ← custom numpad
│      ├───┼───┼───┤          │     72dp buttons
│      │ 4 │ 5 │ 6 │          │     surface color, rounded
│      ├───┼───┼───┤          │     green text, 22sp, 700 weight
│      │ 7 │ 8 │ 9 │          │
│      ├───┼───┼───┤          │
│      │   │ 0 │ ⌫ │          │
│      └───┴───┴───┘          │
│                              │
│      [Abbrechen]             │  ← text button, goes back to kid mode
│                              │
└──────────────────────────────┘
```

**PIN behavior:**
- Custom numpad (not system keyboard) — intentional, feels secure
- Digits: bounce animation on entry (scale 1.0 → 1.3 → 1.0, 150ms)
- Wrong PIN: dots shake horizontally (300ms), turn error red briefly
- Correct PIN: dots turn green, brief pause, navigate to parent mode
- No "forgot PIN" — parent can reinstall or we add recovery later

### 4. Parent Mode — Dashboard

After PIN. Shifts to redan.ai's editorial tone. Cooler background, tighter typography, standard Material interactions.

```
┌──────────────────────────────┐
│  ←                  lauschi  │
│                              │
│  SAMMLUNG                    │  ← section header, caption style
│  ┌──────────────────────┐    │
│  │  📚 12 Karten        → │  │  ← card management
│  └──────────────────────┘    │
│                              │
│  STREAMING                   │
│  ┌──────────────────────┐    │
│  │  ● Spotify verbunden → │  │  ← account info
│  └──────────────────────┘    │
│                              │
│  EINSTELLUNGEN               │
│  ┌──────────────────────┐    │
│  │  PIN ändern          → │  │
│  │  Schlaf-Timer        → │  │
│  │  Über lauschi        → │  │
│  └──────────────────────┘    │
│                              │
└──────────────────────────────┘
```

**Parent mode visual shift:**
- Background: slightly cooler cream (#F0EEEB)
- Typography: smaller, tighter, more information-dense
- No playful animations — standard transitions
- Green accent stays (brand continuity across both modes)

### 5. Card Management (Parent)

```
┌──────────────────────────────┐
│  ← Karten            [+ Neu]│
│                              │
│  Ziehen zum Sortieren        │  ← hint, disappears after first use
│                              │
│  ┌─────┬─────────────────┐   │
│  │ art │ Bibi und Tina   │   │  ← list rows, not grid
│  │ 48  │ 12 Folgen    ≡  │   │     drag handle right
│  └─────┴─────────────────┘   │
│  ┌─────┬─────────────────┐   │
│  │ art │ Die drei ???    │   │
│  │ 48  │ Hörspiel     ≡  │   │
│  └─────┴─────────────────┘   │
│                              │
│  ← swipe to delete          │
│                              │
└──────────────────────────────┘
```

### 6. Add Card (Parent)

```
┌──────────────────────────────┐
│  ← Neue Karte                │
│                              │
│  🔍 Auf Spotify suchen...    │  ← search field, rounded
│                              │
│  ┌─────┬──────────────┬──┐   │
│  │ art │ Die drei ???  │ +│   │  ← results list
│  │     │ Hörspiel      │  │   │     + button = add to collection
│  └─────┴──────────────┴──┘   │
│  ┌─────┬──────────────┬──┐   │
│  │ art │ Die drei !!!  │ +│   │
│  │     │ Hörspiel      │  │   │
│  └─────┴──────────────┴──┘   │
│                              │
└──────────────────────────────┘
```

### 7. Onboarding

Headspace-inspired: minimal, warm, immediate.

**Screen 1 — Welcome:**
- lauschi logo centered
- "Dein Hörspiel-Player" below
- Warm cream background with subtle green accents
- Single green button: "Los geht's"

**Screen 2 — Connect:**
- "Verbinde deinen Musik-Dienst"
- Spotify button (green) + Apple Music button (outline)
- Skip option (can connect later)

**Screen 3 — First card:**
- Redirect to Add Card flow
- "Füge das erste Hörspiel hinzu"
- After adding → straight to kid home with one card

No tutorial, no feature tour, no carousel of benefits. Three taps and you're listening.

---

## Interaction & Motion

**Headspace principle:** motion should feel like breathing — smooth, organic, unhurried.

| Interaction         | Motion                                         |
|---------------------|-------------------------------------------------|
| Card tap            | Scale 0.96 → 1.0, ease-in-out, 150ms           |
| Now-playing appear  | Slide up from bottom edge, ease-out, 300ms      |
| Player expand       | Hero animation on album art, ease-in-out, 350ms |
| Player collapse     | Reverse hero, slide down, 300ms                 |
| Card playing        | Subtle green border fade-in (no pulse/animation) |
| PIN digit entered   | Dot scales 1.0 → 1.3 → 1.0, spring, 150ms     |
| PIN wrong           | Dots shake horizontally, 300ms, haptic feedback  |
| Page transitions    | Shared axis (Material 3), 300ms                  |
| Shimmer loading     | Gentle left-to-right sweep on placeholder shapes |

**Elevation philosophy:** Flat by default. The app lives on warm cream paper — shadows would feel out of place. Depth is conveyed through tonal layering (warm cream → white surface → dim surface), color borders (green for active, terracotta for next-in-queue), and brief scale animation. Shadows are used sparingly: a soft lift under player album art, a green glow for drag feedback, a tiny drop under floating badges.

**The No-Layering-Without-Reason Rule.** If a surface doesn't need to float, it doesn't get a shadow. Most depth is communicated by color and position.

**No:**
- Continuous animations (pulsing, spinning, bouncing loops)
- Toasts or snackbars (use inline feedback)
- Loading spinners (use shimmer placeholders)
- Any motion that draws attention away from the content

---

## Spacing & Layout

**Base unit: 4dp** — all spacing is a multiple.

| Token   | Value | Use                                  |
|---------|-------|--------------------------------------|
| xs      | 4dp   | Icon padding, tight gaps             |
| sm      | 8dp   | Internal card padding                |
| md      | 16dp  | Standard gap, component spacing      |
| lg      | 24dp  | Screen horizontal padding            |
| xl      | 32dp  | Section separators                   |
| xxl     | 48dp  | Major vertical breathing room        |

**Card grid specifics:**
- Horizontal padding: 20dp (slightly generous)
- Grid gap: 12dp horizontal, 8dp vertical (art-to-title tight)
- Title padding below image: 8dp
- Title-to-next-card: 16dp

**Touch targets:** 48dp minimum, 64dp+ for kid-facing controls (player buttons, numpad)

---

## The Two Modes — Visual Summary

| Aspect       | Kid Mode                              | Parent Mode                      |
|--------------|---------------------------------------|----------------------------------|
| Background   | Warm cream (#F0EDE0)                  | Cool cream (#EAE8DD)             |
| Personality  | Album art is hero, UI invisible       | Editorial, settings-like          |
| Typography   | Large, bold, minimal labels           | Standard, information-dense       |
| Layout       | Card grid + player. That's it.        | Lists, grouped settings           |
| Navigation   | None. One screen + player overlay.    | Standard back/forward stack       |
| Motion       | Spring animations, hero transitions   | Material 3 shared axis            |
| Accent use   | Green border on playing card          | Green for toggles, links          |

The PIN is the portal between two different experiences in one app.

---

## Radius System

Consistent rounded corners reinforce the Headspace-like organic feel.

| Element          | Radius  |
|------------------|---------|
| Card images      | 16dp    |
| Buttons          | 12dp    |
| Player sheet     | 24dp    |
| Input fields     | 12dp    |
| PIN numpad keys  | 16dp    |
| Now-playing bar  | 0 (full width, top corners only 16dp when sheet) |
| Chips / badges   | 999dp (pill)  |

---

## Assets Needed

- [ ] App icon (lauschi wordmark or abstract ear/headphone mark — separate task)
- [ ] Splash screen (logo on cream)
- [ ] Nunito font (Google Fonts, bundled)
- [ ] Player controls: Material Symbols Rounded (built-in, no extra package)
- [ ] Placeholder card image (simple illustration or abstract pattern)
- [ ] Empty state illustration (kid-friendly, minimal line art)
- [ ] Lock icon for parent gate

---

## Open Questions

1. **Dark mode?** — Not for MVP. Kids mode is always light. Revisit later.
2. **Landscape?** — Portrait-only for phone. Tablet gets landscape later.
3. **Card labels/categories?** — Not for MVP. All cards in one flat grid. Categories add complexity without clear kid benefit.
4. **Card long-press in kid mode?** — Does nothing. No context menus, no options, no confusion.
5. **Multiple profiles/kids?** — Not for MVP. One collection per device. Revisit based on user feedback.

---

## Do's and Don'ts

### Do:
- **Do** let album art dominate every screen it's on. UI chrome recedes.
- **Do** use forest green for every primary action, active state, and playing indicator. Consistency builds trust.
- **Do** keep touch targets at 48dp minimum, 64dp+ for kid-facing controls.
- **Do** combine color with shape or position for state. Never color alone. (Green border + play badge on active card, not just green border.)
- **Do** use brief, terminal animations (scale 0.96, 150ms ease-in-out) for tactile feedback. No loops, no pulses, no continuous motion.
- **Do** use Nunito for everything. One family; weight and size create hierarchy.
- **Do** prefer inline feedback over toasts or snackbars. No popups for confirmation.
- **Do** use shimmer placeholders (gentle left-to-right sweep) instead of spinners for loading states.
- **Do** keep the app always light. Warm cream is the fox's paper.

### Don't:
- **Don't** use pure black or pure white as page backgrounds. Tint neutrals toward the fox's green.
- **Don't** add tabs, carousels, feeds, or recommendation strips to the kid experience. One screen. One decision.
- **Don't** use side-stripe borders (colored left borders on cards, lists, or callouts).
- **Don't** use gradient text. Use weight or size for emphasis.
- **Don't** use glassmorphism. No blurs, no frosted cards.
- **Don't** use modals as a first thought. Exhaust inline and progressive alternatives.
- **Don't** rely on color alone for state. Combine with icon, shape, or position (color-vision safety).
- **Don't** use Spotify's dark density, over-colorful toy-store energy, or flat characterless Material defaults.
- **Don't** use continuous animations — pulsing, spinning, bouncing loops. Motion is breathing, not performing.
- **Don't** use em-dashes in any copy. Commas, colons, semicolons, periods, or parentheses.
- **Don't** add long-press menus, context menus, or hidden gestures in kid mode. Predictable tap-only.
