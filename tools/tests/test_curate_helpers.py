"""Tests for curate.py helpers — the small functions that gate
correctness of an --all run without exercising the LLM or providers.

_lock_series_id is the safety net that prevents the umlaut-
transliteration bug from corrupting filenames. The exception
formatter is the diagnostic that decides whether you can tell what
went wrong from the log.
"""

from __future__ import annotations

import pytest

from lauschi_catalog.commands.curate import (
    AlbumDecision,
    CuratedSeries,
    _build_metadata_agent,
    _compute_pattern_coverage,
    _lock_series_id,
    _lookup_catalog_entry,
    _resolve_content_type,
    _stratified_sample,
)


def _series(sid: str = "any") -> CuratedSeries:
    """Build a minimal CuratedSeries; the helper only touches .id."""
    return CuratedSeries(
        id=sid,
        title="Title",
        episode_pattern=r"^Folge (\d+):",
        albums=[],
        provider_artist_ids={},
    )


# ── _lock_series_id ───────────────────────────────────────────────────────


def test_lock_overrides_when_canonical_differs():
    """The motivating bug: model produced 'benjamin_bluechen' for
    series.yaml entry 'benjamin_bluemchen'. Override silently fails
    catalog round-tripping; we want a loud override instead."""
    s = _series("benjamin_bluechen")
    _lock_series_id(s, "benjamin_bluemchen")
    assert s.id == "benjamin_bluemchen"


def test_lock_is_noop_when_canonical_matches():
    s = _series("die_drei_fragezeichen")
    _lock_series_id(s, "die_drei_fragezeichen")
    assert s.id == "die_drei_fragezeichen"


def test_lock_noop_when_canonical_is_none():
    """Single-series curate (no --all) has no canonical id; trust
    the model's choice."""
    s = _series("brand_new_series")
    _lock_series_id(s, None)
    assert s.id == "brand_new_series"


def test_lock_returns_same_instance_for_chaining():
    """Caller pattern: _lock_series_id(series, sid).save_curation() etc.
    The function mutates in place and returns the same object."""
    s = _series("a")
    result = _lock_series_id(s, "b")
    assert result is s


# ── exception formatter (covered indirectly via _curate_one) ──────────────


@pytest.mark.parametrize("exc,expected_substring", [
    (ValueError("bad input"), "ValueError: bad input"),
    (RuntimeError(""), "RuntimeError"),
    (Exception(""), "Exception"),
    (ConnectionError("refused"), "ConnectionError: refused"),
])
def test_exception_format_falls_back_to_type_when_str_empty(exc, expected_substring):
    """The format used inside _curate_one's except. Pinning here so a
    refactor doesn't regress the empty-str fallback."""
    msg = f"{type(exc).__name__}: {exc}" if str(exc) else type(exc).__name__
    assert expected_substring in msg


# ── _resolve_content_type ─────────────────────────────────────────────────


def test_yaml_explicit_music_wins_over_pattern():
    """Even if a leftover episode_pattern exists, an explicit
    content_type='music' in series.yaml is canonical."""
    assert _resolve_content_type(
        entry_content_type="music",
        entry_has_pattern=True,
        existing_content_type=None,
    ) == "music"


def test_yaml_explicit_hoerspiel_wins_over_existing_music():
    """The compounding-misclassification fix: a series previously
    curated as music in its JSON file gets correctly recognized as
    hoerspiel when series.yaml says so. Without this, every
    --force re-curate would keep using the music prompt."""
    assert _resolve_content_type(
        entry_content_type="hoerspiel",
        entry_has_pattern=False,
        existing_content_type="music",
    ) == "hoerspiel"


def test_pattern_implies_hoerspiel_when_yaml_silent():
    """No explicit content_type, but episode_pattern is set → it's a
    Hörspiel by definition (patterns are only meaningful for
    episode-numbered content)."""
    assert _resolve_content_type(
        entry_content_type=None,
        entry_has_pattern=True,
        existing_content_type=None,
    ) == "hoerspiel"


def test_pattern_implies_hoerspiel_overrides_existing_music():
    """If yaml has episode_pattern but no explicit content_type, the
    pattern wins over a stale content_type='music' in the existing
    curation. Same root concern: don't compound misclassifications."""
    assert _resolve_content_type(
        entry_content_type=None,
        entry_has_pattern=True,
        existing_content_type="music",
    ) == "hoerspiel"


