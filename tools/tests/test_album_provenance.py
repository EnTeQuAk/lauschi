"""Per-album provenance: decided_by and decided_at on album decisions.

Every album decision should trace back to who made it (the model, the
reconciler, the operator, the split-routing logic, etc.) and when.
"""

from lauschi_catalog.catalog.curate_ops import AlbumDecision, album_provenance
from lauschi_catalog.catalog.lint_ops import lint_provenance_flips
from lauschi_catalog.catalog.reconcile import reconcile_cross_provider
from tests.factories import album_record

# -- AlbumDecision model ---------------------------------------------------


def test_album_decision_defaults():
    d = AlbumDecision(
        album_id="a1",
        provider="spotify",
        include=True,
        episode_num=1,
        title="Folge 1",
    )
    assert d.decided_by == "unknown"
    assert d.decided_at is None


def test_album_decision_serializes_provenance():
    d = AlbumDecision(
        album_id="a1",
        provider="spotify",
        include=True,
        episode_num=1,
        title="Folge 1",
        decided_by="kimi-k2.6",
        decided_at="2026-09-20T12:00:00+00:00",
    )
    dump = d.model_dump()
    assert dump["decided_by"] == "kimi-k2.6"
    assert dump["decided_at"] == "2026-09-20T12:00:00+00:00"


def testalbum_provenance_helper():
    prov = album_provenance("route")
    assert prov["decided_by"] == "route"
    assert prov["decided_at"] is not None


# -- Preseed preserves provenance ------------------------------------------


def test_preseed_preserves_existing_provenance():
    from lauschi_catalog.catalog.curate_ops import _preseed_decisions

    albums = [{"provider": "spotify", "id": "a1", "name": "Folge 1"}]
    existing = {
        "albums": [
            album_record(
                "a1",
                include=True,
                episode_num=1,
                decided_by="operator",
                decided_at="2026-09-01T10:00:00+00:00",
            )
        ]
    }
    carried, remaining = _preseed_decisions(albums, existing)
    assert len(carried) == 1
    assert carried[0].decided_by == "operator"
    assert carried[0].decided_at == "2026-09-01T10:00:00+00:00"
    assert remaining == []


def test_preseed_defaults_for_pre_t11_data():
    from lauschi_catalog.catalog.curate_ops import _preseed_decisions

    albums = [{"provider": "spotify", "id": "a1", "name": "Folge 1"}]
    existing = {
        "albums": [
            {
                "album_id": "a1",
                "provider": "spotify",
                "include": True,
                "episode_num": 1,
                "title": "Folge 1",
            }
        ]
    }
    carried, _ = _preseed_decisions(albums, existing)
    assert carried[0].decided_by == "unknown"
    assert carried[0].decided_at is None


# -- Reconcile stamps provenance ------------------------------------------


def test_reconcile_stamps_provenance():
    albums = [
        album_record("sp1", provider="spotify", include=True, title="Folge 1"),
        album_record(
            "am1",
            provider="apple_music",
            include=False,
            title="Folge 1",
            exclude_reason="wrong_content_type",
        ),
    ]
    result = reconcile_cross_provider(albums)
    assert result.flipped == 1
    assert albums[1]["decided_by"] == "reconcile"
    assert albums[1]["decided_at"] is not None


# -- lint_provenance_flips -------------------------------------------------


def test_lint_catches_operator_flipped_by_model():
    prev = {
        "albums": [
            album_record("a1", include=True, decided_by="operator"),
        ]
    }
    current = {
        "albums": [
            album_record("a1", include=False, decided_by="kimi-k2.6"),
        ]
    }
    issues = lint_provenance_flips(prev, current)
    assert len(issues) == 1
    assert "[provenance_flip]" in issues[0]
    assert "operator" not in issues[0].split("by ")[-1] or "kimi" in issues[0]


def test_lint_ignores_model_flipped_by_model():
    prev = {
        "albums": [
            album_record("a1", include=True, decided_by="kimi-k2.6"),
        ]
    }
    current = {
        "albums": [
            album_record("a1", include=False, decided_by="kimi-k2.6"),
        ]
    }
    issues = lint_provenance_flips(prev, current)
    assert issues == []


def test_lint_ignores_operator_flipped_by_operator():
    prev = {
        "albums": [
            album_record("a1", include=True, decided_by="operator"),
        ]
    }
    current = {
        "albums": [
            album_record("a1", include=False, decided_by="operator"),
        ]
    }
    issues = lint_provenance_flips(prev, current)
    assert issues == []


def test_lint_no_previous_returns_empty():
    current = {"albums": [album_record("a1", include=True)]}
    assert lint_provenance_flips(None, current) == []


def test_lint_same_include_no_flip():
    prev = {
        "albums": [
            album_record("a1", include=True, decided_by="operator"),
        ]
    }
    current = {
        "albums": [
            album_record("a1", include=True, decided_by="kimi-k2.6"),
        ]
    }
    issues = lint_provenance_flips(prev, current)
    assert issues == []
