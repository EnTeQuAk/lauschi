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

## Worked examples

**Clear era boundary** (propose):
```
Series: "Biene Maja"
Observation:
  Cluster A (1976-1982): 52 albums, titles like "01/Majas Geburt",
    label "Karussell", 1-3 tracks each
  Cluster B (2013-2020): 78 albums, titles like "Folge 1: Majas Geburt",
    label "Universum Film", 20-30 tracks each
Reasoning:
  1. 30+ year gap between 1982 and 2013
  2. Title convention shifted: "NNN/Title" → "Folge NNN: Title"
  3. Label changed: Karussell → Universum Film
  4. Both clusters have 50+ albums (well above the 5-album threshold)
  5. This is a CGI reboot of the original animated series
→ Propose era_boundary: label="klassik", range="1976-1982"
→ Propose era_boundary: label="cgi_reboot", range="2013-2020"
```

**Not an era boundary** (don't propose):
```
Series: "Die drei ???"
Observation:
  4 albums titled "Klassiker, Folge NNN: ..." (Apple Music, 2019)
  198 albums titled "Folge NNN: ..." (Spotify, 1979-2024)
Reasoning:
  1. Only 4 "Klassiker" albums vs 198 standard albums
  2. The "Klassiker" prefix is Apple Music's catalog re-labeling, not a
     naming convention shift by the publisher
  3. Below the 5-album threshold for a distinct cluster
  4. No label or content change, just provider catalog formatting
→ Not an era boundary. These are cross-provider formatting differences.
```

**Era with same-episode duplicates** (era_collision):
```
Series: "Benjamin Blümchen"
Observation:
  spotify album: "Folge 1: Benjamin Blümchen als Wetterelefant" (1977, ep 1)
  spotify album: "Folge 1: Benjamin als Wetterelefant" (2020, ep 1)
Reasoning:
  1. Same provider, same episode number, 43 years apart
  2. Slightly different title (modernized spelling)
  3. This is era_collision: re-recorded or remastered for the new era
  4. Include both, and record an era_boundary
→ Include both albums. Propose era_boundary if not already documented.
  The era boundary explains why episode 1 appears twice on the same provider.
```