def test_existing_music_used_when_yaml_has_neither():
    """Legacy escape hatch: if yaml is silent on content_type AND has
    no episode_pattern, fall back to the existing curation. Lets
    pre-migration entries continue to work."""
    assert _resolve_content_type(
        entry_content_type=None,
        entry_has_pattern=False,
        existing_content_type="music",
    ) == "music"


def test_default_to_hoerspiel_when_nothing_signals():
    """Brand-new entry with no pattern, no existing curation, no
    explicit content_type. Default to hoerspiel (most of the catalog)."""
    assert _resolve_content_type(
        entry_content_type=None,
        entry_has_pattern=False,
        existing_content_type=None,
    ) == "hoerspiel"


def test_audiobook_content_type_supported():
    """audiobook is a recognized content_type."""
    assert _resolve_content_type(
        entry_content_type="audiobook",
        entry_has_pattern=False,
        existing_content_type=None,
    ) == "audiobook"
    assert _resolve_content_type(
        entry_content_type="audiobook",
        entry_has_pattern=True,
        existing_content_type=None,
    ) == "audiobook"


def test_legacy_content_type_from_existing_curation():
    """An existing curation with content_type='audiobook' is picked up."""
    assert _resolve_content_type(
        entry_content_type=None,
        entry_has_pattern=False,
        existing_content_type="audiobook",
    ) == "audiobook"


# ── _stratified_sample ────────────────────────────────────────────────────


def test_stratified_returns_all_when_below_n():
    items = list(range(10))
    assert _stratified_sample(items, 40) == items


def test_stratified_picks_first_and_last_for_full_coverage():
    """The whole point: if Spotify returns 305 albums new-first and
    we sample first-N, era-mixed series like ddF lose visibility on
    older naming conventions. A stratified sample must hit both ends."""
    items = list(range(305))
    sample = _stratified_sample(items, 40)
    assert len(sample) == 40
    # First item is included; last item is near the end.
    assert sample[0] == 0
    assert sample[-1] >= 290  # roughly last decile


def test_stratified_spreads_evenly():
    """Even distribution: gaps between picks should be roughly equal."""
    items = list(range(200))
    sample = _stratified_sample(items, 40)
    diffs = [b - a for a, b in zip(sample, sample[1:])]
    # Step is 200/40 = 5, so all diffs should be ~5
    assert max(diffs) - min(diffs) <= 1


def test_stratified_handles_exactly_n():
    items = list(range(40))
    assert _stratified_sample(items, 40) == items


def test_stratified_preserves_original_order():
    """Sampling shouldn't shuffle — caller may rely on order
    (e.g., 'first item is the most recent release')."""
    items = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
    sample = _stratified_sample(items, 5)
    assert sample == sorted(sample, key=items.index)


# ── _build_metadata_agent: music vs Hörspiel split ────────────────────────


def _agent_tool_names(agent) -> list[str]:
    """Pull tool names off a pydantic-ai Agent in a version-tolerant way."""
    return list(agent.toolsets[0].tools.keys())


def test_metadata_agent_for_hoerspiel_has_coverage_tool():
    """Hörspiel agents need check_pattern_coverage to verify their
    proposed episode_pattern against the full discography. Without
    this, the previous run silently dropped 250+ ddF episode numbers."""
    from pydantic_ai.models.test import TestModel

    agent = _build_metadata_agent(TestModel())
    assert _agent_tool_names(agent) == ["check_pattern_coverage"]


def test_metadata_agent_for_music_has_no_tools():
    """Music agents must NOT see check_pattern_coverage. The
    'you MUST call check_pattern_coverage' instruction in the
    Hörspiel prompt would otherwise either be ignored (silent
    instruction violation) or cause the agent to invent a bogus
    pattern to satisfy the instruction. The music prompt also
    explicitly tells the agent there are no tools available."""
    from pydantic_ai.models.test import TestModel

    agent = _build_metadata_agent(TestModel(), content_type="music")
    assert _agent_tool_names(agent) == []


