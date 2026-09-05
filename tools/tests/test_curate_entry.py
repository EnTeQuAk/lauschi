"""The shared curate-entry path.

The CLI, the web job runner, and curate --all each spelled the lookup →
existing curation → content type → curate_one chain inline, with the
subtle parts (split_from refusal, existing record loading, content-type
resolution, frozen facts) diverging between copies. One function feeds
all three; behavior is pinned here.
"""

from pathlib import Path

import pytest

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import (
    CurateEntryPrepared,
    CurateOneResult,
    curate_all,
    curate_entry,
    prepare_curation,
)
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig

pytestmark = pytest.mark.anyio


def _entry(**kw) -> CatalogEntry:
    defaults: dict = {
        "id": "die_playmos",
        "title": "Die Playmos",
        "providers": {"spotify": ProviderConfig(artist_ids=["artist-1"])},
    }
    defaults.update(kw)
    return CatalogEntry(**defaults)


@pytest.fixture
def scratch(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    catalog = tmp_path / "assets" / "catalog"
    (catalog / "curation").mkdir(parents=True)
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    return catalog


class TestPrepareCuration:
    def test_resolves_content_type_and_existing(self, scratch: Path) -> None:
        (scratch / "curation" / "die_playmos.json").write_text(
            '{"id": "die_playmos", "content_type": "music", "albums": []}'
        )
        prepared = prepare_curation(_entry())
        assert isinstance(prepared, CurateEntryPrepared)
        assert prepared.existing is not None
        assert prepared.existing.get("content_type") == "music"
        assert prepared.requested_type == "music"
        assert prepared.entry_content_type == "music"
        assert prepared.series_id == "die_playmos"

    def test_cli_override_wins_but_the_yaml_type_stays_visible(
        self, scratch: Path
    ) -> None:
        prepared = prepare_curation(_entry(), cli_content_type="music")
        assert prepared.requested_type == "music"
        assert prepared.entry_content_type == "hoerspiel"

    def test_missing_series_raises(self, scratch: Path) -> None:
        with pytest.raises(KeyError, match="not in the catalog"):
            prepare_curation("nope")

    def test_split_from_is_refused(self, scratch: Path) -> None:
        with pytest.raises(ValueError, match="split from"):
            prepare_curation(_entry(id="child", title="Child", split_from="parent"))

    def test_corrupt_prior_curation_fails_fast(self, scratch: Path) -> None:
        # An unreadable record may hold approved audit state; silently
        # curating from scratch would overwrite it hours later at save.
        (scratch / "curation" / "die_playmos.json").write_text("{broken")
        with pytest.raises(ValueError, match="unreadable"):
            prepare_curation(_entry())

    def test_pattern_implies_hoerspiel_against_stale_music(self, scratch: Path) -> None:
        (scratch / "curation" / "die_playmos.json").write_text(
            '{"id": "die_playmos", "content_type": "music", "albums": []}'
        )
        prepared = prepare_curation(_entry(episode_pattern=r"^Folge (\d+):"))
        assert prepared.requested_type == "hoerspiel"

    def test_existing_curation_none_when_absent(self, scratch: Path) -> None:
        prepared = prepare_curation(_entry())
        assert prepared.existing is None


class TestCurateEntry:
    async def test_routes_through_curate_one_with_the_resolved_inputs(
        self, scratch: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        prepared = CurateEntryPrepared(
            entry=_entry(),
            existing={"id": "die_playmos", "albums": []},
            requested_type="hoerspiel",
        )
        seen: dict = {}

        async def fake_curate_one(title, providers, *, series_id=None, **kw):
            seen["title"] = title
            seen["series_id"] = series_id
            seen.update(kw)
            return CurateOneResult(ok=True)

        monkeypatch.setattr(curate_ops, "curate_one", fake_curate_one)
        result = await curate_entry(prepared, ["prov"], on_progress=lambda _m: None)
        assert result.ok is True
        assert seen["title"] == "Die Playmos"
        assert seen["series_id"] == "die_playmos"
        assert seen["known_artist_ids"] == {"spotify": ["artist-1"]}
        assert seen["content_type"] == "hoerspiel"
        assert "existing_facts" in seen
        assert seen["existing_curation"] == {"id": "die_playmos", "albums": []}


class TestCurateAll:
    async def test_a_corrupt_file_fails_one_series_not_the_run(
        self, scratch: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        good = _entry(id="good_series", title="Good")
        bad = _entry(id="bad_series", title="Bad")
        monkeypatch.setattr(curate_ops, "load_catalog", lambda: [good, bad])
        (scratch / "curation" / "bad_series.json").write_text("{broken")

        curated: list[str] = []

        async def fake_curate_entry(prepared, providers, **kw):
            curated.append(prepared.series_id)
            return CurateOneResult(ok=True)

        monkeypatch.setattr(curate_ops, "curate_entry", fake_curate_entry)
        result = await curate_all([], force=True, on_progress=lambda _m: None)
        assert curated == ["good_series"]
        assert result.succeeded == 1
        assert result.failed == 1
        assert result.failed_ids == ["bad_series"]
