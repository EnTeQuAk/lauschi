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

from tests.evals import task as task_module
from tests.evals.task import BatchInput, SeriesContext, run_batch_curation

pytestmark = pytest.mark.anyio


@pytest.fixture(autouse=True)
def _no_line_index(monkeypatch: pytest.MonkeyPatch) -> None:
    """The task reads the line index live. These tests stay offline."""
    monkeypatch.setattr(task_module, "shared_page_reference", lambda _brand: "")


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
    return {"provider": "spotify", "id": album_id, "include": True, **fields}


class _Script:
    """A model that answers each request with the next scripted batch."""

    def __init__(self, *batches: list[dict[str, str | int | bool | None]]) -> None:
        self.batches = list(batches)
        self.prompts: list[str] = []

    def __call__(self, messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        self.instructions = info.instructions or ""
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


def _decided(album_id: str, title: str, **fields: str | int | bool | None) -> dict:
    """A row the run decided before this batch, as a curation record."""
    return {
        "album_id": album_id,
        "provider": "spotify",
        "title": title,
        "include": True,
        "episode_num": None,
        "release_date": "2015-01-01",
        **fields,
    }


SAM = SeriesContext(
    id="sam", title="Feuerwehrmann Sam", episode_pattern=r"^Folge (\d+):"
)


async def test_what_the_run_decided_before_reaches_the_prompt() -> None:
    script = _Script([_decide("new", episode_num=4)])
    inp = BatchInput(
        series=SAM,
        albums=[_album("new", "Folge 4: Neu")],
        decided=[
            _decided("a", "Folge 1: Anfang", episode_num=1),
            _decided("c", "Folge 3: Ende", episode_num=3),
            _decided("best", "Best of", include=False, exclude_reason="compilation"),
        ],
    )

    result = await run_batch_curation(inp, model=FunctionModel(script))

    (prompt,) = script.prompts
    assert "Progress: 2 included (episodes 1-3), 1 excluded." in prompt
    assert "Missing episodes so far: [2]" in prompt
    assert [d.album_id for d in result.albums] == ["new"]


async def test_a_box_is_measured_against_the_singles_decided_before() -> None:
    script = _Script([_decide("box", episode_num=6)])
    inp = BatchInput(
        series=SAM,
        albums=[_album("box", "Folgen 6-10: Die Box")],
        decided=[_decided("seven", "Folge 7: Allein", episode_num=7)],
    )

    await run_batch_curation(inp, model=FunctionModel(script))

    assert (
        '<episode_range first="6" last="10" also_released_alone="7"/>'
        in script.prompts[0]
    )


async def test_the_answer_is_settled_together_with_what_was_decided_before() -> None:
    """A sub-series ships a title on one provider. The model leaves the
    same title on the other provider to the main series, and the settle
    step claims it as the twin."""
    script = _Script(
        [
            _decide(
                "sp-geb",
                include=False,
                exclude_reason="sub_series_bleed",
                confidence="high",
            )
        ]
    )
    inp = BatchInput(
        series=SeriesContext(
            id=SUB_SERIES.id,
            title=SUB_SERIES.title,
            episode_pattern=SUB_SERIES.episode_pattern,
            split_from=SUB_SERIES.split_from,
            main_series_title=SUB_SERIES.main_series_title,
            ships=[("apple_music", "am-geb")],
        ),
        albums=[_album("sp-geb", "Folge 2: Feiert Geburtstag")],
        decided=[
            _decided(
                "am-geb",
                "Folge 2: Feiert Geburtstag",
                provider="apple_music",
                episode_num=2,
            )
        ],
    )

    result = await run_batch_curation(inp, model=FunctionModel(script))

    (twin,) = result.albums
    assert twin.album_id == "sp-geb"
    assert twin.include is True
    assert twin.episode_num == 2


async def test_a_series_on_a_shared_page_is_given_the_brands_lines(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Whether the model looked the brand up decided the result, and it
    looked in one run of three. On a shared page the lines now come with
    the instructions, under the main series' name."""
    asked: list[str] = []

    def lines(brand: str) -> str:
        asked.append(brand)
        return "## The brand's lines in the public line index\n<line name=...>"

    monkeypatch.setattr(task_module, "shared_page_reference", lines)
    script = _Script([_decide("a", episode_num=2)])
    inp = BatchInput(
        series=SUB_SERIES, albums=[_album("a", "Folge 2: Feiert Geburtstag")]
    )

    await run_batch_curation(inp, model=FunctionModel(script))

    assert asked == ["Hexe Lilli"]
    assert "## The brand's lines in the public line index" in script.instructions


async def test_a_series_with_a_page_of_its_own_is_not(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        task_module, "shared_page_reference", lambda brand: pytest.fail(brand)
    )
    script = _Script([_decide("new", episode_num=4)])
    inp = BatchInput(series=SAM, albums=[_album("new", "Folge 4: Neu")])

    await run_batch_curation(inp, model=FunctionModel(script))

    assert "public line index\n<line" not in script.instructions
