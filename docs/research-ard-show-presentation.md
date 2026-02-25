# ARD Audiothek: Show Presentation Research

Research into the ARD Audiothek GraphQL API to discover unused metadata fields
that could improve how shows (Sendungen) are presented in lauschi.

## API Surface

Endpoint: `https://api.ardaudiothek.de/graphql`
Schema explorer: `https://api.ardaudiothek.de/graphiql`

### Fields We Already Use

**ProgramSet** (show): `id`, `title`, `synopsis`, `numberOfElements`,
`lastItemAdded`, `feedUrl`, `image.url1X1`, `publicationService.title`

**Item** (episode): `id`, `title`, `synopsis`, `duration`, `publishDate`,
`endDate`, `episodeNumber`, `isPublished`, `image.url1X1`, `programSet.title`,
`audios { url mimeType }`

### Fields Available But Not Used

**ProgramSet:**

| Field | Type | Value for Presentation |
|---|---|---|
| `showType` | Enum: `INFINITE_SERIES`, `FINITE_SERIES`, `SEASON_SERIES`, `SINGLE` | All kids shows are INFINITE_SERIES currently. Could change. |
| `description` | HTML | Richer than `synopsis`. Contains age ranges for some shows (parseable). |
| `publicationService.brandingColor` | Hex color (e.g., `#FF6B00`) | Publisher brand color. Could tint UI elements. |
| `publicationService.organization.name` | String (e.g., `BR`, `WDR`, `NDR`) | Short broadcaster name. Better than full `publicationService.title`. |
| `groupingsByProgramsetId` | Connection | Sub-groups: MULTIPART story arcs, SEASON divisions. Betthupferl has 10+ multipart arcs. |

**Item:**

| Field | Type | Value for Presentation |
|---|---|---|
| `titleClean` | String | Strips suffix (age/broadcaster info) from title. "Tante Silvias Bilder: Putztag" instead of "Tante Silvias Bilder: Putztag \| Gute-Nacht-Geschichte ab 5 Jahren / Mundart Oberfranken" |
| `titleWithoutNumber` | String | Strips "(1/7)" numbering. "Gabriele in der gelben Zeit : Die Herkunft des Drachen" instead of "Gabriele in der gelben Zeit (7/7): Die Herkunft des Drachen" |
| `itemType` | Enum: `EPISODE`, `EVENT_LIVESTREAM`, `SECTION`, `EXTRA`, `NOT_FOUND` | Filter out non-episodes. |
| `status` | Enum: `PUBLISHED`, `SCHEDULED`, `DEPUBLISHED`, etc. | Track content lifecycle beyond `isPublished`. |
| `groupId` + `group { title type count }` | Grouping ref | Links episode to its multipart group. |
| `nextEpisode { id title }` | Item ref | For "play next" functionality. Mostly null in practice. |
| `transcript { text }` | String | Available on schema but empty for kids content. |

**Concepts/keywords/subjects**: Schema has them, but they're sparse/empty for kids content. Not useful yet.

## Content Taxonomy

Analysis of the 30 kids shows in "Fur Kinder" category reveals natural clusters
based on episode duration, publishing frequency, and episode count:

### Bedtime Stories (Gute-Nacht)
Short, daily, for winding down.

| Show | Avg Duration | Episodes | Last Updated | Org |
|---|---|---|---|---|
| Betthupferl | 4 min | 800 | daily | BR |
| Gute Nacht mit der Maus | ~5 min | 29 | daily | WDR |
| Unser Sandmannchen | ~5 min | 211 | daily | RBB |
| Krumelgeschichten | ~5 min | 227 | daily | MDR |

### Audio Dramas (Horspiele)
Longer, immersive stories. The core kids audio content.

| Show | Avg Duration | Episodes | Last Updated | Org |
|---|---|---|---|---|
| MausHorspiel lang | 46 min | 108 | weekly | WDR |
| NDR Horspiele/Geschichten/Marchen | 56 min | 32 | weekly | NDR |
| Die Marchen der ARD | 55 min | 47 | monthly | ARD |
| Pumuckl - Der Horspiel-Klassiker | 27 min | 18 | monthly | BR |
| Kakadu - Das Kinderhorspiel | ~30 min | 69 | biweekly | DLF |
| Geschichten fur Kinder | ~25 min | 57 | weekly | BR |

### Knowledge Podcasts (Wissen)
Educational, question-and-answer format.

| Show | Avg Duration | Episodes | Last Updated | Org |
|---|---|---|---|---|
| CheckPod (Checker Tobi) | 20 min | 130 | biweekly | BR |
| Wunderwigwam | 20 min | 131 | biweekly | HR |
| Anna und die wilden Tiere | 15 min | 99 | weekly | BR |
| Kakadu - Der Kinderpodcast | ~15 min | 52 | weekly | DLF |
| Figarino | ~25 min | 420 | weekly | MDR |

### Short Stories (Kurzgeschichten)
Medium-length standalone stories.

| Show | Avg Duration | Episodes | Last Updated | Org |
|---|---|---|---|---|
| MausHorspiel kurz | 7 min | 200 | daily | WDR |
| Ohrenbar | 13 min | 607 | daily | ARD/RBB |

### Archived / Dormant
Shows with 300+ days since last episode.

