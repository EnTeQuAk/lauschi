"""A split-off child is curated for its own line, and inherits nothing.

Split-off entries share their artist pages with the parent, so a child's
run sees the whole family's discography. It decides each album on one
question, is this my line, and everything else is sub_series_bleed for
the root, which owns what nobody claims (2026-10-09, Chris). The child
used to inherit the parent's and siblings' albums and rejects, and lost
its own line whenever the parent had excluded it: Hexe Lilli
Erstlesergeschichten, Ninjago Band 13 and 17-20, Lauras Stern 10 shipped
nowhere. Only the child's own applied albums still arrive, included with
their numbers, because they are its own content.
"""

import asyncio
import json

import pytest

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import _inject_for_split_child, prepare_curation
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from tests.factories import decision


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

    def test_own_albums_arrive_included_and_nothing_of_the_family(
        self, monkeypatch: pytest.MonkeyPatch
    ):
        monkeypatch.setattr(curate_ops, "load_catalog", lambda: CATALOG)
        result = _inject_for_split_child(None, CHILD)
        by = {a["album_id"]: a for a in result["albums"]}
        assert by["h1"]["include"] is True and by["h1"]["episode_num"] == 16
        assert set(by) == {"h1"}

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

    @pytest.mark.parametrize("reason", ["music_single", "sub_series_bleed"])
    def test_a_carried_exclusion_stays_the_childs_own(
        self, monkeypatch: pytest.MonkeyPatch, reason: str
    ):
        """A sibling shipping the album does not make the child's own
        call about it the sibling's."""
        monkeypatch.setattr(curate_ops, "load_catalog", lambda: CATALOG)
        carried = {
            "provider": "spotify",
            "album_id": "k1",
            "title": "Der Film",
            "include": False,
            "exclude_reason": reason,
        }
        result = _inject_for_split_child({"albums": [dict(carried)]}, CHILD)
        (k1,) = [a for a in result["albums"] if a["album_id"] == "k1"]
        assert k1 == carried

    def test_a_child_run_keeps_its_own_albums_when_the_prior_lacks_them(
        self, monkeypatch: pytest.MonkeyPatch
    ):
        """curate_one injects a parent's children before a child's facts.
        For a child, the first step has no children to add. It once added
        every sibling, the child itself included, so an own album the
        prior curation lacked (a provider lost to a 429) arrived as bleed
        "belonging to" the child and was carried forward excluded."""
        monkeypatch.setattr(curate_ops, "load_catalog", lambda: CATALOG)
        existing = curate_ops._inject_split_children(None, CHILD.id)
        result = _inject_for_split_child(existing, CHILD)
        by = {a["album_id"]: a for a in result["albums"]}
        assert by["h1"]["include"] is True and by["h1"]["episode_num"] == 16

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


