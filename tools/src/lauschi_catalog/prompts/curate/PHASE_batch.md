## Phase: Batch curation

You receive:
- Series title and episode_pattern
- Progress so far (included/excluded counts, prior episode numbers per provider)
- A batch of albums with full metadata (XML: title, release_date, type, tracks_count, duration_min, label, artist, sample tracks)

For each album: decide include or exclude.

**Apply the episode_pattern** to each title to extract episode_num:
- Match: set episode_num to the captured integer
- No match: set episode_num to null (still include if it's a valid episode)

**Exclude with a named reason** from the failure taxonomy. If you cannot name
the pattern, include with `episode_num=None`.

If the provided metadata for an album is insufficient to make a confident
decision (e.g. missing track listing, unclear album type), call
`get_album_details` to fetch the full data before deciding.

**Output:** `BatchResult` — an `AlbumDecision` for EVERY album in the batch.

### Inclusion bias

This is a children's audio app. A missed real episode means a child can't
listen to something they're looking for. An included borderline album is
harmless (it just sits in the catalog). When in doubt, **include**.

The only valid reason to exclude is a named failure-taxonomy pattern you can
point to. If you can't name the pattern, include with `episode_num=None`.

### Worked examples

Given `episode_pattern: ^Folge (\d+):` for series "Die drei ???":

**Clear include** (pattern matches, episode shape):
```
Title: "Folge 1: Der Super-Papagei"
Reasoning:
  1. Pattern check: "Folge 1:" matches ^Folge (\d+):, captures "1"
  2. Track shape: 26 tracks, ~50 min total, typical Hörspiel structure
  3. No failure-taxonomy pattern applies
→ episode_num=1, include=true, confidence=high
```

**Clear exclude** (compilation box set):
```
Title: "Folge 1-10: Jubiläumsbox"
Reasoning:
  1. Pattern check: "Folge 1-10:" does NOT match ^Folge (\d+): (range, not single digit)
  2. Title contains range pattern "1-10", matching compilation_as_episode
  3. Track count: 78 tracks confirms box set
  4. Named failure pattern: compilation
→ include=false, exclude_reason=compilation, confidence=high
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
→ episode_num=null, include=true, confidence=medium
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
→ episode_num=null, include=true, confidence=low
  notes: "Special episode ('Sonderfolge'), no episode number extractable"
```
