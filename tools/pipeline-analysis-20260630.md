# Pipeline Analysis: 2026-06-30 Full Re-curation

Log: `logs/catalog/pipeline-20260630-194228.log`
Model: kimi-k2.6 (curation), minimax-m2.7 (verification)
Mode: `--force` (re-curate everything from scratch)

## Summary

| Metric | Value |
|--------|-------|
| Series in catalog | 254 |
| Curated successfully | 50 |
| Crashed | 1 (Die Biene Maja, series 51) |
| Not reached (crash halted curate loop) | 203 |
| Carried forward (pre-seeded) | 30 |
| Freshly batched | 20 (409 new albums) |
| Total included | 6,735 |
| Total excluded | 1,344 |
| Reconcile flips (auto-fixed) | 161 |
| Reconcile flags (needs review) | 36 |
| Audit | Fully skipped (all 39 eligible were stale) |
| Applied to series.yaml | 18 series (79 new albums) |
| API retries (Cloudflare 524) | 13 across 4 series |

The curate step crashed on series 51 (Die Biene Maja) due to a malformed
`era_boundary` with `release_date_range: '2023'` instead of `'2023-'`.
Steps 2-6 (reconcile, audit, lint, apply, validate) continued over all
254 existing curations.

## Tool Call Distribution

| Tool | Count |
|------|-------|
| search_included_albums | 171 |
| web_search | 125 |
| check_pattern_coverage | 90 |
| fetch_page | 73 |
| get_album_details | 67 |
| propose_series_facts | 9 |
| lint_current_curation | 8 |
| propose_pattern_update | 0 |
| **Total** | **543** |

---

## Bug: Die Biene Maja Crash

`pydantic_core.ValidationError` in `load_existing_facts()` at
`curate_ops.py:1868`. An era_boundary had `release_date_range: '2023'`
instead of the required `'YYYY-YYYY'` or `'YYYY-'` format.

This terminated the curate-all loop. Series 52-254 were never
re-curated. The malformed fact was written by the AI in a prior run
and never validated on write.

**Root cause:** `propose_series_facts` accepts era_boundaries from the
model but doesn't validate `release_date_range` format before persisting.

