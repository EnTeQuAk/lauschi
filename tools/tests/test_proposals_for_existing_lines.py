"""A finalize proposal for a line that already is a split-off child is
dropped: the child entry is the fact. So is a fact the prior curation
carries for such a line, and the regression check does not count it as
lost.

The Wieso? Weshalb? Warum? re-curation (2026-09-06) proposed junior and
erstleser as sub-series although both children exist and their albums
were pre-excluded from the parent's page as bleed. Accepting would fail
on the existing id, listing them clogs the review queue.
"""

from lauschi_catalog.catalog.curate_ops import (
    _drop_proposals_for_existing_lines,
    _regression_baseline,
)
from lauschi_catalog.catalog.facts import SeriesFacts, SubSeriesFact
from lauschi_catalog.catalog.lint_ops import lint_regression
from lauschi_catalog.catalog.models import CatalogEntry

PARENT = CatalogEntry(id="wieso_weshalb_warum", title="Wieso? Weshalb? Warum?")
JUNIOR = CatalogEntry(
    id="wieso_weshalb_warum_junior", title="Junior", split_from="wieso_weshalb_warum"
)
CATALOG = [PARENT, JUNIOR]


def _facts(*labels: str) -> SeriesFacts:
    return SeriesFacts(
        sub_series=[
            SubSeriesFact(
                label=lb, album_ids=["spotify:x"], reason="r", curated_by="curate"
            )
            for lb in labels
        ]
    )


def test_a_proposal_naming_an_existing_child_is_dropped():
    log: list[str] = []
    kept = _drop_proposals_for_existing_lines(
        _facts("junior", "profiwissen"), PARENT, CATALOG, log.append
    )
    assert [s.label for s in kept.sub_series] == ["profiwissen"]
    assert "wieso_weshalb_warum_junior" in "".join(log)


def test_a_child_run_drops_a_proposal_naming_a_sibling():
    kept = _drop_proposals_for_existing_lines(
        _facts("junior"),
        CatalogEntry(
            id="wieso_weshalb_warum_erstleser",
            title="E",
            split_from="wieso_weshalb_warum",
        ),
        CATALOG
        + [
            CatalogEntry(
                id="wieso_weshalb_warum_erstleser",
                title="E",
                split_from="wieso_weshalb_warum",
            )
        ],
        lambda _m: None,
    )
    assert kept.sub_series == []


def test_no_proposals_and_no_entry_pass_through():
    assert (
        _drop_proposals_for_existing_lines(None, PARENT, CATALOG, lambda _m: None)
        is None
    )
    facts = _facts("junior")
    assert (
        _drop_proposals_for_existing_lines(facts, None, CATALOG, lambda _m: None)
        is facts
    )


def test_a_proposal_whose_albums_all_sit_in_a_child_is_dropped(monkeypatch):
    """The child may carry a different id than the label suggests
    (meine_vorlesegeschichten vs wieso_weshalb_warum_vorlesegeschichten);
    its albums are the fact then."""
    from lauschi_catalog.catalog import curate_ops

    child = CatalogEntry(
        id="wieso_weshalb_warum_vorlesegeschichten",
        title="V",
        split_from="wieso_weshalb_warum",
    )
    monkeypatch.setattr(
        curate_ops,
        "_child_album_records",
        lambda entry: [("spotify", "x", "t")] if entry.id == child.id else [],
    )
    kept = _drop_proposals_for_existing_lines(
        _facts("meine_vorlesegeschichten"), PARENT, CATALOG + [child], lambda _m: None
    )
    assert kept.sub_series == []


def test_carried_proposals_are_filtered_like_new_ones():
    """The prior curation carries its proposals forward as facts; a
    proposal that became a child in between is dropped from those too."""
    log: list[str] = []
    kept = _drop_proposals_for_existing_lines(
        _facts("junior"), PARENT, CATALOG, log.append
    )
    assert kept.sub_series == [] and log


def test_a_fact_that_became_an_entry_is_not_reported_as_lost():
    """The run drops the prior curation's fact for a line that has its
    own entry now, so the fact moved, it was not lost. The facts-lost
    gate read it as a wipe and escalated Feuerwehrmann Sam once its film
    line had an entry."""
    previous = {"albums": [], "series_facts": _facts("junior").model_dump()}
    current = {"albums": [], "series_facts": SeriesFacts().model_dump()}

    baseline = _regression_baseline(previous, PARENT, CATALOG)

    assert lint_regression(baseline, current) == []


def test_a_fact_the_run_keeps_still_counts_as_lost():
    previous = {"albums": [], "series_facts": _facts("profiwissen").model_dump()}
    current = {"albums": [], "series_facts": SeriesFacts().model_dump()}

    baseline = _regression_baseline(previous, PARENT, CATALOG)

    assert any("series_facts lost" in f for f in lint_regression(baseline, current))


def test_a_line_with_its_own_artist_page_still_counts_as_existing():
    """wieso_weshalb_warum_junior has its own artist ids, so it is not a
    split child, yet the parent's page carries Junior albums and the
    finalize keeps proposing the line. The entry exists; that is enough."""
    own_page = CatalogEntry(id="wieso_weshalb_warum_junior", title="Junior")
    kept = _drop_proposals_for_existing_lines(
        _facts("junior"), PARENT, [PARENT, own_page], lambda _m: None
    )
    assert kept.sub_series == []
