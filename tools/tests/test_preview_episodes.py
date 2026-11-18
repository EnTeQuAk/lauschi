"""The series preview lists every included release once.

Numbered albums group by their number, so a story both stores ship is one
row with two store icons. An unnumbered album (a music release, a film, a
reading) has no number to group by, and grouping it under "no number"
showed a single row for a whole music artist.
"""

from typing import Any

from lauschi_catalog.web.routes.catalog import group_preview_episodes


def _album(
    album_id: str,
    provider: str,
    title: str,
    episode_num: int | None = None,
    release_date: str = "",
    *,
    include: bool = True,
) -> dict[str, Any]:
    return {
        "album_id": album_id,
        "provider": provider,
        "title": title,
        "episode_num": episode_num,
        "release_date": release_date,
        "include": include,
    }


def test_unnumbered_releases_each_get_a_row() -> None:
    rows = group_preview_episodes(
        [
            _album("sp1", "spotify", "Unperfekt", release_date="2024-02-09"),
            _album(
                "ap1", "apple_music", "Unperfekt - Single", release_date="2024-02-09"
            ),
            _album("sp2", "spotify", "So Jung", release_date="2024-03-08"),
            _album("ap2", "apple_music", "So Jung - Single", release_date="2024-03-08"),
            _album("sp3", "spotify", "Wut", release_date="2025-04-11"),
        ]
    )

    assert [(r["title"], [p["name"] for p in r["providers"]]) for r in rows] == [
        ("Unperfekt", ["apple_music", "spotify"]),
        ("So Jung", ["apple_music", "spotify"]),
        ("Wut", ["spotify"]),
    ]


def test_numbered_episodes_come_first_in_number_order() -> None:
    rows = group_preview_episodes(
        [
            _album("sp9", "spotify", "Ein Film", release_date="2020-01-01"),
            _album("sp2", "spotify", "Folge 2: B", 2),
            _album("ap1", "apple_music", "Folge 1: A - EP", 1),
            _album("sp1", "spotify", "Folge 1: A", 1),
        ]
    )

    assert [(r["episode_num"], r["title"], len(r["providers"])) for r in rows] == [
        (1, "Folge 1: A - EP", 2),
        (2, "Folge 2: B", 1),
        (None, "Ein Film", 1),
    ]


def test_excluded_albums_are_left_out() -> None:
    rows = group_preview_episodes(
        [
            _album("sp1", "spotify", "Hallo Angst", include=False),
            _album("sp2", "spotify", "Unperfekt"),
        ]
    )

    assert [r["title"] for r in rows] == ["Unperfekt"]
