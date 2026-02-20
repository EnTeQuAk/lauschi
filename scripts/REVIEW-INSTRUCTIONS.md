# Catalog Review Instructions

You are reviewing AI-curated Hörspiel series data for the lauschi app.
Work through the series one at a time, fixing obvious issues and flagging
anything unclear for human review.

## Tools available

```bash
# See all issues across all series
mise exec -- uv run scripts/catalog-report.py

# See issues for one series
mise exec -- uv run scripts/catalog-report.py -- SERIES_ID

# Show a series summary (included, excluded, gaps, duplicates)
mise exec -- uv run scripts/catalog-edit.py show SERIES_ID

# Search Spotify for an album (to find IDs for missing episodes)
mise exec -- uv run scripts/catalog-edit.py search "Fünf Freunde 008"

# List all albums for an artist, optionally filtered
mise exec -- uv run scripts/catalog-edit.py artist-albums ARTIST_ID
mise exec -- uv run scripts/catalog-edit.py artist-albums ARTIST_ID "Folge 8"

# Add a missing album (fetches from Spotify, extracts episode number)
mise exec -- uv run scripts/catalog-edit.py add SERIES_ID ALBUM_ID

# Remove an album
mise exec -- uv run scripts/catalog-edit.py remove SERIES_ID ALBUM_ID

# Toggle include/exclude
mise exec -- uv run scripts/catalog-edit.py toggle SERIES_ID ALBUM_ID

# Set episode number on an album
mise exec -- uv run scripts/catalog-edit.py set-episode SERIES_ID ALBUM_ID 42

# Mark series as reviewed (does NOT write to YAML — human does that)
mise exec -- uv run scripts/catalog-edit.py approve SERIES_ID
```

## What to fix (obvious)

1. **Duplicate episodes from sub-series**: Many series have JUNIOR, PROFIWISSEN,
   CLASSICS, "Neue Geschichten", etc. sharing episode numbers with the main series.
   These are separate products that happen to share numbering.
   **Fix**: Remove the sub-series entries. Keep only the main series episodes.
   The sub-series will be curated separately if needed.

   Examples:
   - Was ist Was: main + Junior share episode numbers → keep only main
   - Wieso? Weshalb? Warum?: main + JUNIOR + PROFIWISSEN + ERSTLESER + Vorlesegeschichten
     → keep only main series
   - Sternenschweif: main Hörspiel + audiobooks share Teil numbers → keep Hörspiele
   - Pumuckl: Classic + Christmas + Neue Geschichten → keep all three (different content)
   - Löwenzahn: Fritz Fuchs + CLASSICS → keep both (different content, different eras)

2. **Genuine gaps**: Search the artist's albums for the missing episode.
   If found, add it. If not on Spotify, note it.

3. **Clear duplicates**: Same episode, two versions. Keep the one that matches
   the series' main numbering pattern. Remove the other.

## What to flag (not obvious)

- Series where you're unsure which version to keep
- Series where the episode pattern seems wrong
- Anything that doesn't fit the categories above

Write flags as notes on the series:
```bash
# Edit the JSON directly to add a review note
```
Or just note it in your output and move on.

## What NOT to do

- Don't approve series — just fix issues and the human will approve via TUI
- Don't modify series.yaml directly
- Don't re-run the AI curation
- Don't spend time on series with 0 issues

## Priority order

Work through these first (most issues):
1. Wieso? Weshalb? Warum? (massive sub-series duplication)
2. Was ist Was (main + Junior duplication)
3. Sternenschweif (Hörspiel + audiobook duplication)
4. Die drei ??? (duplicates + gaps)
5. Pumuckl (3 eras sharing numbers)
6. Löwenzahn (Fritz Fuchs + CLASSICS)
7. Prinzessin Lillifee (TV + Gute-Nacht duplication)
8. Die Schule der magischen Tiere (main + ermittelt + Endlich Ferien)
9. Hanni und Nanni (classic + Neue Abenteuer)
10. Die wilden Hühner (+ Wilden Küken spinoff)
11. Fünf Freunde (gaps at 8, 10)
12. Remaining series with issues
