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

import json

import pytest

from lauschi_catalog.catalog import paths
from lauschi_catalog.catalog.audit_ops import (
    AUDIT_ONE_SHOT_MAX_TOKENS,
    audit_route,
    build_overview,
    build_prompt,
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
