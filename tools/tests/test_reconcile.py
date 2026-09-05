"""Tests for cross-provider reconciliation and exclude_reason normalization."""

import pytest

from lauschi_catalog.catalog.reconcile import (
    normalize_exclude_reason,
    reconcile_cross_provider,
)
from tests.factories import album_record

# ── normalize_exclude_reason ────────────────────────────────────────────


class TestNormalizeExcludeReason:
    def test_known_reason_passes_through(self):
        assert normalize_exclude_reason("compilation") == "compilation"

    def test_none_stays_none(self):
        assert normalize_exclude_reason(None) is None

    def test_empty_stays_empty(self):
        assert normalize_exclude_reason("") == ""

    @pytest.mark.parametrize(
        "verbose,expected",
        [
            (
                "Music album (songs). exclude_reason: wrong_content_type",
                "wrong_content_type",
            ),
            (
                "Music album with karaoke tracks; not a Hörspiel. Exclude as wrong_content_type.",
                "wrong_content_type",
            ),
            (
                "Film soundtrack with karaoke versions; music album, not Hörspiel. Exclude as wrong_content_type.",
                "wrong_content_type",
            ),
            ("Single track, 1.1 min. exclude_reason: music_single", "music_single"),
            (
                "Music EP (4 tracks, ~11 min), not a Hörspiel episode. Exclude as wrong content type",
                "wrong_content_type",
            ),
            (
                "Box set containing episodes 1-5. Title contains range pattern. Exclude as compilation.",
                "compilation",
            ),
            (
                "'Die schönsten' + type=compilation signals greatest-hits compilation. Named pattern: kinderlieder_compilation. exclude_reason=kinderlieder_compilation",
                "kinderlieder_compilation",
            ),
            (
                "Type=compilation mixing songs from two prior albums. Named pattern: compilation. exclude_reason=compilation",
                "compilation",
            ),
            (
                "Advent calendar with 24 daily episodes. Named pattern: compilation. Exclude reason: compilation",
                "compilation",
            ),
            (
                "448 tracks, 157.6 min, Bookstream Hörbücher label – unabridged audiobook reading, not a Hörspiel episode. Named pattern: wrong_content_type. Exclude reason: wrong_content_type",
                "wrong_content_type",
            ),
            (
                "Compilation of previously released singles/EPs; marked as compilation type",
                "compilation",
            ),
            (
                "Jubiläumsedition compilation containing multiple episodes. exclude_reason: compilation",
                "compilation",
            ),
        ],
    )
    def test_verbose_reason_normalizes_to_label(self, verbose: str, expected: str):
        assert normalize_exclude_reason(verbose) == expected

    def test_truly_unknown_reason_becomes_unspecified(self):
        assert normalize_exclude_reason("some completely random text") == "unspecified"

    def test_audit_override_preserved(self):
        assert normalize_exclude_reason("audit_override") == "audit_override"

    def test_not_kids_content_preserved(self):
        assert normalize_exclude_reason("not_kids_content") == "not_kids_content"


# ── reconcile_cross_provider ────────────────────────────────────────────


def _album(
    album_id: str,
    title: str,
    provider: str,
    include: bool,
    exclude_reason: str | None = None,
) -> dict:
    return album_record(
        album_id,
        provider=provider,
        include=include,
        title=title,
        exclude_reason=exclude_reason,
    )