def test_metadata_music_prompt_tells_agent_no_pattern_no_tools():
    """Pin the prompt content so a future refactor can't silently
    re-introduce the music-pattern bug."""
    from lauschi_catalog.prompts import load_curate_skill

    p = load_curate_skill(phase="metadata", content_type="music")
    assert "music" in p.lower()  # not Hörspiel
    assert "None" in p  # episode_pattern guidance
    assert "no tools" in p.lower() or "Do NOT call" in p


# ── _lookup_catalog_entry ─────────────────────────────────────────────────


def test_lookup_resolves_by_id(monkeypatch):
    """Single-series CLI usage: 'curate -- detlev_joecker' must
    resolve to the catalog entry so yaml fields (content_type,
    artist_ids, title) get used canonically."""
    entry = _lookup_catalog_entry("detlev_joecker")
    assert entry is not None
    assert entry.id == "detlev_joecker"
    assert entry.content_type == "music"


def test_lookup_resolves_by_title():
    """Users often type the proper title rather than the id slug."""
    entry = _lookup_catalog_entry("Detlev Jöcker")
    assert entry is not None
    assert entry.id == "detlev_joecker"


def test_lookup_returns_none_for_unknown():
    """Brand-new series not in the catalog → caller falls back to
    the no-yaml path."""
    assert _lookup_catalog_entry("definitely_not_a_real_series_id") is None


def test_lookup_id_match_takes_precedence_over_title_match(monkeypatch):
    """If a query matches both an id and a different entry's title
    (rare but possible), the id match wins. Pin the resolution
    order so a future loader rearrangement can't flip it."""
    from lauschi_catalog.commands import curate as curate_mod
    from lauschi_catalog.catalog.models import CatalogEntry

    fake_entries = [
        CatalogEntry(
            id="another_series", title="exact_id_string",
        ),
        CatalogEntry(
            id="exact_id_string", title="Another Title",
        ),
    ]
    monkeypatch.setattr(
        curate_mod, "_lookup_catalog_entry",
        # Avoid load_catalog by re-implementing via the same logic
        lambda q: next(
            (e for e in fake_entries if e.id == q),
            next((e for e in fake_entries if e.title == q), None),
        ),
    )
    entry = curate_mod._lookup_catalog_entry("exact_id_string")
    assert entry.id == "exact_id_string"
    assert entry.title == "Another Title"


# ── _compute_pattern_coverage: failure-mode reporting ─────────────────────
#
# A SimsalaGrimm curate run wedged in a tool-call loop because the
# old tool reported BOTH "regex didn't match" and "regex matched but
# capture wasn't a digit" as a single 0% coverage. The agent tried
# `(.*)` (which matches every title), saw 0%, and concluded its
# regex was broken — when actually its capture group was returning
# the entire title and `int()` rejected it. These tests pin the
# distinction so a refactor can't collapse the buckets again.


def test_pattern_coverage_separates_no_match_from_non_numeric():
    """The motivating SimsalaGrimm bug. Episodes are named
    ('Aladin und die Wunderlampe (...)'), never numbered. With
    ``(.*)`` the regex matches every title but the capture is the
    whole title — distinct from 'regex didn't match'."""
    titles = [
        "Aladin und die Wunderlampe (Das Original-Hörspiel zur TV Serie)",
        "Aschenputtel (Das Original-Hörspiel zur TV Serie)",
    ]
    result = _compute_pattern_coverage(titles, "(.*)")
    assert result["matched"] == 0
    assert result["coverage"] == 0.0
    # All titles fell into non_numeric, NOT no_match. This is the
    # signal the agent needs to bail to episode_pattern=None.
    assert len(result["non_numeric_capture_samples"]) == 2
    assert result["unmatched_regex_samples"] == []
    captured = result["non_numeric_capture_samples"][0]["captured"]
    assert "Aladin" in captured  # captured the whole title


def test_pattern_coverage_buckets_no_match_correctly():
    """Pattern that never matches (different naming convention)
    must report no_match, not non_numeric. This is what the agent
    sees for the 'add another regex alternative' fix path."""
    titles = ["Episode A", "Episode B", "Episode C"]
    result = _compute_pattern_coverage(titles, r"^Folge (\d+):")
    assert result["matched"] == 0
    assert len(result["unmatched_regex_samples"]) == 3
    assert result["non_numeric_capture_samples"] == []


