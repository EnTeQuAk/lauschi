"""A split-off child is curated for its own line.

Split-off entries share their artist pages with the parent, so a
curate used to return the parent's whole discography and was refused
(Hanni und Nanni, 2026-08-31: 187 parent albums included). Now the
catalog's own facts scope the run: the child's applied albums arrive
included with their numbers, the parent's and every other sibling's
applied albums arrive excluded as sub_series_bleed, and the batch only
decides what is new on the shared page (Lego Ninjago "(Band 13-20)").
"""

import json

import pytest

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import _inject_for_split_child, prepare_curation
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig


def _cfg(artist, albums):
    return ProviderConfig(
        artist_ids=[artist],
        album_ids=[a["id"] for a in albums],
        albums=albums,
    )


PARENT = CatalogEntry(
    id="lego_ninjago",
    title="LEGO Ninjago",
    providers={
        "spotify": _cfg(
            "art",
            [
                {
                    "id": "p1",
                    "title": "Folge 1: A",
                    "episode": 1,
                    "release_date": "2020-01-01",
                }
            ],
        )
    },
)
CHILD = CatalogEntry(
    id="lego_ninjago_hoerbuch",
    title="LEGO Ninjago: Hörbücher",
    split_from="lego_ninjago",
    providers={
        "spotify": _cfg(
            "art",
            [
                {
                    "id": "h1",
                    "title": "Zane (Band 16)",
                    "episode": 16,
                    "release_date": "2021-01-01",
                }
            ],
        )
    },
)
OTHER = CatalogEntry(
    id="lego_ninjago_kinofilm",
    title="LEGO Ninjago: Kinofilm",
    split_from="lego_ninjago",
    providers={
        "spotify": _cfg(
            "art",
            [
                {
                    "id": "k1",
                    "title": "Der Film",
                    "episode": None,
                    "release_date": "2017-01-01",
                }
            ],
        )
    },
)
CATALOG = [PARENT, CHILD, OTHER]


class TestInjectForSplitChild:
    @pytest.fixture(autouse=True)
    def _no_owner_curations(self, monkeypatch: pytest.MonkeyPatch, tmp_path):
        """The owners' curation files stay out of these tests: they read
        the real catalog otherwise."""
        monkeypatch.setattr(
            curate_ops, "curation_path", lambda sid: tmp_path / f"{sid}.json"
        )

    def test_own_albums_arrive_included_with_numbers_and_the_rest_as_bleed(
        self, monkeypatch: pytest.MonkeyPatch
    ):
        monkeypatch.setattr(curate_ops, "load_catalog", lambda: CATALOG)
        result = _inject_for_split_child(None, CHILD)
        by = {a["album_id"]: a for a in result["albums"]}
        assert by["h1"]["include"] is True and by["h1"]["episode_num"] == 16
        assert (
            by["p1"]["include"] is False
            and by["p1"]["exclude_reason"] == "sub_series_bleed"
        )
        assert "lego_ninjago" in by["p1"]["notes"]
        assert (
            by["k1"]["include"] is False
            and "lego_ninjago_kinofilm" in by["k1"]["notes"]
        )
        assert set(by) == {"h1", "p1", "k1"}

    def test_an_existing_decision_is_not_overwritten(
        self, monkeypatch: pytest.MonkeyPatch
    ):
        monkeypatch.setattr(curate_ops, "load_catalog", lambda: CATALOG)
        existing = {
            "albums": [
                {
                    "provider": "spotify",
                    "album_id": "p1",
                    "include": True,
                    "title": "kept",
                }
            ]
        }
        result = _inject_for_split_child(existing, CHILD)
        p1 = [a for a in result["albums"] if a["album_id"] == "p1"]
        assert len(p1) == 1 and p1[0]["include"] is True

    def test_a_series_that_is_not_a_child_is_left_alone(
        self, monkeypatch: pytest.MonkeyPatch
    ):
        monkeypatch.setattr(curate_ops, "load_catalog", lambda: CATALOG)
        assert _inject_for_split_child(None, PARENT) is None


def test_a_split_child_is_prepared_like_any_series(
    monkeypatch: pytest.MonkeyPatch, tmp_path
):
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    (tmp_path / "assets" / "catalog" / "curation").mkdir(parents=True)
    monkeypatch.setattr(
        curate_ops, "lookup_catalog_entry", lambda q: CHILD if q == CHILD.id else None
    )
    prepared = prepare_curation(CHILD.id)
    assert prepared.entry is CHILD


class TestParentJudgementStands:
    """What the parent's page already rejected is not re-judged in a
    child's run.

    The Wieso? Weshalb? Warum? Vorlesegeschichten child (2026-09-06)
    re-decided the parent's 230 excluded albums, took 29 minutes and
    1.2M tokens for a three-album line, and included 14 old packaging
    variants the parent had excluded as duplicates. An album the parent
    excluded for a reason of its own arrives in the child excluded as
    bleed; only what the parent handed away as sub_series_bleed is the
    child's to decide.
    """

    def test_parent_rejects_arrive_as_bleed_and_handed_away_albums_stay_open(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path
    ):
        monkeypatch.setattr(curate_ops, "load_catalog", lambda: CATALOG)
        parent_curation = tmp_path / "lego_ninjago.json"
        parent_curation.write_text(
            json.dumps(
                {
                    "albums": [
                        {
                            "provider": "spotify",
                            "album_id": "dup",
                            "title": "Folge 1: A (Hörspiel)",
                            "include": False,
                            "exclude_reason": "duplicate",
                            "release_date": "2021-01-01",
                        },
                        {
                            "provider": "spotify",
                            "album_id": "handed",
                            "title": "Zane (Band 17)",
                            "include": False,
                            "exclude_reason": "sub_series_bleed",
                        },
                    ]
                }
            )
        )
        monkeypatch.setattr(
            curate_ops,
            "curation_path",
            lambda sid: (
                parent_curation if sid == "lego_ninjago" else tmp_path / f"{sid}.json"
            ),
        )
        result = _inject_for_split_child(None, CHILD)
        by = {a["album_id"]: a for a in result["albums"]}
        assert by["dup"]["include"] is False
        assert by["dup"]["exclude_reason"] == "sub_series_bleed"
        assert (
            "duplicate" in by["dup"]["notes"] and "lego_ninjago" in by["dup"]["notes"]
        )
        assert "handed" not in by
