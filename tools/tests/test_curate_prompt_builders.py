"""Pure prompt-assembly helpers extracted from the curate flow.

Three pieces of the batch prompt assembly existed only inside the
700-line flow, untested and (in one case) spelled out twice. These
versions are pure, unit-tested, and the single source; the flow code
calls them.
"""

from __future__ import annotations

from lauschi_catalog.catalog.curate_ops import (
    AlbumDecision,
    build_batch_prompt,
    build_structural_hints,
    curation_from_decisions,
    format_batch_albums,
)


def _decision(
    album_id: str,
    *,
    include: bool = True,
    episode_num: int | None = None,
    provider: str = "spotify",
    title: str = "",
    release_date: str | None = None,
    exclude_reason: str | None = None,
) -> AlbumDecision:
    d = AlbumDecision(
        album_id=album_id,
        provider=provider,
        include=include,
        title=title or album_id,
        episode_num=episode_num,
        release_date=release_date,
        confidence="high",
    )
    if exclude_reason:
        d.exclude_reason = exclude_reason
    return d


class TestCurationFromDecisions:
    def test_shape_matches_what_lint_and_analyze_read(self):
        curation = curation_from_decisions(
            [_decision("a1", episode_num=1)],
            pattern=r"^Folge (\d+):",
        )
        assert curation["episode_pattern"] == r"^Folge (\d+):"
        (album,) = curation["albums"]
        assert album["album_id"] == "a1"
        assert album["episode_num"] == 1
        assert album["include"] is True
        # lint reads exclude_reason; analyze ignores it, so carrying it
        # always is identity-neutral for both consumers
        assert album["exclude_reason"] is None

    def test_series_facts_passes_through_when_given(self):
        facts = {"era_boundaries": [{"label": "klassik"}]}
        curation = curation_from_decisions([], None, series_facts=facts)
        assert curation["series_facts"] == facts

    def test_series_facts_omitted_when_none(self):
        curation = curation_from_decisions([], None)
        assert "series_facts" not in curation

    def test_three_previous_copies_produce_the_same_dict(self):
        """The three inline spellings (batch hints, finalize lint, finalize
        analysis) were converging anyway; one builder feeds all."""
        decisions = [
            _decision("a1", episode_num=1),
            _decision("a2", include=False, exclude_reason="compilation"),
        ]
        curation = curation_from_decisions(decisions, r"^Folge (\d+):")
        assert [a["album_id"] for a in curation["albums"]] == ["a1", "a2"]
        assert curation["albums"][1]["exclude_reason"] == "compilation"


class TestBuildStructuralHints:
    def test_empty_when_no_analysis_signals(self):
        assert build_structural_hints({}) == []

    def test_gap_hint_carries_the_missing_numbers(self):
        hints = build_structural_hints({"gaps": [3, 5]})
        assert hints == ["Missing episodes so far: [3, 5]"]

    def test_duplicate_hint_is_per_episode(self):
        analysis = {
            "duplicates_within_provider": [
                {"provider": "spotify", "episode_num": 7},
                {"provider": "apple_music", "episode_num": 9},
            ]
        }
        hints = build_structural_hints(analysis)
        assert any("spotify" in h and "7" in h for h in hints)
        assert any("apple_music" in h and "9" in h for h in hints)

    def test_missing_provider_episodes_hint(self):
        analysis = {
            "cross_provider_coverage": {"missing_per_provider": {"spotify": [4, 5]}}
        }
        hints = build_structural_hints(analysis)
        assert any("spotify" in h and "[4, 5]" in h for h in hints)

    def test_cluster_hint_shows_up_to_three_examples(self):
        analysis = {
            "title_clusters": [
                {
                    "shape": "folge n",
                    "count": 12,
                    "examples": [f"T{i}" for i in range(6)],
                }
            ]
        }
        (hint,) = build_structural_hints(analysis)
        assert "12 albums" in hint
        assert "T2" in hint
        assert "T3" not in hint  # capped at 3 examples


class TestBuildBatchPrompt:
    def test_snapshot_shape(self):
        prompt = build_batch_prompt(
            series_title="Die Playmos",
            pattern=r"^Folge (\d+):",
            progress_text="Progress: 5 included, 2 excluded.",
            rolling="Prior included: spotify 1-5",
            structural_hints=["Missing episodes so far: [7]"],
            batch_num=2,
            n_batches=4,
            n_albums=3,
            albums_xml="<album>…</album>",
        )
        lines = prompt.splitlines()
        assert lines[0] == "Series: 'Die Playmos'"
        assert lines[1].startswith("Episode pattern: ^Folge (\\d+):")
        assert lines[2] == "Progress: 5 included, 2 excluded."
        assert "Batch 2/4 (3 albums):" in prompt
        assert "<album>" in prompt
        # hints live before the batch listing
        assert prompt.index("Missing episodes") < prompt.index("Batch 2/4")

    def test_without_hints_the_block_is_absent(self):
        prompt = build_batch_prompt(
            series_title="S",
            pattern=None,
            progress_text="Progress: 0 included, 0 excluded.",
            rolling="",
            structural_hints=[],
            batch_num=1,
            n_batches=1,
            n_albums=1,
            albums_xml="<album/>",
        )
        assert "Structural signals" not in prompt
        assert "Batch 1/1" in prompt


class TestFormatBatchAlbums:
    def test_prefers_the_seen_details_entry(self):
        batch = [{"provider": "spotify", "id": "a1", "name": "N"}]
        seen = {
            "spotify:a1": {
                "id": "a1",
                "name": "N full",
                "provider": "spotify",
                "release_date": "2026-01-01",
                "total_tracks": 20,
            }
        }
        albums = format_batch_albums(batch, seen)
        (album,) = albums
        assert album["title"] == "N full"
        assert album["total_tracks"] == 20
        assert album["label"] == ""  # missing details stay explicit

    def test_fallback_fills_every_key_the_prompt_reads(self):
        """The fallback dict was spelled out next to prompt.album_to_dict;
        both must produce the same shape so the XML never meets a key."""
        batch = [{"provider": "spotify", "id": "a1", "name": "N"}]
        (album,) = format_batch_albums(batch, {})
        for key in (
            "provider",
            "id",
            "title",
            "release_date",
            "album_type",
            "total_tracks",
            "label",
            "artist",
            "tracks",
        ):
            assert key in album
        assert album["title"] == "N"
        assert album["episode_num"] is None