def test_pattern_coverage_counts_numeric_captures():
    """Sanity: a working pattern still works."""
    titles = [
        "Folge 1: Foo",
        "Folge 2: Bar",
        "Special edition",  # legitimate non-episode
    ]
    result = _compute_pattern_coverage(titles, r"^Folge (\d+):")
    assert result["matched"] == 2
    assert result["total"] == 3
    assert result["coverage"] == round(2 / 3, 3)
    assert len(result["unmatched_regex_samples"]) == 1


def test_pattern_coverage_alternation_falls_through_non_numeric():
    """List of patterns: if one captures non-numeric but a later
    one captures a digit on the same title, the title counts as
    matched. Pins the inner-loop early-exit semantics."""
    titles = ["Folge 5: Boom"]
    # First pattern matches every word with `(.+)` (non-numeric);
    # second pattern captures the digit. The title should still
    # count as matched.
    result = _compute_pattern_coverage(
        titles, [r"^(.+):", r"^Folge (\d+):"],
    )
    assert result["matched"] == 1
    assert result["non_numeric_capture_samples"] == []


def test_pattern_coverage_rejects_empty_pattern():
    assert "error" in _compute_pattern_coverage(["x"], [])


def test_pattern_coverage_rejects_invalid_regex():
    result = _compute_pattern_coverage(["x"], "(unclosed")
    assert "error" in result
    assert "invalid regex" in result["error"]


def test_pattern_coverage_rejects_zero_capture_groups():
    result = _compute_pattern_coverage(["x"], r"^Folge \d+:")
    assert "error" in result
    assert "capture group" in result["error"]


# ── episode_pattern prompt allows the None escape hatch ───────────────────


def test_metadata_hoerspiel_prompt_allows_none_for_named_episodes():
    """The metadata prompt must explicitly tell the agent to use
    episode_pattern=None for series with named/themed episodes
    (like SimsalaGrimm fairy tales). Without this, the agent
    interprets 'MUST call check_pattern_coverage' as unconditional
    and burns its timeout retrying impossible patterns."""
    from lauschi_catalog.prompts import load_curate_skill

    p = load_curate_skill(phase="metadata", content_type="hoerspiel")
    # Hint to bail out
    assert "None" in p
    # Explicit named/themed escape hatch
    assert "named" in p.lower() or "themed" in p.lower()
    # Numeric-capture contract spelled out
    assert "digit" in p.lower() or "int(" in p


# ── Metadata prompt advertises richer per-album fields ─────────────────────


def test_metadata_prompt_mentions_release_date_signal():
    """The sample assembly hands the agent title | tracks |
    release_date. The prompt must tell the agent these fields exist,
    otherwise the model treats the trailing date as noise. Pin the
    contract so a future prompt rewrite can't silently drop it."""
    from lauschi_catalog.prompts import load_curate_skill

    p = load_curate_skill(phase="metadata", content_type="hoerspiel")
    assert "release_date" in p
    assert "total_tracks" in p


# ── Display-order fallback when episode_num is null ───────────────────────


def _decision(
    aid: str,
    title: str,
    *,
    provider: str = "spotify",
    include: bool = True,
    episode_num: int | None = None,
    release_date: str | None = None,
) -> AlbumDecision:
    return AlbumDecision(
        album_id=aid, provider=provider, include=include,
        episode_num=episode_num, title=title, release_date=release_date,
    )


def _curated(albums: list[AlbumDecision]) -> CuratedSeries:
    return CuratedSeries(
        id="test", title="Test", episode_pattern=None,
        albums=albums, provider_artist_ids={},
    )


def test_included_sorts_numbered_episodes_by_number():
    """Numbered episodes come back ordered by episode_num — same
    as before. Pin so the release_date fallback doesn't
    accidentally reorder numbered series."""
    series = _curated([
        _decision("c", "Folge 3", episode_num=3, release_date="2020-01-01"),
        _decision("a", "Folge 1", episode_num=1, release_date="2022-12-01"),
        _decision("b", "Folge 2", episode_num=2, release_date="2021-06-01"),
    ])
    order = [a.album_id for a in series.included()]
    assert order == ["a", "b", "c"]