class TestReconcileCrossProvider:
    def test_no_change_when_both_included(self):
        albums = [
            _album("sp1", "Folge 1", "spotify", True),
            _album("am1", "Folge 1", "apple_music", True),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 0
        assert result.flagged == 0

    def test_no_change_when_both_excluded(self):
        albums = [
            _album("sp1", "Folge 1", "spotify", False, "compilation"),
            _album("am1", "Folge 1", "apple_music", False, "compilation"),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 0

    def test_wrong_content_type_gets_flipped(self):
        albums = [
            _album("sp1", "Folge 1", "spotify", True),
            _album("am1", "Folge 1", "apple_music", False, "wrong_content_type"),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 1
        assert albums[1]["include"] is True
        assert albums[1].get("exclude_reason") is None

    def test_wrong_content_type_flip_works_both_directions(self):
        albums = [
            _album("sp1", "Folge 1", "spotify", False, "wrong_content_type"),
            _album("am1", "Folge 1", "apple_music", True),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 1
        assert albums[0]["include"] is True

    def test_compilation_gets_flipped_when_counterpart_included(self):
        albums = [
            _album("sp1", "Folge 1", "spotify", True),
            _album("am1", "Folge 1", "apple_music", False, "compilation"),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 1
        assert albums[1]["include"] is True

    def test_sub_series_bleed_gets_flagged(self):
        albums = [
            _album("sp1", "Folge 1", "spotify", True),
            _album("am1", "Folge 1", "apple_music", False, "sub_series_bleed"),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 0
        assert result.flagged == 1

    def test_music_single_is_flagged_not_flipped(self):
        """A single included on one provider and excluded on the other is put on
        the review list, not flipped: the include is the questionable side
        (Chris, 2026-09-05)."""
        albums = [
            _album("sp1", "Song", "spotify", True),
            _album("am1", "Song", "apple_music", False, "music_single"),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 0
        assert result.flagged == 1
        assert albums[1]["include"] is False

    def test_multiple_titles_processed_independently(self):
        albums = [
            _album("sp1", "Folge 1", "spotify", True),
            _album("am1", "Folge 1", "apple_music", False, "wrong_content_type"),
            _album("sp2", "Folge 2", "spotify", True),
            _album("am2", "Folge 2", "apple_music", False, "sub_series_bleed"),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 1
        assert result.flagged == 1

    def test_title_only_on_one_provider_ignored(self):
        albums = [
            _album("sp1", "Spotify Only", "spotify", True),
            _album("am1", "Apple Only", "apple_music", False, "wrong_content_type"),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 0
        assert result.flagged == 0

    def test_multiple_releases_same_title_uses_any_included(self):
        """If Apple Music has both an included and excluded version of
        the same title, there's no mismatch to fix."""
        albums = [
            _album("am1", "Folge 1", "apple_music", True),
            _album("am2", "Folge 1", "apple_music", False, "duplicate"),
            _album("sp1", "Folge 1", "spotify", True),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 0

    def test_returns_details_for_flagged(self):
        albums = [
            _album("sp1", "Folge 1", "spotify", True),
            _album("am1", "Folge 1", "apple_music", False, "sub_series_bleed"),
        ]
        result = reconcile_cross_provider(albums)
        assert len(result.details) == 1
        assert result.details[0]["title"] == "Folge 1"
        assert result.details[0]["action"] == "flagged"

    def test_returns_details_for_flipped(self):
        albums = [
            _album("sp1", "Folge 1", "spotify", True),
            _album("am1", "Folge 1", "apple_music", False, "wrong_content_type"),
        ]
        result = reconcile_cross_provider(albums)
        assert len(result.details) == 1
        assert result.details[0]["action"] == "flipped"
        assert result.details[0]["album_id"] == "am1"

    def test_normalized_title_matching_strips_single_suffix(self):
        albums = [
            _album("sp1", "Song Title", "spotify", True),
            _album("am1", "Song Title - Single", "apple_music", False, "music_single"),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 0
        assert result.flagged == 1

    def test_normalized_title_matching_is_case_insensitive(self):
        albums = [
            _album("sp1", "Folge 1: Der Super-Papagei", "spotify", True),
            _album(
                "am1", "folge 1: der super-papagei", "apple_music", False, "compilation"
            ),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 1

    def test_doppelfolge_compilation_auto_flipped(self):
        """Was Ist Was 'Topic A / Topic B' excluded as compilation on
        one provider but included on the other should be auto-flipped."""
        albums = [
            _album(
                "am1", "07: Roboter & Androiden / Supercomputer", "apple_music", True
            ),
            _album(
                "sp1",
                "07: Roboter & Androiden / Supercomputer",
                "spotify",
                False,
                "compilation",
            ),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 1
        assert albums[1]["include"] is True

    def test_partial_release_auto_flipped(self):
        """Die Playmos 'Brief von Captain Tolle' excluded as
        partial_release on Apple Music but included on Spotify."""
        albums = [
            _album("sp1", "Brief von Captain Tolle", "spotify", True),
            _album(
                "am1",
                "Brief von Captain Tolle",
                "apple_music",
                False,
                "partial_release",
            ),
        ]
        result = reconcile_cross_provider(albums)
        assert result.flipped == 1
        assert albums[1]["include"] is True
        assert albums[1].get("exclude_reason") is None


class TestUnspecifiedAutoFlip:
    """Die Playmos on Apple Music: the full "Folge 100: Der magische
    Ring" sat excluded as `unspecified` while Spotify included the same
    title, and a child got the 1-of-9 fragment instead. An exclusion
    that carries no reason loses to an exact cross-provider include."""

    def _pair(self, reason):
        albums = [
            {
                "album_id": "sp_full",
                "provider": "spotify",
                "include": True,
                "episode_num": 100,
                "title": "Folge 100: Der magische Ring",
            },
            {
                "album_id": "am_full",
                "provider": "apple_music",
                "include": False,
                "episode_num": 100,
                "title": "Folge 100: Der magische Ring",
            },
        ]
        if reason is not None:
            albums[1]["exclude_reason"] = reason
        return albums

    def test_unspecified_flips_on_exact_cross_provider_match(self):
        albums = self._pair("unspecified")
        result = reconcile_cross_provider(albums)
        assert result.flipped == 1
        assert albums[1]["include"] is True

    def test_a_missing_reason_counts_as_unspecified(self):
        albums = self._pair(None)
        result = reconcile_cross_provider(albums)
        assert result.flipped == 1
        assert albums[1]["include"] is True

    def test_flip_is_refused_when_it_would_duplicate_an_included_episode(self):
        albums = self._pair("unspecified")
        albums.append(
            {
                "album_id": "am_frag",
                "provider": "apple_music",
                "include": True,
                "episode_num": 100,
                "title": "Folge 100: Der magische Ring - Episode 1",
            }
        )
        result = reconcile_cross_provider(albums)
        assert result.flipped == 0
        assert albums[1]["include"] is False
        assert result.flagged == 1
        assert any("duplicate" in d.get("reason", "") for d in result.details)


class TestSinglesAndVariantsDoNotFlipToInclude:
    """A same-title include on the other provider does not validate a
    single or an instrumental version: the include is the questionable
    side. Reconcile flags the pair for review instead of flipping."""

    def _pair(self, reason):
        return [
            _album("s1", "Alles ist doof - Single", "spotify", True),
            _album("a1", "Alles ist doof - Single", "apple_music", False, reason),
        ]

    def test_a_single_stays_excluded_and_is_flagged(self):
        result = reconcile_cross_provider(self._pair("music_single"))
        assert result.flipped == 0
        assert result.flagged == 1

    def test_a_format_variant_stays_excluded_and_is_flagged(self):
        result = reconcile_cross_provider(self._pair("format_variant"))
        assert result.flipped == 0
        assert result.flagged == 1
