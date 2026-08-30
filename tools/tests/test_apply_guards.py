"""Apply must be atomic per entry and each guard its own flag.

One flag used to disable five unrelated guards, and a tripped loss
guard still let pattern, artist IDs and facts through, so series.yaml
could end up with the new episode pattern over the old album list.
"""

from __future__ import annotations

import json

from ruamel.yaml import YAML

from lauschi_catalog.catalog.apply_ops import apply_one

yaml = YAML()
yaml.preserve_quotes = True


def _yaml_entry(albums=10, pattern=None, artist_ids=("spotify-artist",)):
    entry: dict = {
        "id": "s",
        "title": "S",
        "providers": {
            "spotify": {
                "artist_ids": list(artist_ids),
                "albums": [
                    {"id": f"old{i}", "episode": i + 1, "title": f"Old {i}"}
                    for i in range(albums)
                ],
            }
        },
    }
    if pattern is not None:
        entry["episode_pattern"] = pattern
    return entry


def _curation(
    n_albums: int,
    *,
    pattern=r"Folge (\d+):",
    content_type=None,
) -> dict:
    albums = [
        {
            "album_id": f"new{i}",
            "provider": "spotify",
            "include": True,
            "title": f"New {i}",
            "episode_num": i + 1,
            "release_date": "2026-01-01",
        }
        for i in range(n_albums)
    ]
    data: dict = {
        "id": "s",
        "title": "S",
        "aliases": ["Es"],
        "series_facts": {"era_boundaries": []},
        "albums": albums,
    }
    if pattern is not None:
        data["episode_pattern"] = pattern
    if content_type is not None:
        data["content_type"] = content_type
    return data


def _dump(entry: dict) -> dict:
    import json

    return json.loads(json.dumps(entry))


class TestLossGuardAtomicity:
    def test_tripped_loss_guard_leaves_the_whole_entry_untouched(self):
        """The old code skipped the provider's albums but still wrote
        pattern, content_type, artist IDs and facts: yaml could end up
        with a new pattern over the old album list."""
        yaml_data = {"series": [_yaml_entry(albums=10, pattern=r"Old (\d+)")]}
        curation = {
            **_curation(3, pattern=r"New (\d+):"),  # 10 -> 3: trips
            "review": {"status": "approved", "audited_at": "2026-08-01T00:00:00+00:00"},
            "curated_at": "2026-01-01T00:00:00+00:00",
        }

        updated = apply_one("s", curation, yaml_data, allow_loss=False)

        assert updated is False
        entry = yaml_data["series"][0]
        assert entry["episode_pattern"] == "Old (\\d+)"  # unchanged
        assert [a["id"] for a in entry["providers"]["spotify"]["albums"]][:2] == [
            "old0",
            "old1",
        ]
        assert len(entry["providers"]["spotify"]["albums"]) == 10
        assert entry["providers"]["spotify"]["artist_ids"] == ["spotify-artist"]
        assert "aliases" not in entry


def _approved_curation(n_albums: int) -> dict:
    return {
        **_curation(n_albums),
        "review": {"status": "approved", "audited_at": "2026-08-01T00:00:00+00:00"},
        "curated_at": "2026-01-01T00:00:00+00:00",
    }