def test_included_sorts_unnumbered_by_release_date():
    """When episode_num is null (named-episode series), albums
    display in chronological release order — not alphabetical.
    This is the SimsalaGrimm fix: fairy tales sorted by when
    the audio release dropped, so users see new releases first
    in a chronological view rather than alphabetical chaos."""
    series = _curated([
        _decision("c", "Allerleirauh", release_date="2022-05-01"),
        _decision("a", "Bremer Stadtmusikanten", release_date="2020-01-15"),
        _decision("b", "Aschenputtel", release_date="2021-03-20"),
    ])
    order = [a.album_id for a in series.included()]
    assert order == ["a", "b", "c"]


def test_included_mixes_numbered_and_unnumbered_correctly():
    """Numbered episodes come first (by number), unnumbered
    follow (by release_date). Mixed series shouldn't interleave."""
    series = _curated([
        _decision("u2", "Special B", release_date="2022-01-01"),
        _decision("n1", "Folge 1", episode_num=1, release_date="2024-01-01"),
        _decision("u1", "Special A", release_date="2021-01-01"),
        _decision("n2", "Folge 2", episode_num=2, release_date="2023-01-01"),
    ])
    order = [a.album_id for a in series.included()]
    assert order == ["n1", "n2", "u1", "u2"]


def test_included_missing_release_date_sorts_with_empty_string_key():
    """Missing release_date falls back to "" via `or ""`, so a
    no-date album sorts BEFORE dated ones lexicographically.
    This is a corner case — both Spotify and Apple Music always
    return a release_date in practice. Pin so re-runs are stable
    if a future provider ever omits it."""
    series = _curated([
        _decision("a", "Mit Datum", release_date="2020-01-15"),
        _decision("b", "Ohne Datum"),
    ])
    order = [a.album_id for a in series.included()]
    assert order == ["b", "a"]


# ── AlbumDecision schema includes release_date ─────────────────────────────


def test_album_decision_release_date_defaults_none():
    """The agent doesn't set release_date — it's hydrated post-hoc
    from the discovery dict. Default None means 'not yet hydrated'
    or 'provider didn't supply it'."""
    d = AlbumDecision(
        album_id="x", provider="spotify", include=True,
        episode_num=None, title="t",
    )
    assert d.release_date is None


def test_confidence_high_without_notes_ok():
    d = AlbumDecision(
        album_id="x", provider="spotify", include=True,
        episode_num=1, title="t", confidence="high",
    )
    assert d.confidence == "high"
    assert d.notes is None


def test_confidence_medium_requires_notes():
    with pytest.raises(ValueError, match="notes"):
        AlbumDecision(
            album_id="x", provider="spotify", include=True,
            episode_num=1, title="t", confidence="medium",
        )


def test_confidence_low_requires_notes():
    with pytest.raises(ValueError, match="notes"):
        AlbumDecision(
            album_id="x", provider="spotify", include=True,
            episode_num=1, title="t", confidence="low",
        )


def test_confidence_medium_with_notes_ok():
    d = AlbumDecision(
        album_id="x", provider="spotify", include=True,
        episode_num=1, title="t", confidence="medium",
        notes="cross-provider asymmetry on this episode",
    )
    assert d.confidence == "medium"
    assert d.notes is not None


def test_legacy_json_without_confidence_loads_as_high():
    """Backward compat: old curation JSONs lack confidence field."""
    import json
    raw = {
        "album_id": "x", "provider": "spotify", "include": True,
        "episode_num": 1, "title": "t",
    }
    d = AlbumDecision.model_validate(raw)
    assert d.confidence == "high"


def test_excluded_without_reason_rejected():
    with pytest.raises(ValueError, match="exclude_reason"):
        AlbumDecision(
            album_id="x", provider="spotify", include=False,
            episode_num=None, title="t",
        )


def test_excluded_with_reason_ok():
    d = AlbumDecision(
        album_id="x", provider="spotify", include=False,
        episode_num=None, title="t", exclude_reason="music_single",
    )
    assert not d.include
    assert d.exclude_reason == "music_single"


# ── album_details tools return release_date and artists ────────────────────


