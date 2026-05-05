"""Tests for the override-recording layer of review.py.

The recording logic is shared by ``propose_override`` (single) and
``propose_overrides_batch`` (many). Pinning it here so future edits
to either tool can't silently drift from the dedup / shape contract.

These tests target ``_try_record_override`` directly. The tools
themselves are thin wrappers over this helper plus their own
action/reason validation; the helper is where the load-bearing
logic lives.
"""

from __future__ import annotations

from lauschi_catalog.commands.review import Deps, _try_record_override


def _deps_with(albums: list[dict]) -> Deps:
    return Deps(providers=[], curation={"albums": albums})


def _album(aid: str, *, provider: str = "spotify") -> dict:
    return {"album_id": aid, "provider": provider, "include": True,
            "title": f"Folge: {aid}"}


# ── happy path ────────────────────────────────────────────────────────────


def test_records_when_album_known_and_unique():
    deps = _deps_with([_album("a"), _album("b")])
    assert _try_record_override(deps, "a", "exclude", "x", provider="spotify") is None
    assert len(deps.proposed_overrides) == 1
    assert deps.proposed_overrides[0] == {
        "album_id": "a", "provider": "spotify",
        "action": "exclude", "reason": "x",
    }
    assert deps._override_count == 1


def test_records_include_action():
    deps = _deps_with([_album("a")])
    _try_record_override(deps, "a", "include", "fits the series", provider="spotify")
    assert deps.proposed_overrides[0]["action"] == "include"


def test_records_apple_music_provider():
    """Provider is passed through verbatim — used for provenance display."""
    deps = _deps_with([_album("a", provider="apple_music")])
    _try_record_override(deps, "a", "exclude", "x", provider="apple_music")
    assert deps.proposed_overrides[0]["provider"] == "apple_music"


# ── skip reasons ──────────────────────────────────────────────────────────


def test_skips_unknown_album_id():
    deps = _deps_with([_album("a")])
    assert _try_record_override(deps, "ghost", "exclude", "x", provider="spotify") == "unknown"
    assert deps.proposed_overrides == []
    assert deps._override_count == 0


def test_skips_already_overridden_album_id():
    deps = _deps_with([_album("a")])
    _try_record_override(deps, "a", "exclude", "x", provider="spotify")
    assert _try_record_override(deps, "a", "exclude", "y", provider="spotify") == "duplicate"
    # Still only one override; the duplicate attempt is a no-op
    assert len(deps.proposed_overrides) == 1
    # Reason from the FIRST call wins; second was ignored
    assert deps.proposed_overrides[0]["reason"] == "x"


def test_duplicate_detection_is_per_album_id_not_action():
    """Trying include after exclude (or vice versa) on the same album
    is still a duplicate. One override per album per run is the rule."""
    deps = _deps_with([_album("a")])
    _try_record_override(deps, "a", "exclude", "x", provider="spotify")
    assert _try_record_override(deps, "a", "include", "y", provider="spotify") == "duplicate"
    assert deps.proposed_overrides[0]["action"] == "exclude"


# ── batch-style usage ─────────────────────────────────────────────────────


def test_batch_via_helper_records_unique_skips_dup():
    """Simulates how propose_overrides_batch loops over the helper:
    same call shape, mixed outcomes accumulate cleanly."""
    deps = _deps_with([_album("a"), _album("b"), _album("c")])
    # Pre-existing override on 'b' to test mid-batch duplicate handling
    _try_record_override(deps, "b", "exclude", "earlier", provider="spotify")

    outcomes = [
        _try_record_override(deps, aid, "exclude", "format-variant", provider="spotify")
        for aid in ["a", "b", "c", "ghost"]
    ]
    assert outcomes == [None, "duplicate", None, "unknown"]
    assert {o["album_id"] for o in deps.proposed_overrides} == {"a", "b", "c"}
    assert deps._override_count == 3  # only successful records bump the counter


def test_helper_does_not_validate_action_or_reason():
    """Action/reason validation is the tool's job, not the helper's
    — batch wants to fail the WHOLE batch on bad action, while the
    single tool wants the same. Keeping the validation at the
    boundary lets both choose consistently."""
    deps = _deps_with([_album("a")])
    # Helper accepts garbage action — caller is expected to have
    # validated already. This pins the contract.
    assert _try_record_override(deps, "a", "garbage", "", provider="spotify") is None
    assert deps.proposed_overrides[0]["action"] == "garbage"
