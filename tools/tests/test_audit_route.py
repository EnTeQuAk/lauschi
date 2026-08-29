"""audit_route decides one-shot vs chunked from prompt size alone.

The boundary was located empirically: dry-run probes on 2026-08-29
showed the one-shot audit producing a verdict for every series up to
feuerwehrmann_sam (13.6k prompt tokens, 255 included) and lego_ninjago
(13.1k, 533 included), and never for bibi_blocksberg (14.8k). Included
album count does not predict the break; prompt size does.

The catalog pinning test reads the real curation files. They live in
git-lfs, so a checkout that only has pointers skips it rather than
failing on fake data.
"""

from __future__ import annotations

import asyncio
import json

import pytest

from lauschi_catalog.catalog import paths
from lauschi_catalog.catalog.audit_ops import (
    _CHUNK_FRAMING_TOKENS,
    _CHUNK_TARGET_TOKENS,
    AUDIT_ONE_SHOT_MAX_TOKENS,
    AuditFactUpdate,
    AuditOverride,
    AuditResult,
    Chunk,
    _album_line,
    audit_route,
    build_overview,
    build_prompt,
    merge_results,
    plan_chunks,
    prompt_size,
)
from lauschi_catalog.catalog.lint_ops import lint_curation

# Measured 2026-08-29 against the live catalog: the only series whose
# audit prompt exceeds the one-shot boundary. If this set changes, the
# catalog grew past the boundary somewhere and the chunked path applies
# to a new series; that is worth noticing, not silently absorbing.
_CHUNKED_SERIES = {
    "bibi_blocksberg",
    "wieso_weshalb_warum",
    "paw_patrol",
    "stephen_janetzko",
}

# The largest series shown to pass in one shot. It must stay above the
# threshold so the one-shot path never runs a series that has not been
# demonstrated to fit.
_LARGEST_KNOWN_ONE_SHOT = "feuerwehrmann_sam"


def _album(i: int, *, include: bool = True) -> dict:
    return {
        "album_id": f"a{i}",
        "provider": "spotify",
        "include": include,
        "episode_num": i,
        "title": f"Folge {i}: Ein Titel für Episode {i}",
        "confidence": "high",
    }


def _curation(n_albums: int) -> dict:
    return {
        "id": "s",
        "title": "S",
        "episode_pattern": r"^Folge (\d+):",
        "albums": [_album(i) for i in range(1, n_albums + 1)],
    }


def test_prompt_size_is_the_probed_measure():
    """The boundary only means something under the measure it was probed
    with. Changing this to a real tokenizer would need the probes redone."""
    assert prompt_size("abcd" * 100) == 100


def test_small_series_routes_one_shot():
    c = _curation(20)
    assert audit_route(c, []) == "one_shot"


def test_route_flips_exactly_at_the_threshold():
    """The decision is a pure size comparison, so a prompt one token over
    the boundary must route chunked and one at the boundary must not."""
    c = _curation(1)
    prompt = build_prompt(c, [])
    room = AUDIT_ONE_SHOT_MAX_TOKENS * 4 - len(prompt)
    # pad the single title so the prompt lands exactly on the boundary
    c["albums"][0]["title"] += "x" * room
    assert prompt_size(build_prompt(c, [])) == AUDIT_ONE_SHOT_MAX_TOKENS
    assert audit_route(c, []) == "one_shot"
    c["albums"][0]["title"] += "xxxx"
    assert audit_route(c, []) == "chunked"


def test_lint_issues_count_toward_the_size():
    """The one-shot prompt embeds lint findings, so they must be part of
    the measured size or a series could route one-shot and then overflow."""
    c = _curation(1)
    prompt = build_prompt(c, [])
    room = AUDIT_ONE_SHOT_MAX_TOKENS * 4 - len(prompt)
    c["albums"][0]["title"] += "x" * room
    assert audit_route(c, []) == "one_shot"
    assert audit_route(c, ["a lint finding that pushes it over"]) == "chunked"


