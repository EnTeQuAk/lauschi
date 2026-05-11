"""Tests for apply._apply_one — the function that ships approved
curations into series.yaml. Pinning the change-detection logic because
a silent skip here means the live catalog disagrees with the reviewed
curation, and the disagreement is invisible until someone re-runs apply.
"""

from __future__ import annotations

from typing import Any

from lauschi_catalog.commands.apply import _apply_one


def _curation(*, albums: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "id": "s1",
        "title": "Test Series",
        "albums": albums,
    }


def _included(album_id: str, *, provider: str = "spotify",
              episode_num: int | None = None,
              title: str = "T") -> dict[str, Any]:
    return {
        "album_id": album_id,
        "provider": provider,
        "include": True,
        "episode_num": episode_num,
        "title": title,
    }


def _yaml_with(series_albums: list[dict] | None = None) -> dict:
    """series.yaml shape with one entry, optionally pre-populated."""
    entry: dict = {"id": "s1", "providers": {"spotify": {}}}
    if series_albums is not None:
        entry["providers"]["spotify"]["albums"] = series_albums
    return {"series": [entry]}


def test_apply_one_writes_when_episode_number_changed_via_pattern_update():
    """The bug this test pins: a pattern update re-extracts an episode
    number, the album_id is unchanged, but the episode field IS
    different. ID-only comparison would skip the write and ship stale
    episode numbers to the app."""
    yaml_data = _yaml_with([
        {"id": "a", "episode": 47, "title": "047/Title"},
    ])
    curation = _curation(albums=[
        _included("a", episode_num=47, title="Folge 47: Title"),
    ])
    # Same album, but title changed (and could be episode change too).
    updated = _apply_one("s1", curation, yaml_data)
    assert updated is True
    saved = yaml_data["series"][0]["providers"]["spotify"]["albums"]
    assert saved[0]["title"] == "Folge 47: Title"


def test_apply_one_skips_write_when_everything_identical():
    yaml_data = _yaml_with([
        {"id": "a", "episode": 1, "title": "T"},
    ])
    curation = _curation(albums=[
        _included("a", episode_num=1, title="T"),
    ])
    assert _apply_one("s1", curation, yaml_data) is False


def test_apply_one_writes_when_album_added():
    yaml_data = _yaml_with([
        {"id": "a", "episode": 1, "title": "T"},
    ])
    curation = _curation(albums=[
        _included("a", episode_num=1, title="T"),
        _included("b", episode_num=2, title="U"),
    ])
    assert _apply_one("s1", curation, yaml_data) is True
    saved_ids = [
        e["id"] for e in
        yaml_data["series"][0]["providers"]["spotify"]["albums"]
    ]
    assert saved_ids == ["a", "b"]


def test_apply_one_writes_when_album_removed():
    yaml_data = _yaml_with([
        {"id": "a", "episode": 1, "title": "T"},
        {"id": "b", "episode": 2, "title": "U"},
    ])
    curation = _curation(albums=[
        _included("a", episode_num=1, title="T"),
    ])
    assert _apply_one("s1", curation, yaml_data) is True


def test_apply_one_writes_when_only_episode_number_differs():
    """Episode number flipped (e.g., review correction); same id+title."""
    yaml_data = _yaml_with([
        {"id": "a", "episode": 5, "title": "T"},
    ])
    curation = _curation(albums=[
        _included("a", episode_num=6, title="T"),
    ])
    assert _apply_one("s1", curation, yaml_data) is True
    saved = yaml_data["series"][0]["providers"]["spotify"]["albums"]
    assert saved[0]["episode"] == 6


# ── content_type handling ─────────────────────────────────────────────────


def _curation_with_ct(content_type: str | None, *, albums: list[dict]) -> dict:
    data = _curation(albums=albums)
    if content_type is not None:
        data["content_type"] = content_type
    return data


def test_apply_writes_music_content_type():
    yaml_data = _yaml_with([])
    curation = _curation_with_ct("music", albums=[
        _included("a", episode_num=1, title="T"),
    ])
    _apply_one("s1", curation, yaml_data)
    assert yaml_data["series"][0].get("content_type") == "music"


def test_apply_strips_redundant_hoerspiel_when_pattern_signals_it():
    """When the yaml entry has an episode_pattern, the curate flow's
    _resolve_is_music picks hoerspiel via that signal — so storing
    `content_type: hoerspiel` explicitly is yaml noise. Strip it."""
    yaml_data = _yaml_with([{"id": "a", "episode": 1, "title": "Folge 1: T"}])
    yaml_data["series"][0]["content_type"] = "hoerspiel"
    yaml_data["series"][0]["episode_pattern"] = r"^Folge (\d+):"
    curation = _curation_with_ct("hoerspiel", albums=[
        _included("a", episode_num=1, title="Folge 1: T"),
    ])
    curation["episode_pattern"] = r"^Folge (\d+):"
    updated = _apply_one("s1", curation, yaml_data)
    assert updated is True
    assert "content_type" not in yaml_data["series"][0]


