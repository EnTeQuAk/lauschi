## Phase: Metadata extraction

You receive:
- Series name
- Provider list with artist IDs
- What the catalog holds for the series, where it has an entry: its id, the
  series it was split off from, the other catalog entries on its artist
  pages, the titles it ships today, its episode_pattern
- Sample albums (title | total_tracks | release_date), drawn from the whole
  artist page

Your task: set up the series metadata. Do NOT classify individual albums.

On an artist page that several catalog entries share, the sample holds
their albums too, and often more of theirs than of this series. That is
expected. The metadata is for this series alone, and the titles it ships
today show which albums are its own.

**episode_pattern rules:**
- Regex with exactly 1 capture group per pattern. The captured group MUST be a
digit string: `int(group)` has to succeed.
- Use a list of regexes when naming conventions changed across eras (e.g.
["^(\\d{3})/", "^Folge (\\d+):"]). Tried in order, first match wins.
- A series may have distinct sub-formats with their own numbering (e.g. main
episodes "Folge N:" plus talk episodes "BFF Talk - Talk N:"). Include patterns
for all numbered sub-formats, not just the dominant one. Dropping a sub-format's
pattern causes those albums to be excluded as unmatched.
- If episodes use NAMED titles without numbering (fairy tales, themes), set
`episode_pattern=None`.

**Workflow (hoerspiel only):**

Where the prompt gives the catalog's episode_pattern, the pattern is
settled: the run numbers the albums with it. Leave `episode_pattern` empty
and skip the steps below.

Step 1: Infer candidate patterns from the series' own titles (the titles it
ships today, or the sample for a series that ships nothing yet). Look for
common formats like `^Folge (\d+):`, `^(\d{3})/`, `^Teil (\d+):`, etc.

Step 2: Call `check_pattern_coverage` immediately with your candidates.
The tool tests against the series' own titles: the albums it already
ships, or every title in the discography for a series that ships nothing
yet (not just the sample). On an artist page shared with other series,
those other series' albums are not part of the measure. Most series reach
>90% coverage on the first or second try. If coverage
is acceptable, commit the pattern and move on.

Step 3 (only if needed): Use `web_search` (max 10 queries) and
`fetch_page` (max 2 URLs) when:
- Coverage is ambiguous (60-80%) and you need to classify unmatched titles
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

**Output:** call `submit_metadata` with id, title, aliases, episode_pattern,
age_note and curator_notes. The call is your answer, and text you write
next to it is not read. Where the prompt gives the catalog id, return it as `id`
unchanged. For a series the catalog does not hold, write the id in
snake_case: lower-case letters, digits and underscores, as in
`die_drei_fragezeichen`.

Note: `provider_artist_ids` are discovered deterministically before this
phase and are not part of the model's output. They cannot be overridden
by the metadata model.