def _real_curations() -> dict[str, dict]:
    out: dict[str, dict] = {}
    for path in sorted(paths.curation_dir().glob("*.json")):
        text = path.read_text(encoding="utf-8")
        if text.startswith("version https://git-lfs"):
            pytest.skip("curation files are git-lfs pointers here; run `git lfs pull`")
        out[path.stem] = json.loads(text)
    if not out:
        pytest.skip("no curation files found")
    return out


def test_catalog_routing_matches_the_measured_boundary():
    """Pin the threshold against the real catalog: exactly the four series
    measured past the boundary route chunked, and the largest series shown
    to pass in one shot still routes one-shot."""
    curations = _real_curations()
    chunked = {
        sid
        for sid, c in curations.items()
        if audit_route(c, lint_curation(c)) == "chunked"
    }
    assert chunked == _CHUNKED_SERIES
    assert (
        audit_route(
            curations[_LARGEST_KNOWN_ONE_SHOT],
            lint_curation(curations[_LARGEST_KNOWN_ONE_SHOT]),
        )
        == "one_shot"
    )


# ── build_overview: the whole-series picture without the album list ──


_TAIL_SERIES = sorted(_CHUNKED_SERIES)


def test_overview_has_no_album_lines():
    """The overview replaces the album list; the model pulls albums on
    demand through its tools. If an album line leaks in, the overview is
    the dump under another name."""
    c = _curation(40)
    ov = build_overview(c, [])
    assert "### Included albums" not in ov
    assert "### Excluded albums" not in ov
    assert not any(line.strip().startswith("[spotify:") for line in ov.splitlines())


def test_overview_carries_coverage_runs_facts_and_lint():
    c = _curation(6)
    c["albums"][2]["include"] = False
    c["albums"][2]["exclude_reason"] = "duplicate"
    c["series_facts"] = {
        "era_boundaries": [],
        "known_gaps": [{"number": 3, "reason": "dup excluded"}],
        "sub_series": [],
    }
    ov = build_overview(c, ["[spotify] a finding"])
    assert "spotify included episodes (5): 1-2, 4-6" in ov
    assert "spotify excluded: duplicate 1" in ov
    assert "Known gap: episode 3 -- dup excluded" in ov
    assert "### Lint findings (1)" in ov and "[spotify] a finding" in ov


def test_overview_folds_the_cluster_tail_on_a_fragmented_series():
    """A fragmented discography has hundreds of one-off title shapes.
    Listing every one with examples is the album dump under another
    name, so the overview shows the big shapes and folds the rest into
    one count line. A small series has nothing to fold."""
    curations = _real_curations()
    janetzko = build_overview(
        curations["stephen_janetzko"], lint_curation(curations["stephen_janetzko"])
    )
    assert "smaller shapes covering" in janetzko
    small = build_overview(_curation(5), [])
    assert "smaller shapes covering" not in small


def test_tail_series_overviews_fit_the_chunk_budget():
    """Every chunk of a chunked audit carries the overview, so it must be
    small on exactly the series that get chunked. Measured 2026-08-29:
    bibi 1,202 · wieso_weshalb_warum 1,494 · paw_patrol 340 ·
    stephen_janetzko 940 (6,165 before the cluster fold)."""
    curations = _real_curations()
    for sid in _TAIL_SERIES:
        ov = build_overview(curations[sid], lint_curation(curations[sid]))
        assert prompt_size(ov) <= 2_000, (sid, prompt_size(ov))


# ── plan_chunks: every album in exactly one chunk that fits ──────────


def _numbered(n: int, *, shape: str = "Folge") -> list[dict]:
    return [
        {
            "album_id": f"{shape[:2].lower()}{i}",
            "provider": "spotify",
            "include": True,
            "episode_num": i,
            "title": f"{shape} {i}: Ein Titel für Nummer {i}",
            "confidence": "high",
        }
        for i in range(1, n + 1)
    ]


def _chunk_tokens(c: dict, chunk: Chunk, lint: list[str]) -> int:
    ov = prompt_size(build_overview(c, lint))
    return (
        ov
        + _CHUNK_FRAMING_TOKENS
        + sum(prompt_size(_album_line(a)) + 1 for a in chunk.albums)
    )


