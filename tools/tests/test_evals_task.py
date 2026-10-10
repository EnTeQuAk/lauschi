"""The eval task runs the production batch agent, prompt and settle step.

An eval that builds its own agent and prompt measures a copy. These
tests drive `run_batch_curation` with a scripted model and check the
three things the copy lacked: the production prompt (line instruction
for a sub-series, the episode range fact for a box), the production
output validator, and the deterministic steps after the batch.
"""

import pytest
from pydantic_ai.messages import ModelMessage, ModelResponse, ToolCallPart
from pydantic_ai.models.function import AgentInfo, FunctionModel

from tests.evals.task import BatchInput, SeriesContext, run_batch_curation

pytestmark = pytest.mark.anyio


def _album(album_id: str, title: str, provider: str = "spotify") -> dict[str, object]:
    return {
        "provider": provider,
        "id": album_id,
        "title": title,
        "release_date": "2015-01-01",
        "total_tracks": 3,
        "album_type": "album",
        "tracks": [{"name": f"{title} - Teil 1", "duration_ms": 600000}],
    }


def _decide(
    album_id: str, **fields: str | int | bool | None
) -> dict[str, str | int | bool | None]:
    return {
        "album_id": album_id,
        "provider": "spotify",
        "title": "echoed by the model",
        "episode_num": None,
        "include": True,
        **fields,
    }


class _Script:
    """A model that answers each request with the next scripted batch."""

    def __init__(self, *batches: list[dict[str, str | int | bool | None]]) -> None:
        self.batches = list(batches)
        self.prompts: list[str] = []

    def __call__(self, messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        self.prompts.append(
            "\n".join(
                str(part.content)
                for message in messages
                for part in message.parts
                if hasattr(part, "content")
            )
        )
        albums = self.batches[min(len(self.prompts), len(self.batches)) - 1]
        return ModelResponse(
            parts=[ToolCallPart(info.output_tools[0].name, {"albums": albums})]
        )


SUB_SERIES = SeriesContext(
    id="hexe_lilli_erstleser",
    title="Hexe Lilli Erstlesergeschichten",
    episode_pattern=r"^Folge (\d+):",
    split_from="hexe_lilli",
    main_series_title="Hexe Lilli",
    sibling_titles=["Hexe Lilli"],
)


async def test_the_model_gets_the_production_prompt() -> None:
    script = _Script(
        [
            _decide("box", episode_num=6),
            _decide("one", episode_num=12),
        ]
    )
    inp = BatchInput(
        series=SeriesContext(
            id="sam", title="Feuerwehrmann Sam", episode_pattern=r"^Folge (\d+):"
        ),
        albums=[
            _album("box", "Folgen 6-10: Das Baby im Schafspelz"),
            _album("one", "Folge 12: Alarm"),
        ],
    )

    await run_batch_curation(inp, model=FunctionModel(script))

    (prompt,) = script.prompts
    assert "Series: 'Feuerwehrmann Sam'" in prompt
    assert '<episode_range first="6" last="10" also_released_alone="none"/>' in prompt


async def test_a_sub_series_is_told_its_line() -> None:
    script = _Script([_decide("a", episode_num=2)])
    inp = BatchInput(
        series=SUB_SERIES, albums=[_album("a", "Folge 2: Feiert Geburtstag")]
    )

    await run_batch_curation(inp, model=FunctionModel(script))

    assert "a line split off from 'Hexe Lilli'" in script.prompts[0]


async def test_an_incomplete_answer_is_sent_back_by_the_output_validator() -> None:
    complete = [_decide("a", episode_num=1), _decide("b", episode_num=2)]
    script = _Script([complete[0]], complete)
    inp = BatchInput(
        series=SeriesContext(id="s", title="S", episode_pattern=r"^Folge (\d+):"),
        albums=[_album("a", "Folge 1: A"), _album("b", "Folge 2: B")],
    )

    result = await run_batch_curation(inp, model=FunctionModel(script))

    assert len(script.prompts) == 2
    assert {d.album_id for d in result.albums} == {"a", "b"}


async def test_the_result_is_what_would_ship() -> None:
    """The settle step runs: a sub-series' unsure claim goes to the main
    series, and titles and numbers come from the provider record."""
    script = _Script(
        [
            _decide("sure", episode_num=99),
            _decide(
                "unsure",
                confidence="medium",
                notes="Sonderband, maybe the main line",
            ),
        ]
    )
    inp = BatchInput(
        series=SUB_SERIES,
        albums=[
            _album("sure", "Folge 2: Feiert Geburtstag"),
            _album("unsure", "Sonderband: Weihnachten"),
        ],
    )

    result = await run_batch_curation(inp, model=FunctionModel(script))

    by = {d.album_id: d for d in result.albums}
    assert by["sure"].title == "Folge 2: Feiert Geburtstag"
    assert by["sure"].episode_num == 2
    assert by["unsure"].include is False
    assert by["unsure"].exclude_reason == "sub_series_bleed"


async def test_an_album_the_series_ships_is_its_own_even_when_unsure() -> None:
    script = _Script(
        [_decide("shipped", confidence="medium", notes="no number in the title")]
    )
    inp = BatchInput(
        series=SeriesContext(
            id=SUB_SERIES.id,
            title=SUB_SERIES.title,
            episode_pattern=SUB_SERIES.episode_pattern,
            split_from=SUB_SERIES.split_from,
            main_series_title=SUB_SERIES.main_series_title,
            ships=[("spotify", "shipped")],
        ),
        albums=[_album("shipped", "Hexe Lilli und der Elfenzauber")],
    )

    result = await run_batch_curation(inp, model=FunctionModel(script))

    assert result.albums[0].include is True