| Show | Episodes | Days Since Last | Org |
|---|---|---|---|
| Marco Polo Shorties | 40 | 1254 | MDR |
| Big Baam | 26 | 1154 | MDR |
| Schloss Einstein Podcast | 24 | 1158 | MDR |
| hr2 Geschichten (2 shows) | 12 each | 1103-1254 | HR |
| Rikes Laberbuch | 10 | 1254 | MDR |

## Key Insights

### 1. `titleClean` is a Big Win

Currently we show raw titles like:
> "Superhelden: Einhorn-Spitzer Handschuh | Gute-Nacht-Geschichte ab 5 Jahren mit Rufus Beck"

Using `titleClean` gives us:
> "Superhelden: Einhorn-Spitzer Handschuh"

This is a one-line change in the GraphQL query and model that immediately
improves readability. Especially on the kid-facing player screen where space
is limited.

### 2. Per-Episode Artwork is the Norm

Most shows provide unique artwork per episode, not just the show's cover.
MausHorspiel, Betthupferl, Ohrenbar, and Pumuckl all have episode-specific
images. We already fetch `image.url1X1` per item but this is worth leveraging
more prominently in the tile detail and player screens.

### 3. Multipart Groupings Are Underused

Betthupferl has multipart story arcs (5-episode arcs like "Superhelden" or
"Tante Silvias Bilder"). Figarino has 2-part stories. These groupings exist
in the API via `groupingsByProgramsetId` and `item.group`.

In the episode list, we could:
- Group episodes under their story arc title
- Show "Teil 1/5" labels using the group metadata instead of parsing titles
- Auto-select complete arcs when adding episodes

### 4. Broadcaster Branding Colors

Every publisher has a `brandingColor` hex value. We could use this for subtle
UI tinting (e.g., the show detail header, or a colored strip on episode tiles).

Key colors from the kids catalog:
- BR: `#FF6B00` (orange), BR-KLASSIK: `#E2002C` (red), BR other: `#006AFF` (blue)
- WDR/Die Maus: `#FF8200` (orange)
- NDR: `#0277BF` (blue) / `#B63929` (red)
- MDR: `#3C8CE6` (blue), MDR SACHSEN: `#76B72A` (green)
- HR: `#EC6602` (orange)
- DLF/Kakadu: `#FF7900` (orange)
- ARD: `#003480` (dark blue)
- RBB/Sandmannchen: `#FEE600` (yellow)

### 5. Duration Indicators

Episode durations cluster into distinct bands:
- **Short** (≤ 5 min): Bedtime stories
- **Medium** (6-15 min): Short stories, knowledge snippets
- **Long** (16-30 min): Full knowledge podcasts, classic Horspiele
- **Extra long** (30+ min): Full audio dramas, fairy tales

A simple duration badge or icon in the show card (moon for bedtime, book for
stories, lightbulb for knowledge) would help parents choose appropriate content
at a glance.

### 6. Freshness and Staleness

Some shows are actively publishing (daily/weekly), others are dormant archives.
`lastItemAdded` tells us this. Shows that haven't published in 300+ days could
be labeled "Archiv" or sorted lower.

Negative "days ago" values in `lastItemAdded` indicate pre-scheduled content
(the ARD CMS sets future publish dates).

### 7. Organization Name vs Publication Service Title

We currently show `publicationService.title` which can be verbose
("Deutschlandfunk Kultur", "MDR TWEENS", "Antenne Brandenburg").
`publicationService.organization.name` gives shorter labels
("Deutschlandradio", "MDR", "RBB") that work better in tight UI spaces.

## Recommended Changes

### Quick Wins (can do now)

1. **Add `titleClean` to item queries** and use it for display.
   Fall back to `title` if `titleClean` is null.

2. **Add `publicationService.organization.name`** to show queries.
   Display as a short broadcaster tag in the show grid.

3. **Add `publicationService.brandingColor`** to show queries.
   Store it; use it later for visual tinting.

4. **Add `showType`** to show queries. Store for future use.

### Medium-Term (discover screen improvements)

5. **Duration-based categorization** in the discover screen.
   Instead of one flat grid sorted by episode count, group shows into
   "Gute-Nacht" / "Horspiele" / "Wissen" / "Geschichten" sections.
   Classification can be heuristic based on avg episode duration plus
   title keyword matching.

6. **Freshness indicator** on show cards. Shows with `lastItemAdded`
   within the past 7 days get a "Neu" badge. Dormant shows (300+ days)
   get sorted to end or into an "Archiv" section.

7. **Episode artwork in tile detail**. When episodes have unique artwork,
   show it as a thumbnail in the episode list instead of the show's
   cover for every row.

### Longer-Term (episode list improvements)

8. **Multipart grouping** in episode lists. Fetch
   `groupingsByProgramsetId` for shows with groupings. In the episode
   list, render group headers and allow adding complete story arcs
   as a unit.

9. **Content type indicator** in the player. Show "Gute-Nacht-Geschichte"
   or "Horspiel" as a subtle label below the title, derived from
   show classification.

## Model Changes Needed

```dart
// Add to ArdProgramSet:
final String? showType;         // "INFINITE_SERIES", etc.
final String? description;      // HTML description
final String? organizationName; // Short broadcaster name
final String? brandingColor;    // Hex color like "#FF6B00"

// Add to ArdItem:
final String? titleClean;       // Cleaned title without suffixes
```

GraphQL query changes are minimal: just adding the fields to existing
queries.
