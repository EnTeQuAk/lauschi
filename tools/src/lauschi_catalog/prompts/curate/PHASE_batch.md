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

**Output:** `BatchResult` — an `AlbumDecision` for EVERY album in the batch.