def test_every_album_lands_in_exactly_one_chunk():
    c = {"id": "s", "title": "S", "albums": _numbered(700)}
    chunks = plan_chunks(c, [])
    ids = [a["album_id"] for ch in chunks for a in ch.albums]
    assert sorted(ids) == sorted(a["album_id"] for a in c["albums"])
    assert len(ids) == len(set(ids))


def test_no_chunk_exceeds_the_one_shot_cap():
    c = {"id": "s", "title": "S", "albums": _numbered(900)}
    for chunk in plan_chunks(c, []):
        assert _chunk_tokens(c, chunk, []) <= AUDIT_ONE_SHOT_MAX_TOKENS


def test_oversized_cluster_is_split_by_episode_in_order():
    """A main line of hundreds of 'Folge N' is subdivided by episode
    number; each range chunk holds a contiguous, ascending run."""
    c = {"id": "s", "title": "S", "albums": _numbered(600)}
    chunks = [
        ch for ch in plan_chunks(c, []) if ch.label.startswith("folge n episodes")
    ]
    assert len(chunks) >= 2
    last = 0
    for ch in chunks:
        eps = [a["episode_num"] for a in ch.albums]
        assert eps == sorted(eps)
        assert eps[0] > last
        last = eps[-1]


def test_sub_line_cluster_stays_whole_in_its_own_chunk():
    """Kampf um Kartoffelbrei (Special) - Teil N, some included and some
    excluded: the whole line must be judged together, so it is one chunk
    with both sides in it."""
    main = _numbered(300)
    special = [
        {
            "album_id": f"kk{i}",
            "provider": "spotify",
            "include": i <= 4,
            "episode_num": None,
            "title": f"Kampf um Kartoffelbrei (Special) - Teil {i}: Geschichte {i}",
            "confidence": "high",
            "exclude_reason": None if i <= 4 else "sub_series",
        }
        for i in range(1, 12)
    ]
    c = {"id": "s", "title": "S", "albums": main + special}
    chunks = plan_chunks(c, [])
    kk = [ch for ch in chunks if ch.label == "kampf um kartoffelbrei (special)"]
    assert len(kk) == 1
    assert {a["album_id"] for a in kk[0].albums} == {f"kk{i}" for i in range(1, 12)}


def test_cross_provider_pairs_are_packed_not_chunked_alone():
    """Two-member clusters are one album on two providers, not a sub-line.
    Two hundred of them must pack into a few chunks, not two hundred."""
    # title_shape collapses digits, so distinct albums need distinct words
    # in their titles or they would merge into one oversized cluster
    words = [f"Wort{chr(65 + i // 26)}{chr(65 + i % 26)}" for i in range(200)]
    albums = []
    for i, word in enumerate(words):
        for prov in ("spotify", "apple_music"):
            albums.append(
                {
                    "album_id": f"{prov[:2]}{i}",
                    "provider": prov,
                    "include": True,
                    "episode_num": None,
                    "title": f"Das Lied vom {word}",
                    "confidence": "high",
                }
            )
    chunks = plan_chunks({"id": "s", "title": "S", "albums": albums}, [])
    assert 1 <= len(chunks) <= 6
    assert all("small title groups" in ch.label for ch in chunks)


def test_real_bibi_kartoffelbrei_is_its_own_chunk():
    curations = _real_curations()
    c = curations["bibi_blocksberg"]
    chunks = plan_chunks(c, lint_curation(c))
    labels = [ch.label for ch in chunks]
    assert "kampf um kartoffelbrei (special)" in labels
    kk = next(ch for ch in chunks if ch.label == "kampf um kartoffelbrei (special)")
    assert any(a["include"] for a in kk.albums) and any(
        not a["include"] for a in kk.albums
    )


def test_chunk_labels_carry_no_album_count():
    # The progress line and the chunk prompt append the count themselves;
    # a label that also carries it printed "(30 albums) (30 albums)".
    albums = [
        {
            "album_id": f"k{i}",
            "provider": "spotify",
            "include": True,
            "episode_num": None,
            "title": f"Kurzhörspiel {'x' * 40}",
            "confidence": "high",
        }
        for i in range(400)
    ]
    for i, word in enumerate(["Apfel", "Birne", "Kirsche"]):
        albums.append(
            {
                "album_id": f"s{i}",
                "provider": "spotify",
                "include": True,
                "episode_num": None,
                "title": f"Das Lied vom {word}",
                "confidence": "high",
            }
        )
    chunks = plan_chunks({"id": "s", "title": "S", "albums": albums}, [])
    assert len(chunks) >= 3
    assert any(ch.label.endswith("(unnumbered)") for ch in chunks)
    assert any("small title groups" in ch.label for ch in chunks)
    assert not any("albums)" in ch.label for ch in chunks)