def test_apply_keeps_explicit_hoerspiel_when_no_other_signal():
    """Series like ferien_saltkrokan have content_type=hoerspiel but
    no episode_pattern (named episodes). Stripping content_type would
    leave _resolve_is_music with no signals and it would default to
    MUSIC on a future re-curate. Keep the explicit value as a
    safeguard against re-introducing the original misclassification
    bug."""
    yaml_data = _yaml_with([{"id": "a", "title": "T"}])
    yaml_data["series"][0]["content_type"] = "hoerspiel"
    # No episode_pattern in yaml or curation
    curation = _curation_with_ct("hoerspiel", albums=[
        _included("a", episode_num=None, title="T"),
    ])
    _apply_one("s1", curation, yaml_data)
    # content_type must persist as a signal for future re-curates.
    assert yaml_data["series"][0].get("content_type") == "hoerspiel"


def test_apply_writes_explicit_hoerspiel_when_correcting_stale_music_without_pattern():
    """Real correction scenario from this session: a series was
    incorrectly tagged as `content_type: music`, re-curated as
    hoerspiel, the new curation has no episode_pattern. Apply must
    replace music with explicit hoerspiel — not just drop the music
    tag — so _resolve_is_music can pick the right mode on any future
    re-curate, even if the curation JSON gets deleted."""
    yaml_data = _yaml_with([{"id": "a", "title": "T"}])
    yaml_data["series"][0]["content_type"] = "music"
    curation = _curation_with_ct("hoerspiel", albums=[
        _included("a", episode_num=None, title="T"),
    ])
    updated = _apply_one("s1", curation, yaml_data)
    assert updated is True
    assert yaml_data["series"][0].get("content_type") == "hoerspiel"


def test_apply_clears_stale_hoerspiel_when_pattern_is_authoritative():
    """If yaml has both `content_type: hoerspiel` AND an
    episode_pattern, the pattern alone signals hoerspiel — so
    content_type is redundant. Strip it for yaml hygiene."""
    yaml_data = _yaml_with([{"id": "a", "episode": 1, "title": "Folge 1: T"}])
    yaml_data["series"][0]["content_type"] = "hoerspiel"
    yaml_data["series"][0]["episode_pattern"] = r"^Folge (\d+):"
    curation = _curation_with_ct("hoerspiel", albums=[
        _included("a", episode_num=1, title="Folge 1: T"),
    ])
    curation["episode_pattern"] = r"^Folge (\d+):"
    _apply_one("s1", curation, yaml_data)
    assert "content_type" not in yaml_data["series"][0]
    # Pattern still there as the surviving hoerspiel signal
    assert yaml_data["series"][0].get("episode_pattern") == r"^Folge (\d+):"


# ── episode_pattern sync (both directions) ────────────────────────────────


def test_apply_writes_new_episode_pattern():
    """Curate produced a pattern; series.yaml previously had none."""
    yaml_data = _yaml_with([{"id": "a", "episode": 1, "title": "T"}])
    curation = _curation(albums=[
        _included("a", episode_num=1, title="Folge 1: T"),
    ])
    curation["episode_pattern"] = r"^Folge (\d+):"
    updated = _apply_one("s1", curation, yaml_data)
    assert updated is True
    assert yaml_data["series"][0]["episode_pattern"] == r"^Folge (\d+):"


def test_apply_clears_stale_pattern_when_curation_now_none():
    """The SimsalaGrimm scenario: a previous (bad) apply wrote a
    non-numeric pattern to series.yaml. Re-curate produces None.
    Apply MUST clear the stale pattern, not silently keep it —
    otherwise the dead pattern stays forever and confuses any
    code that reads series.yaml and tries extract_episode."""
    yaml_data = _yaml_with([{"id": "a", "episode": 1, "title": "T"}])
    yaml_data["series"][0]["episode_pattern"] = [
        r"^(.+?) \(Das Original-Hörspiel zur TV Serie\)$",
        r"^(.+?) \(Die neuen Abenteuer von Yoyo und Doc Croc\)$",
    ]
    curation = _curation(albums=[
        _included("a", episode_num=None, title="Aladin (Das Original)"),
    ])
    # No episode_pattern in curation → None
    updated = _apply_one("s1", curation, yaml_data)
    assert updated is True
    assert "episode_pattern" not in yaml_data["series"][0]


def test_apply_replaces_pattern_with_different_pattern():
    """Pattern correction: old regex replaced by new one."""
    yaml_data = _yaml_with([{"id": "a", "episode": 1, "title": "T"}])
    yaml_data["series"][0]["episode_pattern"] = r"^Folge (\d+):"
    curation = _curation(albums=[
        _included("a", episode_num=1, title="01/T"),
    ])
    curation["episode_pattern"] = r"^(\d+)/"
    updated = _apply_one("s1", curation, yaml_data)
    assert updated is True
    assert yaml_data["series"][0]["episode_pattern"] == r"^(\d+)/"


def test_apply_no_op_when_pattern_already_matches():
    """Idempotency: same pattern in yaml and curation, no write needed."""
    yaml_data = _yaml_with([{"id": "a", "episode": 1, "title": "Folge 1: T"}])
    yaml_data["series"][0]["episode_pattern"] = r"^Folge (\d+):"
    curation = _curation(albums=[
        _included("a", episode_num=1, title="Folge 1: T"),
    ])
    curation["episode_pattern"] = r"^Folge (\d+):"
    # Album entry is also unchanged so the only thing that could
    # trigger a write is the pattern. None does → updated=False.
    assert _apply_one("s1", curation, yaml_data) is False