def test_curate_batch_flow_album_details_returns_release_date_and_artists():
    src = open(
        "src/lauschi_catalog/commands/curate.py", encoding="utf-8",
    ).read()
    block = src.split("def _build_batch_agent")[1].split(
        "# ── Shared helpers",
    )[0]
    assert '"release_date": album.release_date' in block
    assert '"artists": album.artists' in block


# ── propose_pattern_update guards against non-numeric captures ────────────
#
# The SimsalaGrimm pipeline run committed
# `^(.+?) \(Das Original-Hörspiel zur TV Serie\)$` — a valid regex
# whose group 1 captures the fairy tale name (a string), not a digit.
# The check `c.groups < 1` passed it through, but the captured value
# could never int(), so downstream re-extraction set every
# episode_num to None. These tests pin the new defensive check:
# propose_pattern_update calls _compute_pattern_coverage and rejects
# patterns whose group 1 isn't numeric on any title.


def test_propose_pattern_update_source_calls_coverage_check():
    """Pin that the batch agent's propose_pattern_update calls the
    coverage check before accepting a pattern. Source-level pin
    because calling the closure-bound tool requires a full agent
    instance with a model."""
    src = open(
        "src/lauschi_catalog/commands/curate.py", encoding="utf-8",
    ).read()
    # Locate the batch agent's propose_pattern_update
    idx = src.find("def propose_pattern_update")
    assert idx >= 0, "propose_pattern_update not found"
    # The function body must reference the coverage helper — that's
    # how the non-numeric reject path gets invoked.
    block = src[idx:idx + 3000]
    assert "_compute_pattern_coverage" in block, (
        "propose_pattern_update must run candidate patterns through "
        "_compute_pattern_coverage to reject non-numeric captures"
    )
    # And there must be a path that returns an error string when
    # the matched count is 0 — without that, the helper output is
    # ignored and we're back to the SimsalaGrimm bug.
    assert "matched\"] == 0" in block or "matched'] == 0" in block, (
        "propose_pattern_update must reject when zero titles yield "
        "a numeric capture"
    )


def test_propose_pattern_update_carries_titles_via_batch_deps():
    """BatchDeps must carry the discovery-phase titles so the check
    has data to test against. _run_large must populate the field
    on the shared_deps it hands to every batch."""
    src = open(
        "src/lauschi_catalog/commands/curate.py", encoding="utf-8",
    ).read()
    # The dataclass declares the field
    assert "titles: list[str] = field(default_factory=list)" in src, (
        "BatchDeps must declare a titles field for "
        "propose_pattern_update to validate against"
    )
    # _run_large populates it
    assert "titles=all_titles" in src, (
        "_run_large must pass all_titles into BatchDeps so the batch "
        "agent's propose_pattern_update can verify proposed patterns"
    )


def test_pattern_update_docstring_warns_about_numeric_capture():
    """Pin the user-facing contract in the tool's docstring — the
    agent reads this when deciding how to construct a pattern."""
    src = open(
        "src/lauschi_catalog/commands/curate.py", encoding="utf-8",
    ).read()
    idx = src.find("def propose_pattern_update")
    block = src[idx:idx + 2000]
    # Numeric requirement spelled out
    assert "digit" in block.lower(), (
        "propose_pattern_update docstring must warn that capture "
        "group 1 has to yield a digit"
    )


# ── Review's propose_pattern_update has the same numeric+coverage guard ───
#
# Same contract as the batch agent's tool (curate.py): patterns whose
# captures aren't int-parseable OR which match too few titles get
# rejected at the tool boundary. Without these, the review agent
# happily accepted '(\d+)' on alles_steht_kopf — a 4-album series
# where the pattern matched only 2 albums (the "Inside Out 2" sequels)
# and would silently break on any future album with a year in title.

# ── Field-level schema descriptions for episode_pattern ───────────────────
#
# Without Field(description=..., examples=[...]) the agent only sees a
# bare `anyOf: [str, array, null]` and has no schema-level hint that
# None is a first-class choice. Pydantic-ai ships these annotations to
# the model in the JSON schema, so we pin both: the description must
# mention None explicitly AND include the no-pattern guidance, and the
# examples list must include None alongside real patterns to make it
# a concrete choice the schema designer expected.


