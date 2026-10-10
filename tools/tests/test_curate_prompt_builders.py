"""Pure prompt-assembly helpers extracted from the curate flow.

Three pieces of the batch prompt assembly existed only inside the
700-line flow, untested and (in one case) spelled out twice. These
versions are pure, unit-tested, and the single source; the flow code
calls them.
"""

from __future__ import annotations

import pytest
import requests

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import (
    AlbumDecision,
    _build_batch_summary,
    batch_prompt,
    build_batch_prompt,
    build_structural_hints,
    curation_from_decisions,
    format_batch_albums,
)
from lauschi_catalog.catalog.episode_range import RangeFact
from lauschi_catalog.catalog.prompt import format_album_xml, format_reference_lines
from lauschi_catalog.reference import (
    Fetch,
    ReferenceEpisode,
    ReferenceIndex,
    ReferenceLine,
    ReferenceProduct,
    ReferenceSeries,
)
from tests.factories import decision
from tests.test_reference_index import fake_fetch


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
    return decision(
        album_id,
        provider=provider,
        include=include,
        episode_num=episode_num,
        title=title or album_id,
        release_date=release_date,
        exclude_reason=exclude_reason or None,
    )


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
            sibling_titles=[],
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
            sibling_titles=[],
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


class TestEpisodeRangeFact:
    """The batch sees a page in slices of 30, so whether a box's episodes
    also exist on their own is handed to it as a fact per album."""

    def test_the_fact_rides_on_its_album(self):
        batch = [
            {"provider": "spotify", "id": "box", "name": "Folgen 6-10: Baby"},
            {"provider": "spotify", "id": "one", "name": "Folge 12: Alarm"},
        ]
        facts = {("spotify", "box"): RangeFact(6, 10, released_alone=())}

        box, single = format_batch_albums(batch, {}, facts)

        assert box["episode_range"] == RangeFact(6, 10, released_alone=())
        assert "episode_range" not in single

    def test_the_fact_rides_on_its_album_when_details_lack_the_keys(self):
        # Prefetched details are provider payloads, and album_to_dict falls
        # back to "?" for a missing provider. The batch row always has both.
        batch = [{"provider": "spotify", "id": "box", "name": "Folgen 6-10: Baby"}]
        seen = {"spotify:box": {"name": "Folgen 6-10: Baby", "total_tracks": 25}}
        facts = {("spotify", "box"): RangeFact(6, 10, released_alone=())}

        (box,) = format_batch_albums(batch, seen, facts)

        assert box["episode_range"] == RangeFact(6, 10, released_alone=())

    def test_xml_says_none_of_the_run_exists_alone(self):
        album = {
            "provider": "spotify",
            "id": "box",
            "title": "Folgen 6-10: Baby",
            "episode_range": RangeFact(6, 10, released_alone=()),
        }

        xml = format_album_xml(album, include_tracks=False)

        assert '<episode_range first="6" last="10" also_released_alone="none"/>' in xml

    def test_xml_lists_the_episodes_that_exist_alone(self):
        album = {
            "provider": "spotify",
            "id": "box",
            "title": "Folgen 1-3: Start",
            "episode_range": RangeFact(1, 3, released_alone=(1, 3)),
        }

        xml = format_album_xml(album, include_tracks=False)

        assert 'also_released_alone="1, 3"' in xml


class TestBatchPrompt:
    """The prompt of one batch carries what the run decided before it."""

    PATTERN = r"^Folge (\d+):"
    DECIDED = [
        decision("a", episode_num=1, title="Folge 1: Anfang"),
        decision("c", episode_num=3, title="Folge 3: Ende"),
        decision("best", include=False, exclude_reason="compilation", title="Best of"),
    ]

    def _prompt(
        self,
        decisions: list[AlbumDecision],
        *,
        run_facts: dict[tuple[str, str], RangeFact] | None = None,
        line_of: str | None = None,
    ) -> str:
        return batch_prompt(
            [
                {
                    "provider": "spotify",
                    "id": "box",
                    "name": "Folgen 6-10: Die Box",
                    "release_date": "2020-01-01",
                }
            ],
            decisions,
            series_title="Feuerwehrmann Sam",
            pattern=self.PATTERN,
            seen_details={},
            run_facts=run_facts or {},
            sibling_titles=["Feuerwehrmann Sam Classics"],
            line_of=line_of,
            batch_num=2,
            n_batches=3,
        )

    def test_a_first_batch_has_no_history(self) -> None:
        prompt = self._prompt([])

        assert "Progress: 0 included, 0 excluded.\n" in prompt
        assert "Structural signals" not in prompt
        assert "Batch 2/3 (1 albums):" in prompt

    def test_progress_names_the_episode_span_decided_so_far(self) -> None:
        prompt = self._prompt(self.DECIDED)

        assert "Progress: 2 included (episodes 1-3), 1 excluded.\n" in prompt

    def test_summary_and_structural_hints_come_from_the_decisions(self) -> None:
        prompt = self._prompt(self.DECIDED)

        assert _build_batch_summary(self.DECIDED, self.PATTERN, 2) in prompt
        assert "  Missing episodes so far: [2]" in prompt

    def test_a_box_carries_its_fact_and_the_series_its_siblings(self) -> None:
        prompt = self._prompt(
            [],
            run_facts={("spotify", "box"): RangeFact(6, 10, (7,))},
            line_of="Feuerwehrmann Sam",
        )

        assert '<episode_range first="6" last="10" also_released_alone="7"/>' in prompt
        assert "  - Feuerwehrmann Sam Classics" in prompt
        assert "a line split off from 'Feuerwehrmann Sam'" in prompt


