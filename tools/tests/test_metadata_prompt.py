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
from pydantic import ValidationError
from pydantic_ai import Agent
from pydantic_ai.exceptions import UnexpectedModelBehavior
from pydantic_ai.messages import ModelMessage, ModelResponse, ToolCallPart
from pydantic_ai.models.function import AgentInfo, FunctionModel
from pydantic_ai.models.test import TestModel

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import (
    CurateDeps,
    CuratedSeries,
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


def test_a_series_in_the_catalog_is_told_its_id() -> None:
    assert "Its catalog id is `hexe_lilli_erstleser`. Return it as `id`.\n" in _prompt(
        series_id="hexe_lilli_erstleser"
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


def test_the_catalog_pattern_is_stated_as_settled() -> None:
    """A list printed by Python doubles every backslash, so each regex
    is printed as it is typed."""
    prompt = _prompt(pattern=[r"^(\d{3})/", r"^Folge (\d+):"])
    assert (
        "The catalog holds an episode_pattern for this series. The run numbers "
        "its albums with it whatever you return, so leave episode_pattern "
        "empty and skip the pattern check:\n"
        "  ^(\\d{3})/\n"
        "  ^Folge (\\d+):\n"
    ) in prompt
    assert "\\\\d" not in prompt


def test_a_single_catalog_pattern_is_printed_the_same_way() -> None:
    assert "the pattern check:\n  ^Folge (\\d+):\n" in _prompt(pattern=r"^Folge (\d+):")


def test_the_facts_come_before_the_sample() -> None:
    prompt = _prompt(
        series_id="hexe_lilli_erstleser",
        line_of="Hexe Lilli",
        sibling_titles=["Hexe Lilli"],
        shipped_titles=["Feiert Geburtstag"],
        pattern=r"^Folge (\d+):",
    )
    order = [
        prompt.index("Its catalog id"),
        prompt.index("split off from"),
        prompt.index("also carry"),
        prompt.index("The catalog ships"),
        prompt.index("episode_pattern"),
        prompt.index("Sample albums"),
    ]
    assert order == sorted(order)


class Stop(Exception):
    """Ends a run at the point a test looks at."""


async def _run_the_line(
    monkeypatch: pytest.MonkeyPatch,
    *,
    answers: dict[str, object] | None = None,
    stop_at: str = "_preseed_decisions",
) -> tuple[list[str], list[dict[str, object]]]:
    """Run the Erstleser line of a shared Hexe Lilli page up to ``stop_at``.

    Returns the prompts the metadata agent got, and the keyword arguments
    ``stop_at`` was called with.
    """
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
                discovered_album("spotify", "s2", "Hexe Lilli zaubert")
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
                    {"id": line.id, "title": line.title} | (answers or {}),
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
    stopped_with: list[dict[str, object]] = []

    def stop(*_a: object, **kwargs: object) -> None:
        stopped_with.append(kwargs)
        raise Stop

    monkeypatch.setattr(curate_ops, stop_at, stop)
    with pytest.raises(Stop):
        await curate_ops._run_large(
            line.title,
            [],
            model_name="test",
            api_key="test",
            timeout=60,
            existing_facts=SeriesFacts(),
            series_id=line.id,
        )
    return asked, stopped_with


@pytest.mark.anyio
async def test_a_run_tells_the_agent_what_the_catalog_holds(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    (prompt,), _ = await _run_the_line(monkeypatch)

    assert "Its catalog id is `hexe_lilli_erstleser`. Return it as `id`.\n" in prompt
    assert "This series is a line split off from 'Hexe Lilli'.\n" in prompt
    assert "also carry these catalog entries: 'Hexe Lilli'.\n" in prompt
    assert (
        "The catalog ships 1 title in this series today:\n  - Folge 1: Geburtstag\n"
    ) in prompt
    assert "the pattern check:\n  ^Folge (\\d+):\n" in prompt
    assert "  - Hexe Lilli zaubert | " in prompt


@pytest.mark.anyio
async def test_a_series_with_a_catalog_pattern_is_not_asked_for_one() -> None:
    """The run keeps the catalog's pattern, so a proposal is thrown away.
    Checking it anyway cost GLM-5.3 the Erstleser line of Hexe Lilli: the
    catalog's pattern numbers 3 of its 17 titles, the agent returned it as
    told, and the check refused it three times."""
    catalog_pattern = r"^Folge (\d+): .*\(Erstlesergeschichten\)"

    def answer(_messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        return ModelResponse(
            parts=[
                ToolCallPart(
                    info.output_tools[0].name,
                    {
                        "id": "hexe_lilli_erstleser",
                        "title": "Hexe Lilli: Erstlesergeschichten",
                        "episode_pattern": catalog_pattern,
                    },
                )
            ]
        )

    agent = curate_ops._build_metadata_agent(FunctionModel(answer))
    deps = CurateDeps(
        providers=[],
        titles=["Feiert Geburtstag", "Zaubert Hausaufgaben"],
        coverage_titles=["Feiert Geburtstag", "Zaubert Hausaufgaben"],
        pattern=catalog_pattern,
    )

    result = await agent.run("Series: 'Hexe Lilli: Erstlesergeschichten'", deps=deps)

    assert result.output.title == "Hexe Lilli: Erstlesergeschichten"


@pytest.mark.anyio
async def test_a_series_without_a_catalog_pattern_still_has_its_proposal_checked() -> (
    None
):
    def answer(_messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        return ModelResponse(
            parts=[
                ToolCallPart(
                    info.output_tools[0].name,
                    {"id": "x", "title": "X", "episode_pattern": r"^Folge (\d+):"},
                )
            ]
        )

    agent = curate_ops._build_metadata_agent(FunctionModel(answer))
    deps = CurateDeps(providers=[], titles=["Feiert Geburtstag"])

    with pytest.raises(UnexpectedModelBehavior):
        await agent.run("Series: 'X'", deps=deps)


@pytest.mark.anyio
async def test_the_batches_name_the_series_as_the_catalog_does(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """GLM-5.3 answered the Sternchen line of Sternenschweif with the title
    "Sternenschweif". The batches were then asked about a series of that
    name, and the line took 142 episodes of the main series."""
    _, (batch,) = await _run_the_line(
        monkeypatch,
        answers={"id": "hexe_lilli", "title": "Hexe Lilli"},
        stop_at="batch_prompt",
    )

    assert batch["series_title"] == "Hexe Lilli: Erstlesergeschichten"


def test_a_run_takes_id_and_title_from_the_catalog() -> None:
    """Both are catalog facts. The cover cache and the failure dumps of a
    run are filed under its id, and the web UI looks for them under the
    catalog's."""
    line = entry("5_geschwister_adventskalender", "5 Geschwister: Adventskalender")
    meta = SeriesMetadata(id="fuenf_geschwister", title="5 Geschwister")

    curate_ops._name_as_catalog(meta, line, lambda _line: None)

    assert meta.title == "5 Geschwister: Adventskalender"
    assert meta.id == "5_geschwister_adventskalender"
    assert CuratedSeries(id=meta.id, title=meta.title, albums=[]).id == meta.id


@pytest.mark.anyio
@pytest.mark.parametrize("catalog_id", ["5_geschwister", "100_wolf", "3berlin"])
async def test_a_catalog_id_that_starts_with_a_digit_is_a_valid_answer(
    catalog_id: str,
) -> None:
    """The agents' id rule was narrower than the catalog's. GLM-5.3 answered
    the main series of 5 Geschwister and 100% Wolf with their catalog ids,
    and the refusal ended both runs."""
    requests = 0

    def answer(_messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        nonlocal requests
        requests += 1
        return ModelResponse(
            parts=[
                ToolCallPart(
                    info.output_tools[0].name, {"id": catalog_id, "title": "X"}
                )
            ]
        )

    agent = curate_ops._build_metadata_agent(
        FunctionModel(answer), content_type="music"
    )

    result = await agent.run("Series: 'X'", deps=CurateDeps(providers=[], titles=[]))

    assert result.output.id == catalog_id
    assert requests == 1


@pytest.mark.parametrize("not_an_id", ["heidi-cgi", "Heidi", "heidi cgi", "_heidi", ""])
def test_an_id_the_catalog_would_refuse_is_still_refused(not_an_id: str) -> None:
    with pytest.raises(ValidationError):
        SeriesMetadata(id=not_an_id, title="Heidi (CGI)")