def test_real_paw_patrol_ranges_are_ordered_and_under_target():
    curations = _real_curations()
    c = curations["paw_patrol"]
    lint = lint_curation(c)
    chunks = plan_chunks(c, lint)
    ranges = [ch for ch in chunks if ch.label.startswith("folge n episodes")]
    assert len(ranges) >= 4
    last = 0
    for ch in ranges:
        eps = [a["episode_num"] for a in ch.albums]
        assert eps[0] >= last
        last = eps[-1]
        assert _chunk_tokens(c, ch, lint) <= _CHUNK_TARGET_TOKENS + 200


# ── merge_results: fold chunk verdicts without losing or inventing ───


def _ov(album_id: str, action: str, reason: str = "r") -> AuditOverride:
    return AuditOverride(
        album_id=album_id, provider="spotify", action=action, reason=reason
    )


def test_merge_keeps_agreeing_overrides_and_approves_when_all_do():
    merged = merge_results(
        [
            AuditResult(approve=True, overrides=[_ov("a", "exclude")]),
            AuditResult(approve=True, overrides=[_ov("b", "include")]),
        ]
    )
    assert merged.approve is True
    assert {(o.album_id, o.action) for o in merged.overrides} == {
        ("a", "exclude"),
        ("b", "include"),
    }


def test_merge_contradiction_drops_both_and_does_not_approve():
    """Two chunks overriding one album both ways is a disagreement the
    merge must never resolve silently: a human decides."""
    merged = merge_results(
        [
            AuditResult(approve=True, overrides=[_ov("a", "exclude", "compilation")]),
            AuditResult(approve=True, overrides=[_ov("a", "include", "real episode")]),
        ]
    )
    assert merged.approve is False
    assert merged.overrides == []
    assert any("[chunk_conflict] spotify:a" in c for c in merged.concerns)


def test_merge_forces_fact_updates_to_merge_mode():
    """A chunk sees one slice; a replace from it would wipe facts other
    chunks or earlier audits established."""
    merged = merge_results(
        [AuditResult(approve=True, fact_updates=[AuditFactUpdate(mode="replace")])]
    )
    assert merged.fact_updates[0].mode == "merge"
    assert any("[chunk_facts]" in c for c in merged.concerns)


def test_merge_dedups_repeated_concerns_before_the_escalation_count():
    """Every chunk repeating the same known-gap note must not escalate on
    volume: six copies of one concern are one concern."""
    same = "known gap 62 is documented and correct"
    merged = merge_results(
        [AuditResult(approve=True, concerns=[same]) for _ in range(6)]
    )
    assert merged.concerns == [same]


def test_merge_any_disapproving_chunk_disapproves():
    merged = merge_results(
        [AuditResult(approve=True), AuditResult(approve=False, concerns=["bad"])]
    )
    assert merged.approve is False


def test_merge_of_nothing_does_not_approve():
    assert merge_results([]).approve is False


# ── audit_one: the one-shot path is untouched by the dispatch ────────


def test_one_shot_series_runs_exactly_todays_prompt_once(monkeypatch, tmp_path):
    """276 series route one-shot. For them audit_one must call the model
    exactly once with exactly build_prompt's text: the dispatch is a
    no-op on the path the size boundary was probed against."""
    import lauschi_catalog.catalog.audit_ops as m

    c = _curation(20)
    (tmp_path / "s.json").write_text(json.dumps(c))
    monkeypatch.setattr(m, "CURATION_DIR", tmp_path)
    monkeypatch.setenv("OPENCODE_API_KEY", "test")
    monkeypatch.setattr(m, "build_model", lambda *a, **k: object())
    monkeypatch.setattr(m, "_build_audit_agent", lambda *a, **k: object())
    calls: list[str] = []

    async def fake_run(prepared, prompt, **kw):
        calls.append(prompt)
        return AuditResult(approve=True)

    monkeypatch.setattr(m, "_run_audit_prompt", fake_run)
    result = asyncio.run(m.audit_one("s", force=True))
    assert result is not None and result.approve is True
    assert calls == [build_prompt(c, lint_curation(c))]


