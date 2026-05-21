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

### Worked examples

Given `episode_pattern: ^Folge (\d+):` for series "Die drei ???":

**Clear include** (pattern matches, episode shape):
```
Title: "Folge 1: Der Super-Papagei"
→ episode_num=1, include=true, confidence=high
```

**Clear exclude** (compilation box set):
```
Title: "Folge 1-10: Jubiläumsbox"
→ include=false, exclude_reason=compilation, confidence=high
```

**No pattern match, but valid episode** (different naming era):
```
Title: "Der Super-Papagei" (3 tracks, 45 min, 1979)
→ episode_num=null, include=true, confidence=medium
  notes: "No pattern match; track shape and duration suggest real episode"
```

**Cross-provider, same episode number** (not a duplicate):
```
spotify: "Folge 1: Der Super-Papagei" (ep 1, 26 tracks)
apple_music: "Die drei ??? Folge 1: Der Super-Papagei" (ep 1, 3 tracks)
→ Include BOTH. Different providers, different catalog metadata.
```

**Audiobook reading in a Hörspiel series**:
```
Title: "Die drei ??? - gelesen von Rufus Beck (ungekürzt)"
→ include=false, exclude_reason=wrong_content_type, confidence=high
  notes: "Audiobook reading, not a Hörspiel episode"
```

**Ambiguous, can't name a failure pattern**:
```
Title: "Sonderfolge: Das Geheimnis der Geisterinsel"
→ episode_num=null, include=true, confidence=low
  notes: "No pattern match, unclear if special or regular episode"
```
