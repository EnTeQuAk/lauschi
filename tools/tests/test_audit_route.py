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