def _chunked_setup(monkeypatch, tmp_path):
    import lauschi_catalog.catalog.audit_ops as m

    c = {"id": "s", "title": "S", "albums": _numbered(700)}
    for a in c["albums"]:
        a["title"] += " " + "x" * 40
    lint = lint_curation(c)
    assert audit_route(c, lint) == "chunked"
    (tmp_path / "s.json").write_text(json.dumps(c))
    monkeypatch.setattr(m, "CURATION_DIR", tmp_path)
    monkeypatch.setenv("OPENCODE_API_KEY", "test")
    monkeypatch.setattr(m, "build_model", lambda *a, **k: object())
    monkeypatch.setattr(m, "_build_audit_agent", lambda *a, **k: object())
    return m, c, lint


def test_a_chunk_that_fails_once_is_retried_from_a_fresh_context(monkeypatch, tmp_path):
    m, c, lint = _chunked_setup(monkeypatch, tmp_path)
    calls: list[str] = []
    progress: list[str] = []

    async def flaky_run(prepared, prompt, **kw):
        calls.append(prompt)
        if "### This chunk (2 of" in prompt and calls.count(prompt) == 1:
            raise RuntimeError("Model token limit (32768) exceeded")
        return AuditResult(approve=True)

    monkeypatch.setattr(m, "_run_audit_prompt", flaky_run)
    result = asyncio.run(m.audit_one("s", force=True, on_progress=progress.append))
    expected = len(plan_chunks(c, lint))
    assert result is not None and result.approve
    assert len(calls) == expected + 1
    assert any("chunk 2 attempt 1/3 failed" in p for p in progress)


def test_a_chunk_that_keeps_failing_fails_the_series_after_three_attempts(
    monkeypatch, tmp_path
):
    m, _, _ = _chunked_setup(monkeypatch, tmp_path)
    calls: list[str] = []

    async def broken_run(prepared, prompt, **kw):
        calls.append(prompt)
        raise RuntimeError("Model token limit (32768) exceeded")

    monkeypatch.setattr(m, "_run_audit_prompt", broken_run)
    with pytest.raises(RuntimeError):
        asyncio.run(m.audit_one("s", force=True))
    assert len(calls) == 3


def test_chunked_series_runs_one_prompt_per_chunk_and_merges(monkeypatch, tmp_path):
    import lauschi_catalog.catalog.audit_ops as m

    # size, not album count, decides the route: pad titles so the prompt is
    # past the one-shot boundary, and assert that precondition explicitly
    c = {"id": "s", "title": "S", "albums": _numbered(700)}
    for a in c["albums"]:
        a["title"] += " " + "x" * 40
    lint = lint_curation(c)
    assert audit_route(c, lint) == "chunked"
    (tmp_path / "s.json").write_text(json.dumps(c))
    monkeypatch.setattr(m, "CURATION_DIR", tmp_path)
    monkeypatch.setenv("OPENCODE_API_KEY", "test")
    monkeypatch.setattr(m, "build_model", lambda *a, **k: object())
    monkeypatch.setattr(m, "_build_audit_agent", lambda *a, **k: object())
    prompts: list[str] = []

    async def fake_run(prepared, prompt, **kw):
        prompts.append(prompt)
        return AuditResult(approve=True, concerns=[f"seen {len(prompts)}"])

    monkeypatch.setattr(m, "_run_audit_prompt", fake_run)
    expected = len(plan_chunks(c, lint))
    result = asyncio.run(m.audit_one("s", force=True))
    assert len(prompts) == expected >= 2
    overview = build_overview(c, lint)
    assert all(p.startswith(overview) for p in prompts)
    assert all("### This chunk (" in p for p in prompts)
    assert result is not None and len(result.concerns) == expected
