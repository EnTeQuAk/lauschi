# Era detection

Loaded when the discography spans 10+ years. Use for `hoerspiel` series with
long publication histories.

## Evidence checklist

1. **Release date clustering:** Group included albums by decade. If two or
   more distinct clusters exist with 5+ year gaps, that's an era signal.

2. **Title prefix shifts:** Look for systematic naming convention changes:
   - "NNN/Title" → "Folge NNN: Title" → "Klassiker, Folge NNN: Title"
   - Each prefix shift = potential era boundary

3. **Track count shifts:** Older releases may have different track counts
   (e.g., 1-3 tracks per episode on Apple Music for classics vs 20-40 for
   modern Spotify chapter splitting). Not definitive alone but supports era
   boundaries.

4. **Publisher/label changes:** If the label field changes systematically
   across decades, that's a publisher transition signal.

## When to propose era_boundary

- Two or more clusters with distinct title conventions AND 5+ year gap
- At least 5 albums in each cluster (avoid false positives from one-off
  re-releases)
- Label the boundary with a short descriptive label (e.g., "klassik",
  "cgi_reboot", "continuation")

## When NOT to propose era_boundary

- Single re-release with a different prefix but same era (e.g., one
  "Klassiker" edition among 20 standard editions) — that's a format variant,
  not an era
- Track count differences without title convention changes (Spotify vs Apple
  Music track counts differ by provider encoding, not era)