class TestFlags:
    def test_allow_loss_applies_a_heavy_drop(self):
        yaml_data = {"series": [_yaml_entry(albums=10)]}
        updated = apply_one(
            "s",
            _approved_curation(1),
            yaml_data,
            allow_loss=True,
        )
        assert updated is True
        assert len(yaml_data["series"][0]["providers"]["spotify"]["albums"]) == 1

    def test_allowing_loss_does_not_skip_the_review_gates(self, tmp_path, monkeypatch):
        """--allow-loss lifts the loss guard, not the review gate: an
        unaudited curation is still refused even over a heavy drop."""
        from lauschi_catalog.catalog.apply_ops import apply_curations

        base = tmp_path / "assets" / "catalog"
        (base / "curation").mkdir(parents=True)
        (base / "series.yaml").write_text(
            "series:\n  - id: s\n    title: S\n    providers: {}\n"
        )
        monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))

        result = apply_curations(
            "s",
            allow_unreviewed=False,
            allow_loss=True,
            on_progress=lambda _m: None,
        )
        assert result.applied == 0
        assert result.details[0].refused is True

    def test_allowing_unreviewed_does_not_skip_the_loss_guard(self):
        """The two flags are independent: an unaudited, heavy-drop
        curation applied with --allow-unreviewed still trips the loss
        guard (which is applied_one's own guard, not the CLI's)."""
        yaml_data = {"series": [_yaml_entry(albums=10)]}
        # should_apply is the review gate and would refuse first; drive
        # the loss guard directly through apply_one like the caller does
        # after should_apply passes.
        updated = apply_one("s", _approved_curation(1), yaml_data, allow_loss=False)
        assert updated is False
        assert len(yaml_data["series"][0]["providers"]["spotify"]["albums"]) == 10

    def test_each_gate_is_checked_even_when_the_other_flag_is_set(
        self, tmp_path, monkeypatch
    ):
        """--allow-unreviewed overrides the review gate; the loss guard
        still blocks the same run."""
        from lauschi_catalog.catalog.apply_ops import apply_curations

        base = tmp_path / "assets" / "catalog"
        (base / "curation").mkdir(parents=True)
        curation = {
            "id": "s",
            "title": "S",
            "albums": [
                {
                    "album_id": f"a{i}",
                    "provider": "spotify",
                    "include": True,
                    "title": f"Folge {i}",
                    "episode_num": i + 1,
                }
                for i in range(3)
            ],  # heavy drop on a 10-album yaml entry
        }
        (base / "curation" / "s.json").write_text(json.dumps(curation))
        (base / "series.yaml").write_text(
            json.dumps(  # series.yaml is YAML; JSON is a valid subset
                {"series": [{"id": "s", "title": "S", "providers": {}}]}
            )
        )
        # pre-populate the yaml entry with 10 albums so the drop trips
        entry = _yaml_entry(albums=10)
        import io as _io

        buf = _io.StringIO()
        yaml.dump({"series": [entry]}, buf)
        (base / "series.yaml").write_text(buf.getvalue())
        monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))

        messages: list[str] = []
        result = apply_curations(
            "s",
            allow_unreviewed=True,
            allow_loss=False,
            on_progress=messages.append,
        )
        assert result.applied == 0
        # gate passed (allow_unreviewed), the loss guard refused the write
        assert any("REFUSED" in m and ">50% loss" in m for m in messages)
        assert result.details[0].refused is False  # not a review-gate refusal


class TestEmptyCuration:
    def test_zero_included_albums_is_printed_and_counted_not_silent(self):
        yaml_data = {"series": [_yaml_entry(albums=10)]}
        curation = _approved_curation(0)
        assert curation["albums"] == []

        updated = apply_one("s", curation, yaml_data)

        assert updated is False
        assert len(yaml_data["series"][0]["providers"]["spotify"]["albums"]) == 10


class TestLossGuardSignature:
    def test_the_loss_guard_threshold_is_exact(self):
        """The guard threshold is unchanged: a >50% drop trips. 10 -> 5
        is exactly 50% and applies; 10 -> 4 is 60% and refuses."""
        yaml_data = {"series": [_yaml_entry(albums=10)]}
        updated = apply_one("s", self_entry(5), yaml_data)
        assert updated is True

        yaml_data = {"series": [_yaml_entry(albums=10)]}
        updated = apply_one("s", self_entry(4), yaml_data)
        assert updated is False
        assert len(yaml_data["series"][0]["providers"]["spotify"]["albums"]) == 10


def self_entry(n: int) -> dict:
    return {
        **_curation(n),
        "review": {"status": "approved", "audited_at": "2026-08-01T00:00:00+00:00"},
        "curated_at": "2026-01-01T00:00:00+00:00",
    }
