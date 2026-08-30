"""AlbumDecision must never carry free text in exclude_reason."""

import pytest

from lauschi_catalog.catalog.curate_ops import AlbumDecision


def test_excluded_album_without_reason_gets_the_catch_all() -> None:
    """An excluded album with no reason at all and no notes gets
    'unspecified'."""
    d = AlbumDecision(
        album_id="x",
        provider="spotify",
        include=False,
        title="T",
        episode_num=None,
        confidence="high",
    )
    assert d.exclude_reason == "unspecified"


def test_notes_are_never_copied_into_exclude_reason() -> None:
    """Free-text notes describe *why* the agent is unsure; they are not
    one of the enum values. Copying them into exclude_reason used to
    bypass the Literal because the write happened inside a model
    validator, which pydantic does not re-validate."""
    d = AlbumDecision(
        album_id="x",
        provider="spotify",
        include=False,
        title="T",
        episode_num=None,
        confidence="medium",
        notes="Wrong content type: audiobook",
    )
    assert d.exclude_reason != d.notes
    assert d.exclude_reason == "unspecified"
    assert d.notes == "Wrong content type: audiobook"


def test_bogus_enum_value_raises() -> None:
    """The prompt asks for exact enum values; a value outside the
    Literal must fail validation so the model retries with a valid one."""
    with pytest.raises(Exception):
        AlbumDecision(
            album_id="x",
            provider="spotify",
            include=False,
            title="T",
            episode_num=None,
            exclude_reason="compilation_set",
        )


def test_valid_reason_still_validates() -> None:
    d = AlbumDecision(
        album_id="x",
        provider="spotify",
        include=False,
        title="T",
        episode_num=None,
        exclude_reason="wrong_content_type",
        notes="Audiobook reading under a Hörspiel artist",
        confidence="high",
    )
    assert d.exclude_reason == "wrong_content_type"


def test_unspecified_is_a_valid_enum_value() -> None:
    d = AlbumDecision(
        album_id="x",
        provider="spotify",
        include=False,
        title="T",
        episode_num=None,
        exclude_reason="unspecified",
        notes="Could not classify",
        confidence="medium",
    )
    assert d.exclude_reason == "unspecified"
