"""Pin the regression and sanity lints.

lint_regression compares a re-curation against the previous curation:
an include-collapse (one curate run stamped all of mama_sandy
music_single; another once scoped a mixed artist to Hörspiel only) or
a facts wipe must surface as CRITICAL so the audit gate can refuse
auto-approval. The sanity rules in lint_curation catch what models
reason about unreliably: future dates (models live at their training
cutoff) and year-capture episode numbers from over-broad regexes.
"""

from __future__ import annotations

from datetime import date

from lauschi_catalog.catalog.lint_ops import (
    critical_issues,
    lint_curation,
    lint_regression,
)


def _curation(albums, facts=None):
    return {"albums": albums, "series_facts": facts}


def _album(
    title="Folge 1: x",
    include=True,
    provider="spotify",
    ep=None,
    release_date="2020-01-01",
    reason=None,
    album_id="a1",
):
    return {
        "album_id": album_id,
        "provider": provider,
        "include": include,
        "episode_num": ep,
        "title": title,
        "release_date": release_date,
        "exclude_reason": reason,
        "confidence": "high",
    }


# -- lint_regression ------------------------------------------------------


def test_include_collapse_to_zero_is_critical():
    prev = _curation([_album() for _ in range(8)])
    cur = _curation([_album(include=False, reason="music_single") for _ in range(8)])
    issues = lint_regression(prev, cur)
    assert any("0 included" in i for i in critical_issues(issues))


def test_include_drop_over_half_is_critical():
    prev = _curation([_album(album_id=f"a{i}") for i in range(20)])
    cur = _curation(
        [_album(album_id=f"a{i}") for i in range(8)]
        + [
            _album(album_id=f"a{i}", include=False, reason="compilation")
            for i in range(8, 20)
        ],
    )
    issues = lint_regression(prev, cur)
    assert critical_issues(issues)


def test_modest_drop_is_fine():
    prev = _curation([_album(album_id=f"a{i}") for i in range(20)])
    cur = _curation([_album(album_id=f"a{i}") for i in range(15)])
    assert lint_regression(prev, cur) == []


def test_facts_wipe_is_critical():
    facts = {"known_gaps": [{"number": 19, "reason": "legal"}]}
    prev = _curation([_album()], facts=facts)
    cur = _curation([_album()], facts=None)
    issues = lint_regression(prev, cur)
    assert any("series_facts" in i for i in critical_issues(issues))


def test_no_previous_curation_no_issues():
    assert lint_regression(None, _curation([_album()])) == []


# -- new lint_curation sanity rules ---------------------------------------


def test_future_release_date_flagged():
    cur = _curation([_album(release_date="2027-01-01")])
    issues = lint_curation(cur, today=date(2026, 6, 11))
    assert any("future" in i.lower() for i in issues)


def test_past_release_date_not_flagged_as_future():
    cur = _curation([_album(release_date="2026-03-13")])
    issues = lint_curation(cur, today=date(2026, 6, 11))
    assert not any("future" in i.lower() for i in issues)


def test_episode_number_year_capture_flagged():
    cur = _curation([_album(ep=2025)])
    issues = lint_curation(cur)
    assert any("episode_num" in i for i in issues)


def test_title_counterpart_conflict_flagged():
    cur = _curation(
        [
            _album(title="Das grüne Album", provider="spotify"),
            _album(
                title="Das grüne Album - EP",
                provider="apple_music",
                include=False,
                reason="music_single",
                album_id="b1",
            ),
        ]
    )
    issues = lint_curation(cur)
    assert any("counterpart" in i.lower() for i in issues)


def test_duplicate_exclusion_is_not_a_counterpart_conflict():
    """'duplicate' asserts redundancy, not a content classification;
    flagging it would contradict Rule 5's properly-excluded convention."""
    cur = _curation(
        [
            _album(title="Ep 1", provider="spotify"),
            _album(
                title="Ep 1",
                provider="apple_music",
                include=False,
                reason="duplicate",
                album_id="b1",
            ),
        ]
    )
    issues = lint_curation(cur)
    assert not any("counterpart" in i.lower() for i in issues)


def test_properly_distinct_titles_no_counterpart_issue():
    cur = _curation(
        [
            _album(title="Folge 1: Der Anfang", provider="spotify"),
            _album(
                title="Intro Song",
                provider="apple_music",
                include=False,
                reason="music_single",
                album_id="b1",
            ),
        ]
    )
    issues = lint_curation(cur)
    assert not any("counterpart" in i.lower() for i in issues)