def test_series_metadata_episode_pattern_field_describes_none_choice():
    """Pin the schema annotation that ships to the model. Without this
    the agent sees an unannotated str|list|null union and tends to
    fill in a catch-all pattern (alles_steht_kopf '(\\\\d+)' was the
    motivating case)."""
    from lauschi_catalog.commands.curate import SeriesMetadata

    schema = SeriesMetadata.model_json_schema()
    pat = schema["properties"]["episode_pattern"]
    desc = pat.get("description", "")
    # Must explicitly mention None as a valid choice and warn against
    # cosmetic fills.
    assert "None" in desc
    assert "release_date" in desc, (
        "description should tell the agent there's a downstream "
        "fallback (release_date sort) so it doesn't feel pressured "
        "to invent a pattern"
    )
    # Must include examples featuring None as a concrete first-class
    # value, not just real patterns.
    examples = pat.get("examples", [])
    assert None in examples, (
        "examples must include None to signal it's expected, not "
        "just a fallback"
    )


def test_curated_series_episode_pattern_field_describes_none_choice():
    """Same description on CuratedSeries (the small-flow output) so
    the single-agent path gets the same hint."""
    from lauschi_catalog.commands.curate import CuratedSeries

    schema = CuratedSeries.model_json_schema()
    pat = schema["properties"]["episode_pattern"]
    assert "None" in pat.get("description", "")
    assert None in pat.get("examples", [])


def test_batch_prompt_distinguishes_structure_from_numbering():
    """The batch prompt's pattern-update section was nudging the
    agent to call propose_pattern_update whenever titles 'looked
    structured', even without digit episode numbers. SimsalaGrimm
    titles have a consistent (Das Original-Hörspiel zur TV Serie)
    suffix — structure but no number — and the agent still
    proposed a story-name-capturing pattern. Pin that the prompt
    now explicitly tells the agent: structure isn't numbering."""
    from lauschi_catalog.prompts import load_curate_skill

    p = load_curate_skill(phase="batch", content_type="hoerspiel")
    # Must specifically tell the agent NOT to propose for named
    # episodes with structured suffixes — that was the SimsalaGrimm
    # failure mode. Looking for the conceptual distinction.
    assert "structure" in p.lower() or "structured" in p.lower(), (
        "batch prompt must mention 'structure' to "
        "distinguish from 'numbering'"
    )
    # And explicitly point at release_date as the fallback for
    # unnumbered series, so the agent knows there IS a downstream
    # plan and doesn't feel pressured to invent a pattern.
    assert "release_date" in p, (
        "batch prompt must point at release_date as the "
        "fallback sort key for unnumbered series, otherwise the "
        "agent may invent a non-numeric pattern just to give the "
        "framework something to extract from"
    )


# ── dropped-album detection ───────────────────────────────────────────────


def test_restore_dropped_albums_adds_missing():
    """If the agent omits an album from its output, the validation
    step should add it back as 'not_decided' so it doesn't vanish."""
    from lauschi_catalog.commands.curate import (
        AlbumDecision, _restore_dropped_albums,
    )

    decisions = [
        AlbumDecision(
            album_id="a1", provider="spotify", include=True, title="T1",
            episode_num=None,
        ),
    ]
    index = {
        ("spotify", "a1"): {"name": "T1", "release_date": "2020-01-01"},
        ("apple_music", "b1"): {"name": "T2", "release_date": "2020-02-01"},
    }
    _restore_dropped_albums(decisions, index)

    assert len(decisions) == 2
    dropped = [d for d in decisions if d.album_id == "b1"]
    assert len(dropped) == 1
    assert dropped[0].include is False
    assert "not_decided" in (dropped[0].exclude_reason or "")
    assert dropped[0].title == "T2"
    assert dropped[0].release_date == "2020-02-01"


def test_restore_dropped_albums_no_op_when_all_present():
    """When every discovered album has a decision, the helper is a no-op."""
    from lauschi_catalog.commands.curate import (
        AlbumDecision, _restore_dropped_albums,
    )

    decisions = [
        AlbumDecision(
            album_id="a1", provider="spotify", include=True, title="T1",
            episode_num=None,
        ),
        AlbumDecision(
            album_id="b1", provider="apple_music", include=False, title="T2",
            episode_num=None, exclude_reason="compilation",
        ),
    ]
    index = {
        ("spotify", "a1"): {"name": "T1"},
        ("apple_music", "b1"): {"name": "T2"},
    }
    _restore_dropped_albums(decisions, index)
    assert len(decisions) == 2


