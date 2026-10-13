"""The metadata agent's prompt states what the catalog knows.

A split-off line got forty sample albums of the whole shared artist page
and nothing else. Most of them were the main series' episodes, and
nothing said so. In a full run DeepSeek V4 Pro reasoned in circles over
that in seven series ("the series is the Adventskalender, but the samples
are main episodes") until its output budget was gone, and the series was
lost. The main series, the other entries on the page, the titles the
series ships and its pattern are all in the catalog before the agent
starts.
"""

import pytest
from pydantic_ai import Agent
from pydantic_ai.messages import ModelMessage, ModelResponse, ToolCallPart
from pydantic_ai.models.function import AgentInfo, FunctionModel
from pydantic_ai.models.test import TestModel

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import (
    CurateDeps,
    DiscoveryResult,
    SeriesFacts,
    SeriesMetadata,
    build_metadata_prompt,
)
from tests.factories import discovered_album, entry

SAMPLE = "  - Folge 1: Hexe Lilli zaubert | 12 tracks | 2010-01-01"


def _prompt(**facts: object) -> str:
    return build_metadata_prompt(
        query="Hexe Lilli: Erstlesergeschichten",
        provider_list="spotify: ['a1']",
        sample_lines=SAMPLE,
        **facts,  # type: ignore[arg-type]
    )


def test_a_series_the_catalog_knows_nothing_about_gets_the_sample_alone() -> None:
    assert _prompt() == (
        "Series: 'Hexe Lilli: Erstlesergeschichten'\n"
        "Providers: spotify: ['a1']\n"
        "Sample albums (title | tracks | release_date):\n"
        f"{SAMPLE}"
    )


def test_a_split_off_line_is_told_its_main_series() -> None:
    assert "This series is a line split off from 'Hexe Lilli'.\n" in _prompt(
        line_of="Hexe Lilli"
    )


def test_a_shared_page_names_its_other_entries_and_whose_the_sample_is() -> None:
    prompt = _prompt(sibling_titles=["Hexe Lilli", "Hexe Lilli (Kinofilm)"])
    assert (
        "Its artist pages also carry these catalog entries: 'Hexe Lilli', "
        "'Hexe Lilli (Kinofilm)'.\n"
    ) in prompt
    assert (
        "The sample albums are drawn from the whole page, so many of them "
        "belong to those entries and not to this series.\n"
    ) in prompt


def test_a_page_of_its_own_says_nothing_about_other_entries() -> None:
    assert "whole page" not in _prompt(shipped_titles=["Feiert Geburtstag"])


def test_the_titles_the_series_ships_are_listed_once_each() -> None:
    prompt = _prompt(
        shipped_titles=[
            "Feiert Geburtstag",
            "Zaubert Hausaufgaben",
            "Feiert Geburtstag",
        ]
    )
    assert (
        "The catalog ships 2 titles in this series today:\n"
        "  - Feiert Geburtstag\n"
        "  - Zaubert Hausaufgaben\n"
    ) in prompt


def test_a_long_series_shows_titles_spread_over_what_it_ships() -> None:
    prompt = _prompt(shipped_titles=[f"Folge {n}: Titel" for n in range(1, 201)])
    assert "The catalog ships 200 titles in this series today, among them:\n" in prompt
    listed = [line for line in prompt.splitlines() if line.endswith(": Titel")]
    assert len(listed) == 15
    assert listed[0] == "  - Folge 1: Titel"
    assert int(listed[-1].split()[2].rstrip(":")) > 180


def test_the_catalog_pattern_is_printed_as_the_regex_to_type() -> None:
    """A list printed by Python doubles every backslash, and the agent
    types the pattern back into `check_pattern_coverage`."""
    prompt = _prompt(pattern=[r"^(\d{3})/", r"^Folge (\d+):"])
    assert (
        "The catalog holds an episode_pattern for this series, and the run "
        "numbers its albums with it. Check it first:\n"
        "  ^(\\d{3})/\n"
        "  ^Folge (\\d+):\n"
    ) in prompt
    assert "\\\\d" not in prompt


