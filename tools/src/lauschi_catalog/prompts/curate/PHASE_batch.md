## Phase: Batch curation

You receive:
- Series title and episode_pattern
- Progress so far (included/excluded counts, prior episode numbers per provider)
- A batch of albums with full metadata (XML: title, release_date, type, tracks_count, duration_min, label, artist, sample tracks, and `<episode_range>` for an album whose title names a run of episodes)

For each album: decide include or exclude.

**You do not number the albums.** After the batch, code reads every
number from the title (what the episode_pattern captures, or the first
number of a run like "Folgen 6-10"), the track names and the same album on
the other provider, and takes none from anywhere else. A title the pattern
does not match is still included if it is a valid episode, without a number.

**Exclude with a named reason** from the failure taxonomy. The `exclude_reason`
field is an enum; use exactly one of these values:

| Value | When to use |
|---|---|
| `compilation` | Re-sells episodes that exist on their own: box sets, "Best of", a "Folge 1-10" run whose episodes are also released alone |
| `kinderlieder_compilation` | "Die schönsten..." children's song compilations |
| `multi_artist_compilation` | Multi-artist compilations, "Kinderparty" releases |
| `wrong_content_type` | Audiobook reading in a Hörspiel series, music in a non-music series, etc. |
| `music_single` | Single track under 5 min, not an episode |
| `format_variant` | Karaoke, instrumental, sped-up, nightcore versions |
| `sub_series_bleed` | Belongs to a sibling line (the prompt lists the sibling entries that exist; a line with no entry yet counts too) |
| `duplicate` | Same content, same provider (keep the most recent) |
| `not_kids_content` | Adult content in a children's series |
| `different_series` | Belongs to a completely different series |
| `partial_release` | Incomplete or preview release |
| `unspecified` | Catch-all when no other category fits (prefer including instead) |

If you cannot name a pattern from this list, **include**.

**Cross-provider consistency**: same include/exclude decision on both providers
for the same title. Different track counts are expected, never a reason to exclude.

If the provided metadata for an album is insufficient to make a confident
decision (e.g. missing track listing, unclear album type), call
`get_album_details` to fetch the full data before deciding.

**Output:** one decision for EVERY album in the batch: `provider` and `id`
as the batch gives them, `include`, `exclude_reason` for an exclusion,
`confidence`, and `notes`.

### Worked examples

Given `episode_pattern: ^Folge (\d+):` for series "Die drei ???":

**Clear include** (pattern matches, episode shape):
```
Title: "Folge 1: Der Super-Papagei"
Reasoning:
  1. Pattern check: "Folge 1:" matches ^Folge (\d+):, captures "1"
  2. Track shape: 26 tracks, ~50 min total, typical Hörspiel structure
  3. No failure-taxonomy pattern applies
→ include=true, confidence=high
```

**Clear exclude** (compilation box set):
```
Title: "Folge 1-10: Jubiläumsbox"
<episode_range first="1" last="10" also_released_alone="1, 2, 3, 4, 5, 6, 7, 8, 9, 10"/>
Reasoning:
  1. Pattern check: "Folge 1-10:" does NOT match ^Folge (\d+): (a run, not one episode)
  2. episode_range: all ten episodes are released on their own on this page,
     so the box re-sells them (compilation_as_episode)
  3. Track count: 78 tracks fits a box set
→ include=false, exclude_reason=compilation, confidence=high
```

**A run that is the episode release** (the only way to hear these episodes):
```
Title: "Folgen 6-10: Das Baby im Schafspelz"
<episode_range first="6" last="10" also_released_alone="none"/>
Reasoning:
  1. Pattern check: no match, the title names a run of episodes
  2. episode_range: none of 6 to 10 exists on its own on this page, so this
     album is their only release, not a repackaging
  3. A run takes the number of its first episode, read from its title
→ include=true, confidence=high
```

**No pattern match, but valid episode** (different naming era):
```
Title: "Der Super-Papagei" (3 tracks, 45 min, 1979)
Reasoning:
  1. Pattern check: no match for ^Folge (\d+):
  2. Can I name a failure pattern? No. "Der Super-Papagei" isn't a compilation,
     music single, or wrong content type.
  3. Track shape: 3 tracks, 45 min is consistent with early Apple Music
     Hörspiel packaging (one track per act).
  4. Inclusion bias: can't name a failure pattern, so include.
  5. Confidence: medium because pattern didn't match, but duration and
     track shape fit.
→ include=true, confidence=medium
  notes: "No pattern match; track shape and duration suggest real episode from pre-numbering era"
```

**Cross-provider pair** (not a duplicate):
```
spotify: "Folge 1: Der Super-Papagei" (ep 1, 26 tracks)
apple_music: "Die drei ??? Folge 1: Der Super-Papagei" (ep 1, 3 tracks)
Reasoning:
  1. Same episode number (1) on different providers
  2. This is cross_provider_pair, NOT a duplicate
  3. Different track counts (26 vs 3) reflect platform packaging differences
  4. Both are the same content in different catalogs
→ Include BOTH with their respective provider tags. confidence=high for both.
```

**Audiobook reading in a Hörspiel series**:
```
Title: "Die drei ??? - gelesen von Rufus Beck (ungekürzt)"
Reasoning:
  1. Pattern check: no match for ^Folge (\d+):
  2. "gelesen von" (read by) + "ungekürzt" (unabridged) = audiobook reading
  3. Named failure pattern: wrong_content_type (audiobook in a Hörspiel series)
  4. This is a different format of the content, not a Hörspiel episode
→ include=false, exclude_reason=wrong_content_type, confidence=high
  notes: "Audiobook reading, not a Hörspiel episode"
```

**Ambiguous, can't name a failure pattern** (default to include):
```
Title: "Sonderfolge: Das Geheimnis der Geisterinsel"
Reasoning:
  1. Pattern check: no match for ^Folge (\d+): ("Sonderfolge" != "Folge")
  2. Can I name a failure pattern? No. "Sonderfolge" (special episode) is
     not a compilation, music single, or wrong content type.
  3. Track shape: 12 tracks, 48 min, consistent with Hörspiel episode
  4. Inclusion bias: can't name a failure pattern, and track shape fits.
     A child looking for this special episode should find it.
→ include=true, confidence=low
  notes: "Special episode ('Sonderfolge'), no episode number extractable"
```
