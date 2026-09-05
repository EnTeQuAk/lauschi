"""Same-provider duplicates are settled by the era fact, not a year window.

The prompt used to say: within ~2 years it's a duplicate, 5+ years apart
it's a new era, and nothing about 2 to 5. Decided 2026-09-05 (D5): an
era_boundary fact is the authority. Same provider, same episode number,
same title with no era separating the two releases is a duplicate and
the newest wins; if an era fact separates them, both stay.
"""

from lauschi_catalog.catalog.curate_ops import (
    AlbumDecision,
    _settle_same_provider_duplicates,
)
from lauschi_catalog.catalog.facts import SeriesFacts


def _dec(album_id, title, date, *, provider="spotify", ep=12, include=True):
    return AlbumDecision(
        album_id=album_id,
        provider=provider,
        include=include,
        episode_num=ep,
        title=title,
        release_date=date,
        confidence="high",
    )


def _eras(*ranges):
    return SeriesFacts.model_validate(
        {
            "era_boundaries": [
                {"label": f"e{i}", "release_date_range": r, "curated_by": "curate"}
                for i, r in enumerate(ranges)
            ]
        }
    ).era_boundaries


class TestEraBoundaryContainsYear:
    def test_closed_and_open_ranges(self):
        closed, open_ = _eras("1980-1990", "2015-")
        assert closed.contains_year(1985)
        assert not closed.contains_year(1991)
        assert open_.contains_year(2030)
        assert not open_.contains_year(2014)


class TestSettleSameProviderDuplicates:
    def test_no_era_fact_means_duplicate_and_the_newest_wins(self):
        old = _dec("old", "Folge 12: Der Fluch", "1985-03-01")
        new = _dec("new", "Folge 12: Der Fluch", "2019-06-01")
        out = {d.album_id: d for d in _settle_same_provider_duplicates([old, new], [])}
        assert out["new"].include is True
        assert out["old"].include is False
        assert out["old"].exclude_reason == "duplicate"
        assert "new" in (out["old"].notes or "")

    def test_an_era_fact_separating_the_releases_keeps_both(self):
        old = _dec("old", "Folge 12: Der Fluch", "1985-03-01")
        new = _dec("new", "Folge 12: Der Fluch", "2019-06-01")
        out = _settle_same_provider_duplicates([old, new], _eras("1980-1990", "2015-"))
        assert all(d.include for d in out)

    def test_both_in_the_same_era_is_still_a_duplicate(self):
        a = _dec("a", "Folge 12: Der Fluch", "2016-01-01")
        b = _dec("b", "Folge 12: Der Fluch", "2019-01-01")
        out = {
            d.album_id: d
            for d in _settle_same_provider_duplicates([a, b], _eras("2015-"))
        }
        assert out["b"].include is True
        assert out["a"].include is False

    def test_different_titles_are_left_alone(self):
        a = _dec("a", "Folge 12: Der Fluch", "2016-01-01")
        b = _dec("b", "Folge 12: Die Rückkehr", "2019-01-01")
        assert all(d.include for d in _settle_same_provider_duplicates([a, b], []))

    def test_different_providers_are_not_duplicates(self):
        a = _dec("a", "Folge 12: Der Fluch", "2016-01-01", provider="spotify")
        b = _dec("b", "Folge 12: Der Fluch", "2019-01-01", provider="apple_music")
        assert all(d.include for d in _settle_same_provider_duplicates([a, b], []))

    def test_excluded_albums_do_not_compete(self):
        a = _dec("a", "Folge 12: Der Fluch", "2016-01-01", include=False)
        b = _dec("b", "Folge 12: Der Fluch", "2019-01-01")
        out = {d.album_id: d for d in _settle_same_provider_duplicates([a, b], [])}
        assert out["b"].include is True

    def test_order_and_untouched_albums_are_preserved(self):
        x = _dec("x", "Folge 1: Anfang", "2000-01-01", ep=1)
        old = _dec("old", "Folge 12: Der Fluch", "1985-03-01")
        new = _dec("new", "Folge 12: Der Fluch", "2019-06-01")
        out = _settle_same_provider_duplicates([x, old, new], [])
        assert [d.album_id for d in out] == ["x", "old", "new"]
        assert out[0] is x