# ── batch summary ───────────────────────────────────────────────────────


def test_batch_summary_includes_episode_runs_and_exclusion_reasons():
    from lauschi_catalog.commands.curate import AlbumDecision, _build_batch_summary

    decisions = [
        AlbumDecision(album_id="a1", provider="spotify", include=True, episode_num=1, title="T1"),
        AlbumDecision(album_id="a2", provider="spotify", include=True, episode_num=2, title="T2"),
        AlbumDecision(album_id="a3", provider="spotify", include=True, episode_num=3, title="T3"),
        AlbumDecision(album_id="a5", provider="spotify", include=True, episode_num=5, title="T5"),
        AlbumDecision(album_id="b1", provider="apple_music", include=False, episode_num=None, title="Box",
                      exclude_reason="compilation"),
        AlbumDecision(album_id="b2", provider="apple_music", include=False, episode_num=None, title="Best Of",
                      exclude_reason="compilation"),
        AlbumDecision(album_id="b3", provider="apple_music", include=False, episode_num=None, title="Karaoke",
                      exclude_reason="karaoke"),
    ]
    summary = _build_batch_summary(decisions, r"^Folge (\d+):", batch_num=2)
    assert "1-3" in summary
    assert "5" in summary
    assert "Active pattern:" in summary
    assert "compilation (2)" in summary
    assert "karaoke (1)" in summary


def test_batch_summary_empty_when_no_prior_decisions():
    from lauschi_catalog.commands.curate import _build_batch_summary

    summary = _build_batch_summary([], None, batch_num=1)
    assert summary == ""


def test_batch_summary_compresses_non_consecutive_episodes():
    from lauschi_catalog.commands.curate import AlbumDecision, _build_batch_summary

    decisions = [
        AlbumDecision(album_id="a1", provider="spotify", include=True, episode_num=1, title="T1"),
        AlbumDecision(album_id="a3", provider="spotify", include=True, episode_num=3, title="T3"),
        AlbumDecision(album_id="a4", provider="spotify", include=True, episode_num=4, title="T4"),
        AlbumDecision(album_id="a10", provider="spotify", include=True, episode_num=10, title="T10"),
    ]
    summary = _build_batch_summary(decisions, None, batch_num=2)
    assert "1" in summary
    assert "3-4" in summary
    assert "10" in summary


def test_batch_summary_groups_included_episodes_by_provider():
    """Cross-provider duplicates must not be excluded because the agent
    conflates providers. The summary must show which episodes are
    already included on *each* provider, not a flat global list."""
    from lauschi_catalog.commands.curate import AlbumDecision, _build_batch_summary

    decisions = [
        # Spotify has episodes 1-3
        AlbumDecision(album_id="s1", provider="spotify", include=True, episode_num=1, title="T1"),
        AlbumDecision(album_id="s2", provider="spotify", include=True, episode_num=2, title="T2"),
        AlbumDecision(album_id="s3", provider="spotify", include=True, episode_num=3, title="T3"),
        # Apple Music has episode 2 (different provider, same episode = must keep)
        AlbumDecision(album_id="a1", provider="apple_music", include=False, episode_num=2, title="T2",
                      exclude_reason="already included"),
    ]
    summary = _build_batch_summary(decisions, None, batch_num=2)

    # Must show episodes grouped by provider, not a flat global list
    assert "(by provider):" in summary
    assert "spotify:" in summary
    assert "1-3" in summary
    # apple_music is NOT in the included section (agent wrongly excluded it)
    # but the summary must NOT claim episode 2 is already included globally
    lines = summary.splitlines()
    for line in lines:
        if "Prior included" in line and "provider" not in line:
            pytest.fail("Summary must not show a flat 'Prior included episodes' list")

    # Verify no line implies episode 2 is already included on apple_music
    for line in lines:
        if "apple_music:" in line and "2" in line:
            pytest.fail("apple_music should not show episode 2 as already included")
