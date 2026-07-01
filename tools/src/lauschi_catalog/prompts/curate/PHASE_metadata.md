## Phase: Metadata extraction

You receive:
- Series name
- Provider list with artist IDs
- Sample albums (title | total_tracks | release_date)

Your task: set up the series metadata. Do NOT classify individual albums.

**episode_pattern rules:**
- Regex with exactly 1 capture group per pattern. The captured group MUST be a
digit string — `int(group)` has to succeed.
- Use a list of regexes when naming conventions changed across eras (e.g.
["^(\\d{3})/", "^Folge (\\d+):"]). Tried in order, first match wins.
- A series may have distinct sub-formats with their own numbering (e.g. main
episodes "Folge N:" plus talk episodes "BFF Talk - Talk N:"). Include patterns
for all numbered sub-formats, not just the dominant one. Dropping a sub-format's
pattern causes those albums to be excluded as unmatched.
- If episodes use NAMED titles without numbering (fairy tales, themes), set
`episode_pattern=None`.

**Workflow (hoerspiel only):**

Step 1: Infer candidate patterns from the sample titles. Look for common
formats like `^Folge (\d+):`, `^(\d{3})/`, `^Teil (\d+):`, etc.

Step 2: Call `check_pattern_coverage` immediately with your candidates.
The tool tests against ALL titles in the discography, not just the sample.
Most series reach >90% coverage on the first or second try. If coverage
is acceptable, commit the pattern and move on.

Step 3 (only if needed): Use `web_search` (max 3 queries) and
`fetch_page` (max 2 URLs) when:
- Coverage is ambiguous (60-80%) and you need to classify unmatched titles
- You need to find missing artist IDs for a provider
- The series structure is genuinely unclear from titles alone
Don't search for every series; most are straightforward from the sample
titles + one pattern check.

Worked example:
  Proposed: ["Teil (\\d+)"] on titles like "01/Majas Geburt", "Folge 2: Der Ball"
  → Call check_pattern_coverage(["Teil (\\d+)"])
  → Returns coverage_pct: 0 (no matches on album titles)
  → Fix: switch to ["^(\\d+)/", "^Folge (\\d+):"] and re-test.
  → Returns coverage_pct: 72
  → Fix: add "^Klassiker, Folge (\\d+):" and re-test.
  → Returns coverage_pct: 70. Remaining unmatched are movie Hörspiele and
     singles: legitimate non-episodes. Commit the pattern.

For music and audiobook series, episode_pattern is always None and no pattern
tools are registered. Set up the metadata directly.

**Output:** `SeriesMetadata` (id, title, aliases, episode_pattern, age_note,
curator_notes, provider_artist_ids).