class TestTheChildDecidesItsLine:
    """What the parent rejected is not handed to the child either.

    The parent's rejects used to arrive in the child as bleed, because the
    Wieso? Weshalb? Warum? Vorlesegeschichten child (2026-09-06) re-decided
    the parent's 230 excluded albums and included 14 packaging variants
    the parent had excluded as duplicates. But the inherited rejects also
    took the child's own line away whenever the parent had excluded it.
    The child now judges every album against its own line; the batch
    prompt names that line and leaves anything in doubt to the root.
    """

    def test_parent_rejects_and_handed_away_albums_stay_for_the_child(
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
                        },
                        {
                            "provider": "spotify",
                            "album_id": "band13",
                            "title": "Kai (Band 13)",
                            "include": False,
                            "exclude_reason": "wrong_content_type",
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
        assert {a["album_id"] for a in result["albums"]} == {"h1"}


class TestParentClaimsForItsChildren:
    """The parent's side of the owner claim. Wieso? Weshalb? Warum?
    kept 181 ownerless exclusions of its JUNIOR and Erstleser albums
    after both became split children (2026-09-30), because the parent's
    injection skipped every album its prior curation already had."""

    @pytest.fixture(autouse=True)
    def _catalog(self, monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
        monkeypatch.setattr(curate_ops, "load_catalog", lambda: CATALOG)
        monkeypatch.setattr(
            curate_ops, "curation_path", lambda sid: tmp_path / f"{sid}.json"
        )

    def test_a_childs_current_curation_is_its_claim(self, tmp_path) -> None:
        """The children curate before the parent, so the parent takes what
        they claim now, not what series.yaml shipped at the last apply:
        a new line album the child took is the child's, and an album it
        gave back is the parent's to decide again."""
        (tmp_path / "lego_ninjago_hoerbuch.json").write_text(
            json.dumps(
                {
                    "albums": [
                        {
                            "provider": "spotify",
                            "album_id": "h13",
                            "title": "Kai (Band 13)",
                            "include": True,
                        },
                        {
                            "provider": "spotify",
                            "album_id": "h1",
                            "title": "Zane (Band 16)",
                            "include": False,
                            "exclude_reason": "duplicate",
                        },
                    ]
                }
            )
        )
        result = curate_ops._inject_split_children(None, PARENT.id)
        by = {a["album_id"]: a for a in result["albums"]}
        assert curate_ops.bleed_owner(by["h13"]["notes"]) == "lego_ninjago_hoerbuch"
        assert "h1" not in by
        # a child with no curation yet still claims what it ships
        assert curate_ops.bleed_owner(by["k1"]["notes"]) == "lego_ninjago_kinofilm"

    def test_an_album_a_child_gave_back_is_decided_again(self, tmp_path) -> None:
        """The parent's prior curation still says the album belongs to the
        child. Carried forward, nobody would ship it."""
        (tmp_path / "lego_ninjago_hoerbuch.json").write_text(json.dumps({"albums": []}))
        existing = {
            "albums": [
                {
                    "provider": "spotify",
                    "album_id": "h1",
                    "title": "Zane (Band 16)",
                    "include": False,
                    "exclude_reason": "sub_series_bleed",
                    "notes": "Belongs to split series 'lego_ninjago_hoerbuch'",
                },
                {
                    "provider": "spotify",
                    "album_id": "op",
                    "title": "Kept by hand",
                    "include": False,
                    "exclude_reason": "sub_series_bleed",
                    "notes": "Belongs to 'lego_ninjago_hoerbuch'",
                    "decided_by": "operator",
                },
            ]
        }
        result = curate_ops._inject_split_children(existing, PARENT.id)
        ids = {a["album_id"] for a in result["albums"]}
        assert "h1" not in ids
        assert "op" in ids

    @pytest.mark.parametrize(
        ("carried", "owner"),
        [
            (
                {"include": False, "exclude_reason": "sub_series_bleed"},
                "lego_ninjago_hoerbuch",
            ),
            (
                {"include": False, "exclude_reason": "music_single"},
                "lego_ninjago_hoerbuch",
            ),
            ({"include": True}, None),
            (
                {
                    "include": False,
                    "exclude_reason": "duplicate",
                    "decided_by": "operator",
                },
                None,
            ),
        ],
    )
    def test_a_carried_exclusion_of_a_childs_album_names_the_child(
        self, carried: dict, owner: str | None
    ) -> None:
        existing = {
            "albums": [
                {"provider": "spotify", "album_id": "h1", "title": "Zane (Band 16)"}
                | carried
            ]
        }
        result = curate_ops._inject_split_children(existing, PARENT.id)
        (h1,) = [a for a in result["albums"] if a["album_id"] == "h1"]
        assert curate_ops.bleed_owner(h1.get("notes")) == owner


class TestUnclaimedIsTheRoots:
    """What a child calls not its line belongs to the family root, which
    owns whatever no member claims. Named as such, the child's audit and
    lint leave it to the root's curation, where it is decided and audited,
    instead of reviewing the whole shared page a second time."""

    def test_a_childs_ownerless_bleed_names_the_root(self) -> None:
        decisions = [
            decision(
                "p9",
                include=False,
                exclude_reason="sub_series_bleed",
                notes="Main series episode, not a Hörbuch",
            ),
            decision(
                "k1",
                include=False,
                exclude_reason="sub_series_bleed",
                notes="Belongs to 'lego_ninjago_kinofilm'",
            ),
            decision("x1", include=False, exclude_reason="music_single"),
            decision("h13", include=True, episode_num=13),
        ]

        assert curate_ops._name_root_as_owner(decisions, CHILD) == 1

        by = {d.album_id: d for d in decisions}
        assert curate_ops.bleed_owner(by["p9"].notes) == "lego_ninjago"
        assert "Main series episode" in by["p9"].notes
        assert curate_ops.bleed_owner(by["k1"].notes) == "lego_ninjago_kinofilm"
        assert by["x1"].notes is None

    def test_the_root_keeps_its_ownerless_bleed_for_a_split_proposal(self) -> None:
        d = decision("new", include=False, exclude_reason="sub_series_bleed")
        assert curate_ops._name_root_as_owner([d], PARENT) == 0
        assert curate_ops.bleed_owner(d.notes) is None


def test_children_curate_before_their_root() -> None:
    """The root takes its children's claims from their curations, so in
    a full run every child is curated first."""
    loner = CatalogEntry(id="tkkg", title="TKKG", providers={})
    ordered = curate_ops.children_first([PARENT, loner, CHILD, OTHER])
    assert [e.id for e in ordered] == [
        "lego_ninjago_hoerbuch",
        "lego_ninjago_kinofilm",
        "lego_ninjago",
        "tkkg",
    ]


def test_a_childs_batch_prompt_names_its_line() -> None:
    prompt = curate_ops.build_batch_prompt(
        series_title="LEGO Ninjago: Hörbücher",
        pattern=None,
        progress_text="",
        rolling="",
        structural_hints=[],
        sibling_titles=["LEGO Ninjago"],
        batch_num=1,
        n_batches=1,
        n_albums=1,
        albums_xml="<albums/>",
        line_of="LEGO Ninjago",
    )
    assert "a line split off from 'LEGO Ninjago'" in prompt


@pytest.mark.anyio
async def test_a_full_run_finishes_every_child_before_a_root_starts(
    monkeypatch: pytest.MonkeyPatch, tmp_path
) -> None:
    """Two series run at once, so ordering the list is not enough: the
    last child and its root would overlap and the root would read a
    curation that is still being written."""
    loner = CatalogEntry(id="tkkg", title="TKKG", providers={})
    monkeypatch.setattr(
        curate_ops, "load_catalog", lambda: [PARENT, loner, CHILD, OTHER]
    )
    monkeypatch.setattr(
        curate_ops, "curation_path", lambda sid: tmp_path / f"{sid}.json"
    )
    monkeypatch.setattr(
        curate_ops,
        "prepare_curation",
        lambda entry: curate_ops.CurateEntryPrepared(
            entry=entry, requested_type="hoerspiel"
        ),
    )
    monkeypatch.setattr(curate_ops, "record_event", lambda event: None)
    log: list[str] = []

    async def fake_curate_entry(prepared, providers, **kw):
        log.append(f"start {prepared.entry.id}")
        # one child finishes at once, the other is still running when a
        # free slot would let the root start
        await asyncio.sleep(0.05 if prepared.entry.id == OTHER.id else 0)
        log.append(f"end {prepared.entry.id}")
        return curate_ops.CurateOneResult()

    monkeypatch.setattr(curate_ops, "curate_entry", fake_curate_entry)

    await curate_ops.curate_all([], force=True, concurrency=2)

    last_child_end = max(
        log.index(f"end {c}")
        for c in ("lego_ninjago_hoerbuch", "lego_ninjago_kinofilm")
    )
    assert log.index("start lego_ninjago") > last_child_end


class TestAClaimNeedsCertainty:
    """A child's claim takes the album from the root, so it needs the
    model's full confidence. Lauras Stern: Laura took a Christmas
    Sonderband the main series ships, at medium confidence and with the
    note "part of the main Hörspiel line". Doubt goes to the root, which
    owns what no line claims and loses nothing by keeping it."""

    def _unsure(self, album_id: str, **kw) -> "curate_ops.AlbumDecision":
        d = decision(
            album_id,
            include=True,
            confidence="medium",
            notes="Sonderband, part of the main line",
            **kw,
        )
        d.decided_by = "kimi-k2.6"
        return d

    def test_an_unsure_claim_is_left_to_the_root(self) -> None:
        d = self._unsure("sonderband", title="Sonderband: Weihnachten")

        left = curate_ops._leave_doubt_to_root([d], CHILD)

        assert left == [d]
        assert (d.include, d.exclude_reason) == (False, "sub_series_bleed")
        assert d.episode_num is None
        assert "part of the main line" in d.notes
        assert d.decided_by == "split"

    def test_a_confident_claim_stays(self) -> None:
        d = decision("band13", include=True, episode_num=13, title="Kai (Band 13)")
        d.decided_by = "kimi-k2.6"

        assert curate_ops._leave_doubt_to_root([d], CHILD) == []
        assert d.include is True

    def test_an_album_the_child_already_ships_is_its_own(self) -> None:
        """An old run's medium confidence must not take a shipped album
        away from the line it ships in."""
        d = self._unsure("h1", title="Zane (Band 16)", episode_num=16)

        assert curate_ops._leave_doubt_to_root([d], CHILD) == []
        assert d.include is True

    def test_an_operators_include_stays(self) -> None:
        d = self._unsure("by_hand")
        d.decided_by = "operator"

        assert curate_ops._leave_doubt_to_root([d], CHILD) == []
        assert d.include is True

    def test_the_root_keeps_its_unsure_includes(self) -> None:
        """For the root the inclusion bias holds: in doubt, include."""
        d = self._unsure("special")

        assert curate_ops._leave_doubt_to_root([d], PARENT) == []
        assert d.include is True


class TestTheSameTitleIsOneLine:
    """Hexe Lilli Erstlesergeschichten took four titles on Spotify and
    called the same four not its line on Apple Music. The root would have
    taken the Apple Music albums, and one title would ship in two series
    depending on the provider. A claim on one provider is evidence for
    the other, the way a twin already supplies an episode number."""

    def _pair(self, **bleed_kw) -> tuple:
        claimed = decision(
            "sp1",
            provider="spotify",
            include=True,
            title="Hexe Lilli und der kleine Delfin",
            release_date="2015-11-06",
        )
        other = decision(
            "am1",
            provider="apple_music",
            include=False,
            exclude_reason="sub_series_bleed",
            title="Hexe Lilli und der kleine Delfin",
            release_date="2015-11-06",
            **bleed_kw,
        )
        return claimed, other

    def test_the_twin_of_a_claimed_title_is_claimed_too(self) -> None:
        claimed, other = self._pair(notes="Main series double-story album")

        assert curate_ops._claim_twins([claimed, other], CHILD, ["Hexe Lilli"]) == 1

        assert other.include is True and other.exclude_reason is None
        assert other.decided_by == "split"

    def test_a_twin_another_member_owns_stays_theirs(self) -> None:
        claimed, other = self._pair(notes="Belongs to 'lego_ninjago_kinofilm'")

        assert curate_ops._claim_twins([claimed, other], CHILD, ["Hexe Lilli"]) == 0
        assert other.include is False

    def test_an_operators_exclusion_stays(self) -> None:
        claimed, other = self._pair()
        other.decided_by = "operator"

        assert curate_ops._claim_twins([claimed, other], CHILD, ["Hexe Lilli"]) == 0
        assert other.include is False

    def test_a_different_release_is_no_twin(self) -> None:
        claimed, other = self._pair()
        other.release_date = "2021-03-01"

        assert curate_ops._claim_twins([claimed, other], CHILD, ["Hexe Lilli"]) == 0
        assert other.include is False

    def test_the_root_claims_no_twins(self) -> None:
        """The root's ownerless bleed is what a split proposal is made
        from, and its twin being included is a finding for lint."""
        claimed, other = self._pair()

        assert curate_ops._claim_twins([claimed, other], PARENT, ["Hexe Lilli"]) == 0
        assert other.include is False
