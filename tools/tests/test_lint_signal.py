"""Lint findings feed the audit prompt, so they must be signal.

On 2026-10-03 three rules flooded it: [fragment_included] read
"Folge 10" as a fragment of an excluded album titled just "Folge 1"
(93 lines on Leo Lausemaus), and [split_cluster] / [title_counterpart]
reported rows another series owns on a shared family page, which code
routed and that series' own audit reviews.
"""

from lauschi_catalog.catalog.lint_ops import lint_curation


def _a(
    album_id: str,
    title: str,
    *,
    include: bool,
    provider: str = "apple_music",
    reason: str | None = None,
    notes: str = "",
    ep: int | None = None,
) -> dict:
    return {
        "album_id": album_id,
        "provider": provider,
        "title": title,
        "include": include,
        "exclude_reason": reason,
        "notes": notes,
        "episode_num": ep,
    }


def _kinds(issues: list[str], kind: str) -> list[str]:
    return [i for i in issues if i.startswith(kind)]


def test_a_longer_episode_number_is_not_a_fragment() -> None:
    issues = lint_curation(
        {
            "id": "leo",
            "albums": [
                _a("x", "Folge 1", include=False, reason="sub_series_bleed"),
                _a("y", "Folge 10: Babysitter? Nein Danke! - EP", include=True, ep=10),
            ],
        }
    )
    assert _kinds(issues, "[fragment_included]") == []


def test_a_real_fragment_is_still_reported() -> None:
    issues = lint_curation(
        {
            "id": "playmos",
            "albums": [
                _a(
                    "full",
                    "Folge 100: Der magische Ring",
                    include=False,
                    reason="unspecified",
                ),
                _a(
                    "part",
                    "Folge 100: Der magische Ring - Episode 1",
                    include=True,
                    ep=100,
                ),
            ],
        }
    )
    assert len(_kinds(issues, "[fragment_included]")) == 1


def test_rows_another_series_owns_make_no_cluster_or_counterpart_findings() -> None:
    owned = "Belongs to 'benjamin_bluemchen'"
    issues = lint_curation(
        {
            "id": "benjamin_bluemchen_minis",
            "albums": [
                _a("m1", "Folge 1: Benjamin hilft", include=True, ep=1),
                _a(
                    "p2",
                    "Folge 2: Benjamin als Koch",
                    include=False,
                    reason="sub_series_bleed",
                    notes=owned,
                ),
                _a(
                    "p1",
                    "Folge 1: Benjamin hilft",
                    include=False,
                    provider="spotify",
                    reason="sub_series_bleed",
                    notes=owned,
                ),
            ],
        }
    )
    assert _kinds(issues, "[split_cluster]") == []
    assert _kinds(issues, "[title_counterpart]") == []


def test_a_sub_line_split_the_series_decided_itself_is_still_reported() -> None:
    """Bibi Blocksberg's Kartoffelbrei parts 1-4 in, 5-11 out as a
    sub-series is what the cluster rule exists for."""
    issues = lint_curation(
        {
            "id": "bibi_blocksberg",
            "albums": [
                _a("k1", "Kampf um Kartoffelbrei (Special) - Teil 1", include=True),
                _a(
                    "k5",
                    "Kampf um Kartoffelbrei (Special) - Teil 5",
                    include=False,
                    reason="sub_series_bleed",
                ),
            ],
        }
    )
    assert len(_kinds(issues, "[split_cluster]")) == 1
