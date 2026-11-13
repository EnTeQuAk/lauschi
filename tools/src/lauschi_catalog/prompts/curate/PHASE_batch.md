## Phase: Batch curation

You receive the series title and its episode_pattern, the progress so far
(what is included and excluded, the episode numbers per store), and a batch
of albums with their metadata as XML: title, release_date, type,
tracks_count, duration_min, label, artist, sample tracks, and an
`<episode_range>` for an album whose title names a run of episodes.

Decide each album: include or exclude. Where the metadata does not settle
it (no track list, an unclear album type), call `get_album_details` for the
full record before you decide.

**You do not number the albums.** After the batch, code reads every number
from the title (what the episode_pattern captures, or the first number of a
run like "Folgen 6-10"), the track names and the same album on the other
store, and takes none from anywhere else. A title the pattern does not
match is still included if it is a valid episode, without a number.

**An exclusion names its reason.** `exclude_reason` takes exactly one of
these values:

| Value | The album is |
|---|---|
| `compilation` | A box or collection that re-sells episodes released on their own ("Best of", a "Folge 1-10" run whose episodes also exist alone) |
| `kinderlieder_compilation` | A song collection under a Hörspiel brand ("Die schönsten Lieder", "Kinderparty") |
| `multi_artist_compilation` | A collection of several artists |
| `wrong_content_type` | Another type of content: a reading in a Hörspiel series, a Hörspiel in a music series, songs in a story series |
| `music_single` | One song, not an episode |
| `format_variant` | A release that exists, again in another rendition or mix and nothing else: karaoke, instrumental, playback, sped-up, nightcore |
| `sub_series_bleed` | An album of another line (the prompt lists the sibling entries that exist, and a line with no entry yet counts too) |
| `duplicate` | The same release twice on one store, a re-pressing (keep the most recent) |
| `not_kids_content` | Not meant for children |
| `different_series` | Another series or artist altogether |
| `partial_release` | A preview or an excerpt, or one part of an episode whose complete album is on the store too |
| `unspecified` | None of the above (include instead) |

If no value fits, include the album.

**Output:** one decision for EVERY album in the batch: `provider` and `id`
as the batch gives them, `include`, `exclude_reason` for an exclusion,
`confidence`, and `notes`.

### Worked examples

Given `episode_pattern: ^Folge (\d+):` for series "Die drei ???":

**A regular episode** (include):
```
Title: "Folge 1: Der Super-Papagei"
Reasoning:
  1. "Folge 1:" matches the pattern
  2. 26 tracks, ~50 min: one story with scenes
  3. No exclusion reason applies
→ include=true, confidence=high
```

**A box of episodes that exist alone** (exclude):
```
Title: "Folge 1-10: Jubiläumsbox"
<episode_range first="1" last="10" also_released_alone="1, 2, 3, 4, 5, 6, 7, 8, 9, 10"/>
Reasoning:
  1. The title names a run of episodes, not one
  2. All ten are released on their own on this page, so the box re-sells
     them (compilation_as_episode)
→ include=false, exclude_reason=compilation, confidence=high
```

**A run that is the episode release** (include):
```
Title: "Folgen 6-10: Das Baby im Schafspelz"
<episode_range first="6" last="10" also_released_alone="none"/>
Reasoning:
  1. The title names a run of episodes
  2. None of 6 to 10 exists on its own on this page, so this album is
     their only release, not a repackaging
  3. Code numbers it with its first episode
→ include=true, confidence=high
```

**No pattern match, but an episode** (include):
```
Title: "Der Super-Papagei" (3 tracks, 45 min, 1979)
Reasoning:
  1. No match for ^Folge (\d+):
  2. No exclusion reason applies: not a box, not a single, not another
     type of content
  3. 3 tracks of 45 min fit an early release, one track per act
→ include=true, confidence=medium
  notes: "No pattern match, track shape and length fit an episode from before the numbering"
```

**The same episode on both stores** (not a duplicate):
```
spotify: "Folge 1: Der Super-Papagei" (ep 1, 26 tracks)
apple_music: "Die drei ??? Folge 1: Der Super-Papagei" (ep 1, 3 tracks)
Reasoning:
  1. Same episode on two stores: a cross_provider_pair, NOT a duplicate
  2. The track counts differ by packaging
→ Include BOTH with their respective provider tags. confidence=high for both.
```

**A reading in a Hörspiel series** (exclude):
```
Title: "Die drei ??? - gelesen von Rufus Beck (ungekürzt)"
Reasoning:
  1. "gelesen von" and "ungekürzt": one narrator reads a book
  2. A reading is another type of content than this series
→ include=false, exclude_reason=wrong_content_type, confidence=high
  notes: "Audiobook reading, not a Hörspiel episode"
```
