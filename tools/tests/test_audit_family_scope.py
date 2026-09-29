"""An audit reviews what its series owns on a shared artist page.

Every member of a split family carries the whole page. The audit of
benjamin_bluemchen_tv_serie (5 own albums) listed all 567 rows and was
routed to the chunked audit. Rows another member owns were decided by
code from that member's applied albums and are audited there, so they
are summarized by owner instead of listed. Everything the series or
its model decided stays listed, ownerless bleed included: whether one
of those is really this series' episode is exactly what a child's
audit is for.
"""

from lauschi_catalog.catalog.audit_ops import audit_route, build_prompt, plan_chunks


def _row(album_id: str, *, include: bool, notes: str = "", reason: str = "") -> dict:
    return {
        "album_id": album_id,
        "provider": "spotify",
        "include": include,
        "episode_num": None,
        "title": f"Titel {album_id}",
        "exclude_reason": reason or None,
        "notes": notes,
        "confidence": "high",
    }


def _child(n_owned: int) -> dict:
    owned = [
        _row(
            f"p{i}",
            include=False,
            reason="sub_series_bleed",
            notes="Belongs to 'benjamin_bluemchen'",
        )
        for i in range(n_owned)
    ]
    return {
        "id": "benjamin_bluemchen_tv_serie",
        "title": "Benjamin Blümchen: TV-Serie",
        "split_from": "benjamin_bluemchen",
        "episode_pattern": None,
        "albums": [
            _row("own1", include=True),
            _row("stray", include=False, reason="sub_series_bleed"),
            _row(
                "sib",
                include=False,
                reason="sub_series_bleed",
                notes="Belongs to split series 'benjamin_bluemchen_minis'",
            ),
            *owned,
        ],
    }


def test_rows_another_member_owns_are_counted_not_listed():
    prompt = build_prompt(_child(3), [])
    assert "[spotify:own1]" in prompt
    assert "[spotify:stray]" in prompt
    assert "[spotify:p0]" not in prompt and "[spotify:sib]" not in prompt
    assert "benjamin_bluemchen: 3" in prompt
    assert "benjamin_bluemchen_minis: 1" in prompt


def test_a_child_is_told_what_it_owns_and_what_its_root_owns():
    prompt = build_prompt(_child(1), [])
    assert "moved from the parent's curation" not in prompt
    assert "belong to the family's root" in prompt


def test_a_child_with_a_large_family_page_routes_one_shot():
    assert audit_route(_child(800), []) == "one_shot"


def test_chunks_never_carry_rows_another_member_owns():
    chunks = plan_chunks(_child(800), [])
    listed = {a["album_id"] for c in chunks for a in c.albums}
    assert listed == {"own1", "stray"}
