"""Pins for the shared helpers that replaced per-module copies."""

from __future__ import annotations

from lauschi_catalog.catalog.canonical import album_sort_key


def _album(ep, release_date="2020-01-01", title="Folge 1"):
    return {"episode_num": ep, "release_date": release_date, "title": title}


class TestAlbumSortKey:
    def test_orders_by_episode_number(self):
        albums = [_album(3), _album(1), _album(2)]
        assert [a["episode_num"] for a in sorted(albums, key=album_sort_key)] == [
            1,
            2,
            3,
        ]

    def test_episode_less_albums_sort_last(self):
        albums = [_album(None, title="Special"), _album(2), _album(1)]
        ordered = sorted(albums, key=album_sort_key)
        assert ordered[-1]["title"] == "Special"

    def test_ties_break_on_release_date_then_title(self):
        older = _album(1, release_date="2019-01-01", title="A")
        newer_same_title = _album(1, release_date="2021-01-01", title="A")
        other_title = _album(1, release_date="2021-01-01", title="B")
        albums = [newer_same_title, other_title, older]
        assert sorted(albums, key=album_sort_key) == [
            older,
            newer_same_title,
            other_title,
        ]

    def test_all_episode_less_albums_still_order_by_date_and_title(self):
        a = _album(None, release_date="2019-01-01", title="ZZZ")
        b = _album(None, release_date="2021-01-01", title="AAA")
        c = _album(None, release_date="2021-01-01", title="BBB")
        albums = [c, a, b]
        assert sorted(albums, key=album_sort_key) == [a, b, c]

    def test_matches_the_display_order_curate_used_to_inline(self):
        """The exact tuple identity: (ep is None, ep, release_date, title)."""
        album = {"episode_num": 7, "release_date": "2020-05-05", "title": "Folge 7"}
        expected = (
            album["episode_num"] is None,
            album["episode_num"],
            album["release_date"] or "",
            album["title"],
        )
        assert album_sort_key(album) == expected