def test_a_single_catalog_pattern_is_printed_the_same_way() -> None:
    assert "Check it first:\n  ^Folge (\\d+):\n" in _prompt(pattern=r"^Folge (\d+):")


def test_the_facts_come_before_the_sample() -> None:
    prompt = _prompt(
        line_of="Hexe Lilli",
        sibling_titles=["Hexe Lilli"],
        shipped_titles=["Feiert Geburtstag"],
        pattern=r"^Folge (\d+):",
    )
    order = [
        prompt.index("split off from"),
        prompt.index("also carry"),
        prompt.index("The catalog ships"),
        prompt.index("episode_pattern"),
        prompt.index("Sample albums"),
    ]
    assert order == sorted(order)


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("content_type", "has_pattern_tool"), [("hoerspiel", True), ("audiobook", False)]
)
async def test_a_run_tells_the_agent_what_the_catalog_holds(
    monkeypatch: pytest.MonkeyPatch, content_type: str, has_pattern_tool: bool
) -> None:
    main = entry("hexe_lilli", "Hexe Lilli", spotify=["a1"])
    line = entry(
        "hexe_lilli_erstleser",
        "Hexe Lilli: Erstlesergeschichten",
        spotify=["a1"],
        split_from="hexe_lilli",
        episode_pattern=r"^Folge (\d+):",
    )
    line.providers["spotify"].albums = [{"id": "s1", "title": "Folge 1: Geburtstag"}]
    monkeypatch.setattr(curate_ops, "load_catalog", lambda: [main, line])
    monkeypatch.setattr(curate_ops, "lookup_catalog_entry", lambda _id: line)

    async def page(*_a: object, **_k: object) -> DiscoveryResult:
        return DiscoveryResult(
            all_albums=[
                discovered_album("spotify", "s1", "Folge 1: Geburtstag")
                | {"total_tracks": 9},
                discovered_album("spotify", "s2", "Folge 1: Hexe Lilli zaubert")
                | {"total_tracks": 12},
            ],
            artist_ids={"spotify": ["a1"]},
            provider_errors=[],
            incomplete=False,
        )

    monkeypatch.setattr(curate_ops, "_run_discovery", page)
    monkeypatch.setattr(
        curate_ops, "build_model", lambda _name, _key: TestModel(call_tools=[])
    )
    asked: list[str] = []

    def answer(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        asked.append(str(messages[0].parts[-1].content))  # type: ignore[union-attr]
        return ModelResponse(
            parts=[
                ToolCallPart(
                    info.output_tools[0].name,
                    {"id": "hexe_lilli_erstleser", "title": line.title},
                )
            ]
        )

    monkeypatch.setattr(
        curate_ops,
        "_build_metadata_agent",
        lambda _model, **_k: Agent[CurateDeps, SeriesMetadata](
            FunctionModel(answer), output_type=SeriesMetadata
        ),
    )

    class Stop(Exception):
        pass

    def stop(*_a: object, **_k: object) -> None:
        raise Stop

    # the batches are not what this test is about
    monkeypatch.setattr(curate_ops, "_preseed_decisions", stop)
    with pytest.raises(Stop):
        await curate_ops._run_large(
            line.title,
            [],
            model_name="test",
            api_key="test",
            timeout=60,
            existing_facts=SeriesFacts(),
            series_id=line.id,
            content_type=content_type,
        )

    (prompt,) = asked
    assert "This series is a line split off from 'Hexe Lilli'.\n" in prompt
    assert "also carry these catalog entries: 'Hexe Lilli'.\n" in prompt
    assert (
        "The catalog ships 1 title in this series today:\n  - Folge 1: Geburtstag\n"
    ) in prompt
    assert "  - Folge 1: Hexe Lilli zaubert | " in prompt
    # a pattern to check is only named to a run that can check one
    assert ("Check it first:\n  ^Folge (\\d+):\n" in prompt) is has_pattern_tool