class TestReferenceLines:
    """What the line index holds for a brand, as a block for the prompt."""

    SERIES = ReferenceSeries(
        id=1,
        name="Hexe Lilli",
        lines=[
            ReferenceLine(
                "Klassiker",
                [
                    ReferenceEpisode(
                        "1", "Hexe Lilli stellt die Schule auf den Kopf", 2760
                    ),
                    ReferenceEpisode("2", "Hexe Lilli macht Zauberquatsch", 2460),
                ],
            ),
            ReferenceLine(
                "Erstlesergeschichten", [ReferenceEpisode("3", "Und der Vampir", 2160)]
            ),
            ReferenceLine("Musik", []),
        ],
    )
    UNFILED = [
        ReferenceProduct(
            id=7,
            title="Und der kleine Eisbär Knöpfchen",
            author="Hexe Lilli",
            label="EUROPA mini",
            kind="RADIOPLAY",
            seconds=2880,
            categories=(),
            brand=None,
            line=None,
            number=None,
        )
    ]

    def test_lines_come_with_titles_and_running_times_never_with_numbers(self) -> None:
        block = format_reference_lines(self.SERIES, self.UNFILED)

        assert (
            '<line name="Klassiker">\n'
            "Hexe Lilli stellt die Schule auf den Kopf (46 min)\n"
            "Hexe Lilli macht Zauberquatsch (41 min)\n"
            "</line>"
        ) in block
        assert (
            '<line name="Erstlesergeschichten">\nUnd der Vampir (36 min)\n</line>'
            in block
        )
        assert "Musik" not in block, "a line without titles says nothing"

    def test_a_title_without_a_known_running_time_stands_alone(self) -> None:
        series = ReferenceSeries(
            id=2,
            name="X",
            lines=[
                ReferenceLine(
                    "Hörspiele", [ReferenceEpisode("4", "Lauras Geheimnis", None)]
                )
            ],
        )

        assert "\nLauras Geheimnis\n</line>" in format_reference_lines(series, [])

    def test_products_without_a_line_are_listed_apart(self) -> None:
        block = format_reference_lines(self.SERIES, self.UNFILED)

        assert (
            "<no_line>\nUnd der kleine Eisbär Knöpfchen (EUROPA mini, RADIOPLAY, 48 min)\n</no_line>"
            in block
        )
        assert "<no_line>" not in format_reference_lines(self.SERIES, [])

    def test_the_block_says_what_it_is_good_for(self) -> None:
        block = format_reference_lines(self.SERIES, self.UNFILED)

        assert block.startswith("## The brand's lines in the public line index\n")
        assert "proves nothing" in block
        assert "no episode numbers" in block


class TestSharedPageReference:
    """The fetch around the block: a run goes on without the index."""

    def _index(self, monkeypatch: pytest.MonkeyPatch, fetch: Fetch, url: str) -> None:
        monkeypatch.setattr(
            curate_ops,
            "ReferenceIndex",
            lambda: ReferenceIndex(url, fetch=fetch, use_cache=False),
        )

    def test_a_known_brand_comes_back_as_the_block(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        self._index(monkeypatch, fake_fetch, "https://example.test/api")

        block = curate_ops.shared_page_reference("Kommissar Kugelblitz")

        assert (
            '<line name="Hörspiele zu den Büchern">\nDie rote Socke (61 min)\n' in block
        )
        assert "<no_line>\nDer grüne Schal (EUROPA mini, RADIOPLAY, 48 min)" in block

    def test_an_unknown_brand_and_an_unconfigured_index_give_nothing(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        self._index(monkeypatch, fake_fetch, "https://example.test/api")
        assert curate_ops.shared_page_reference("Conni") == ""

        self._index(monkeypatch, fake_fetch, "")
        assert curate_ops.shared_page_reference("Kommissar Kugelblitz") == ""

    def test_an_index_that_cannot_be_reached_does_not_stop_the_run(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        def down(url: str, params: dict | None) -> dict:
            raise requests.ConnectionError(url)

        self._index(monkeypatch, down, "https://example.test/api")

        assert curate_ops.shared_page_reference("Kommissar Kugelblitz") == ""