**Fix:** Add format validation in `propose_series_facts` (or in the
Pydantic model's validator) so bad ranges are rejected at write time,
not on the next read. Also fix the 7 existing malformed facts:
- Die Biene Maja
- Die Feriendetektive
- In einem Land vor unserer Zeit
- Karlsson vom Dach
- Lauras Stern (4 bad ranges)
- Löwenzahn (3 bad ranges, used full date strings like `'2021-07-02 to 2024-01-19'`)
- Mia and Me: Buch

## Bug: Bibi Blocksberg Episode Number Collision

The metadata pattern `^Kampf um Kartoffelbrei \(Special\) - Teil (\d+):`
assigns episode numbers 1-4 to the Kartoffelbrei specials. These collide
with the main series Folge 1-4. Lint flags duplicates on both providers.

**Fix:** Either remove the Kartoffelbrei pattern from episode_pattern
(leave them unnumbered) or declare a `sub_series` fact with its own
numbering namespace so lint knows to exclude the collision.

---

## Finalize Phase Analysis

The `exclude_reason` fix from the prior session eliminated all
"excluded without reason" false positives. Zero occurrences in this run.
No series called lint more than once. The prompt optimization is working.

### Timing Distribution

| Bucket | Count | Series |
|--------|-------|--------|
| 0s (no work) | 8 | SpongeBob, Gregs Tagebuch, Kati & Azuro, Was Ist Was Junior, Monika Häuschen, Ritter Rost, Wendy, Sternenfohlen |
| < 1m | 9 | Lego Ninjago (13s), Madagascar (16s), Eiskönigin (27s), PAW Patrol (29s), Shrek (30s), Rabe Socke (34s), Peppa Pig (46s), Kung Fu Panda (47s), Fünf Freunde (49s) |
| 1-2m | 15 | H2O, Mia and Me, TKKG Junior, Die Punkies, Janosch, Hanni und Nanni, Miraculous, LEGO City, Wickie, Die drei ??? Kids, Dragons, Michael Ende, Die Playmos, Teufelskicker, Spirit |
| 2-3m | 7 | Wieso Weshalb Warum, Pumuckl, Die Olchis, Bibi Blocksberg, Pettersson, Kira Kolumna, Drachenzähmen, Die Fuchsbande |
| 3-5m | 3 | Was Ist Was (3m14s), Sternenschweif (3m44s), Asterix (4m54s) |
| 5m+ | 4 | Otfried Preußler (5m30s), Die Originale (6m49s), Hexe Lilli (6m50s), Cornelia Funke (12m07s) |

### Dominant Waste Pattern: Era Collision Hunting

When the finalize prompt says "era evidence found" but provides no
specific flagged albums, the agent goes searching for collisions that
don't exist. Three series are clear examples:

**Hexe Lilli (6m50s, 53 tool calls):** The agent spent 40
`search_included_albums` calls chasing cross-era duplicate episode
numbers. It correctly diagnosed the cause (three production eras) but
kept investigating details it can't act on. Finalize can't change
episode assignments or restructure eras.

**Die Originale (6m49s, 34 tool calls):** Only 2 unnumbered albums
(trivially handled). The agent then spent 30+ calls searching for era
collisions that don't exist, probing episodes 1, 2, 10, 60, 100 one
by one. Zero lint issues confirms there was nothing to find.

**Asterix (4m54s, 29 tool calls):** Same pattern. 2 unnumbered albums,
agent searched episodes 01-10 individually, then "Klassiker", "Neu",
"Original". Fetched 26 album details from each provider. Zero lint
issues.

**Fix:** The finalize user prompt should distinguish between "era
evidence exists and needs resolution" vs "eras are already documented,
just verify." When existing era_boundaries already cover all flagged
evidence, the prompt should say "Era boundaries already documented,
skip Step 2" instead of including era evidence lines that trigger
investigation.

### Series Over 8 Tool Calls

| Series | Calls | Issue |
|--------|-------|-------|
| Hexe Lilli | 53 | Era collision hunting (can't act on findings) |
| Die Originale | 34 | Era collision hunting (nothing to find) |
| Asterix | 29 | Era collision hunting (nothing to find) |
| Sternenschweif | 18 | 4x get_album_details for era analysis (borderline) |
| Feuerwehrmann Sam | 15 | Multiple unnumbered albums, legitimate |
| Was Ist Was | 14 | 52 unnumbered albums, legitimate complexity |
| Otfried Preußler | 14 | 10 get_album_details for era probing (heavy) |
| Bibi Blocksberg | 13 | Found real Kartoffelbrei numbering issue |
| Die Playmos | 13 | 3 web_search + fetch for episode list |
| Cornelia Funke | 9 | 4 sub-series to discover, legitimate |

---

## Metadata Phase Analysis

### Timing Distribution

| Bucket | Count |
|--------|-------|
| < 30s | 3 (Gregs Tagebuch 25s, TKKG Junior 20s, Sternenfohlen 30s) |
| 30s-1m | 9 |
| 1-2m | 20 |
| 2-3m | 10 |
| 3m+ | 8 |

### Dominant Waste Pattern: Web Research Before Pattern Check

23 out of 50 series (46%) did web research before their first
`check_pattern_coverage` call. In many cases the pattern check returned
>95% coverage on the first try, meaning all the web research was wasted.

| Metric | No web research | 3 web searches |
|--------|----------------|----------------|
| Average duration | ~42s | ~3m 06s |
| Series count | 16 | 14 |

Worst examples:
- **Asterix (4m05s):** 3 web searches, 2 fetches before pattern check. Coverage was 98%.
- **Die Originale (3m38s):** 3 web searches, 2 fetches before pattern check. Coverage was 98%.
- **Lego Ninjago (1m20s):** 3 web searches, 1 fetch before pattern check. Coverage was 95%.

**Fix:** The metadata prompt should instruct the agent to run
`check_pattern_coverage` first on candidate patterns inferred from
sample titles. Web research should only happen when coverage is
ambiguous or the agent needs to find artist IDs.

### Metadata Rejections

3 series had metadata rejected for low coverage:
- **Pettersson und Findus (3m31s):** 26% coverage, resubmitted with pattern=None
- **Janosch (4m):** 21% coverage, resubmitted with pattern=None
- **Die Eiskönigin (2m06s):** Agent wanted pattern=None but couldn't
  figure out how to pass null, burned 5 `check_pattern_coverage` calls
  with empty lists before hitting the tool limit escape hatch

### Pattern Coverage Warnings

15 series kept patterns despite below-80% coverage warnings. Most are
legitimate (unmatched titles are compilations, sub-series, or
non-episodes). Notable cases:

| Series | Coverage | Concern |
|--------|----------|---------|
| Cornelia Funke | 8% (6/71) | Author umbrella, pattern=None may be better |
| Pippi Langstrumpf | 17% (5/30) | Very low, should probably be None |
| Janosch | 21% | Rejected, became None |
| Pettersson und Findus | 26% | Rejected, became None |
| Die Olchis | 24% (26/108) | Mixed content, may need sub-series split |
| Wieso Weshalb Warum | 34% (125/363) | Three eras, different naming conventions |
| Kommissar Kugelblitz | 38% (37/98) | Mixed naming |
| Der Räuber Hotzenplotz | 40% (6/15) | Small catalog, borderline |

---

## Cross-Provider Issues

### Extreme Album Count Mismatches

| Series | Spotify | Apple Music | Notes |
|--------|---------|-------------|-------|
| PAW Patrol | 47 | 492 | Spotify artist page nearly empty |
| Benjamin Blümchen | 275 | 282 | 168 matched each side |
| Feuerwehrmann Sam | 177 | 200 | Apple Music has more |
| Wieso Weshalb Warum | 170 | 193 | Very low match rate (37%) |
| Stephen Janetzko | 308 | 328 | Zero match (music artist) |
| Simone Sommerland | 392 | 249 | Zero match (music artist) |

### Notable Cross-Provider Gaps

| Series | Issue |
|--------|-------|
| PAW Patrol | Episodes 1-445 on Apple Music, barely on Spotify |
| Nils Holgersson | Episodes 28-54 on Apple Music only |
| Polly Pocket | Episodes 27-52 on Spotify only |
| LEGO City Klassik | Multiple episodes on Spotify only |

### Title Counterpart Warnings (sub_series_bleed)

Albums included on one provider but excluded as `sub_series_bleed` on
the other. These need manual review via `mise run catalog-review`:

| Series | Albums Affected |
|--------|----------------|
| Kira Kolumna | 12 "Reportage" episodes |
| Pumuckl | 3 Weihnachten episodes |
| Bibi Blocksberg | 5 Kurzhörspiele/Bibi erzählt |
| Die Schlümpfe | 2 Kinofilm albums |
| Feuerwehrmann Sam | 1 film |
| Fünf Freunde | 1 Kinofilm |
| Conni | 1 Kinofilm |
| Hanni und Nanni | 1 Neue Abenteuer |
| Pettersson und Findus | 1 Kinofilm |

---

## Curation Quality

### Series with 0 Exclusions (review whether filtering is missing)

TKKG Junior (92), Was Ist Was (158), Kati & Azuro (83), Asterix (84),
H2O (104), Sternenschweif (156), Sternenfohlen (87), Die Eiskönigin
(12), Drachenzähmen (10), Kung Fu Panda (10).

Most small catalogs are fine. Was Ist Was (158 albums, 0 exclusions,
67% pattern coverage) and Sternenschweif (156 albums, 0 exclusions)
may warrant a second look.

### Massive Duplicate Episode Numbers (era collisions)

These series have eras with overlapping episode numbering. Eras are
documented but lint still flags the duplicates:

| Series | Scope |
|--------|-------|
| Jan Tenner | eras "klassik" + "der_neue_superheld", eps 1-40 |
| Wickie | eras "klassik" + "cgi_reboot", eps 1-12 |
| H2O | eras "original" + reboot, eps 1-26 |
| Pumuckl | eras "klassik" + "neue_geschichten", 18+ eps |
| Wieso Weshalb Warum | 3 eras, multiple overlaps |
| Die Schlümpfe | both providers, 14-19 eps |
| Hanni und Nanni | era "klassik", eps 1-12 |

These are expected and correct. Lint Rule 3 could learn to suppress
duplicates when a documented era_boundary explains the collision.

### Split Proposals (unaudited)

| Series | Proposed Splits |
|--------|----------------|
| Cornelia Funke | tintenwelt, wilde_huehner, gespensterjaeger, drachenreiter |
| Die Olchis | olchi_detektive |
| Sternenschweif | sternchen |

All flagged as "Unaudited sub_series" in lint. The audit step skipped
everything as stale, so none were reviewed or applied.

---

## API Reliability

4 series hit Cloudflare 524 timeouts to the Kimi K2.6 endpoint.
Exponential backoff (10s, 20s, 40s, 80s, 160s) succeeded in all cases.

| Series | Retries | Wall-clock Impact |
|--------|---------|-------------------|
| LEGO City | 6 | inflated to ~220m |
| Cornelia Funke | 3 | inflated to ~123m |
| Peppa Pig | 3 | inflated to ~89m |
| Otfried Preußler | 1 | inflated to ~48m |

---

## Actionable Items

### Bugs to Fix

1. **Validate era_boundary format on write.** The Die Biene Maja crash
   could have been prevented by validating `release_date_range` in
   `propose_series_facts` before persisting. Fix the 7 existing
   malformed facts too.

2. **Bibi Blocksberg Kartoffelbrei episode collision.** Remove the
   Kartoffelbrei pattern from episode_pattern or declare a sub_series
   fact with separate numbering.

### Prompt Improvements

3. **Metadata: pattern check first.** Add instruction to run
   `check_pattern_coverage` before web research. Only use web_search
   when coverage is ambiguous or artist IDs are needed. Expected
   savings: ~1-2 minutes per series for 23/50 affected series.

4. **Finalize: skip era step when already documented.** When existing
   era_boundaries already cover all flagged evidence, the user prompt
   should say "Era boundaries documented, skip Step 2" instead of
   including era evidence that triggers investigation. Expected
   savings: 3-5 minutes each for Die Originale, Asterix, Hexe Lilli.

5. **Finalize: suppress lint duplicates for documented eras.** Lint
   Rule 3 could learn to not flag duplicate episode numbers when a
   documented era_boundary explains the collision. This would reduce
   lint noise and prevent the agent from investigating expected
   duplicates.

### Data Fixes

6. **Fix 7 malformed series_facts.** Clean up the bad
   `release_date_range` values so the next pipeline run doesn't crash.

7. **Review 36 reconcile flags.** These are `sub_series_bleed` items
   that need human review via `mise run catalog-review`.

8. **Review 0-exclusion series.** Was Ist Was (158 albums) and
   Sternenschweif (156 albums) with zero exclusions may be missing
   quality filtering.

### Infrastructure

9. **Re-run curate for series 52-254.** The crash at series 51 means
   203 series were never re-curated. Either fix the malformed facts
   first and re-run, or skip Die Biene Maja and continue.

10. **Re-run audit after curate completes.** All 39 auditable series
    were skipped as stale. Audit needs to run after curate finishes
    to get the 4-eye verification pass.
