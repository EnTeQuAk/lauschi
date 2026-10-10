"""The batch agent asks the model for its decision and nothing else.

A batch shows every album as ``<album provider=".." id="..">``, and the
model answers in those words: provider, id, include, a reason, its
confidence and a note. Title, release date and episode number are in
the provider record and the pattern, so code fills them in.
"""

import pytest
from pydantic_ai.messages import ModelMessage, ModelResponse, ToolCallPart
from pydantic_ai.models.function import AgentInfo, FunctionModel

from lauschi_catalog.catalog.curate_ops import (
    AlbumAnswer,
    BatchAnswer,
    CurateDeps,
    _build_batch_agent,
    decisions_from_answer,
)
from tests.factories import discovered_album

pytestmark = pytest.mark.anyio


class _Answers:
    """A model that gives the same answer to every request. It counts the
    requests and keeps what it was last told."""

    def __init__(self, *albums: dict[str, str | int | bool | None]) -> None:
        self.albums = list(albums)
        self.requests = 0
        self.told = ""

    def __call__(self, messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        self.requests += 1
        self.told = "\n".join(
            str(part.content) for part in messages[-1].parts if hasattr(part, "content")
        )
        return ModelResponse(
            parts=[ToolCallPart(info.output_tools[0].name, {"albums": self.albums})]
        )


def _deps(*batch_ids: tuple[str, str]) -> CurateDeps:
    deps = CurateDeps()
    deps.current_batch_ids = set(batch_ids)
    return deps


async def test_the_decision_in_the_batchs_own_words_is_a_complete_answer() -> None:
    model = _Answers(
        {
            "provider": "spotify",
            "id": "film",
            "include": False,
            "exclude_reason": "sub_series_bleed",
            "confidence": "high",
            "notes": "Kinofilm Hörspiel, the sibling entry's",
        },
        {"provider": "apple_music", "id": "ep", "include": True, "confidence": "high"},
    )
    agent = _build_batch_agent(FunctionModel(model), model_name="test")

    result = await agent.run(
        "batch", deps=_deps(("spotify", "film"), ("apple_music", "ep"))
    )

    assert model.requests == 1
    assert result.output == BatchAnswer(
        albums=[
            AlbumAnswer(
                provider="spotify",
                id="film",
                include=False,
                exclude_reason="sub_series_bleed",
                notes="Kinofilm Hörspiel, the sibling entry's",
            ),
            AlbumAnswer(provider="apple_music", id="ep", include=True),
        ]
    )


async def test_an_unsure_answer_without_a_note_is_sent_back() -> None:
    model = _Answers(
        {"provider": "spotify", "id": "a", "include": True, "confidence": "medium"}
    )
    agent = _build_batch_agent(FunctionModel(model), model_name="test")

    with pytest.raises(Exception, match="output retries"):
        await agent.run("batch", deps=_deps(("spotify", "a")))

    assert model.requests == 3


async def test_an_answer_that_is_not_the_batch_is_sent_back() -> None:
    """One decision for every album of the batch, and for no other."""
    model = _Answers(
        {"provider": "spotify", "id": "a1", "include": True},
        {
            "provider": "spotify",
            "id": "a3",
            "include": False,
            "exclude_reason": "compilation",
        },
    )
    agent = _build_batch_agent(FunctionModel(model), model_name="test")

    with pytest.raises(Exception, match="output retries"):
        await agent.run("batch", deps=_deps(("spotify", "a1"), ("spotify", "a2")))

    assert "omitted 1 album(s). Missing: spotify:a2" in model.told
    assert "added 1 extra album(s). Extra: spotify:a3" in model.told


async def test_an_answer_with_an_album_too_many_is_sent_back() -> None:
    model = _Answers(
        {"provider": "spotify", "id": "a1", "include": True},
        {"provider": "spotify", "id": "a2", "include": True},
    )
    agent = _build_batch_agent(FunctionModel(model), model_name="test")

    with pytest.raises(Exception, match="output retries"):
        await agent.run("batch", deps=_deps(("spotify", "a1")))

    assert "added 1 extra album(s). Extra: spotify:a2" in model.told
    assert "omitted" not in model.told


def test_an_album_answered_twice_is_accepted_as_it_is() -> None:
    """The check after a batch compares sets of albums, so it does not see
    the same album twice. This pins what happens today."""
    answer = BatchAnswer(
        albums=[
            AlbumAnswer(provider="spotify", id="a1", include=True),
            AlbumAnswer(
                provider="spotify", id="a1", include=False, exclude_reason="compilation"
            ),
        ]
    )
    assert len(answer.albums) == 2


PATTERN = r"^Folge (\d+):"


def test_title_and_release_date_come_from_the_provider_record() -> None:
    batch = [
        {
            **discovered_album("spotify", "a", "Folge 2: Feiert Geburtstag"),
            "release_date": "2013-11-22",
        }
    ]
    answer = BatchAnswer(albums=[AlbumAnswer(provider="spotify", id="a", include=True)])

    decisions, unknown = decisions_from_answer(
        answer, batch, pattern=PATTERN, decided_by="kimi-k2.6"
    )

    (decision,) = decisions
    assert unknown == []
    assert decision.album_id == "a"
    assert decision.title == "Folge 2: Feiert Geburtstag"
    assert decision.release_date == "2013-11-22"
    assert decision.decided_by == "kimi-k2.6"
    assert decision.decided_at is not None


def test_the_number_is_the_titles_not_the_models() -> None:
    """The next batch's prompt reads the numbers decided so far, so an
    included album is numbered from its title at once. A number the
    model adds is not part of the answer."""
    batch = [
        discovered_album("spotify", "ep", "Folge 2: Feiert Geburtstag"),
        discovered_album("spotify", "box", "Folgen 6-10: Das Baby im Schafspelz"),
        discovered_album("spotify", "special", "Sonderfolge: Die Geisterinsel"),
        discovered_album("spotify", "out", "Folge 3: Als Karaoke"),
    ]
    answer = BatchAnswer.model_validate(
        {
            "albums": [
                {"provider": "spotify", "id": "ep", "include": True, "episode_num": 99},
                {"provider": "spotify", "id": "box", "include": True},
                {"provider": "spotify", "id": "special", "include": True},
                {
                    "provider": "spotify",
                    "id": "out",
                    "include": False,
                    "exclude_reason": "format_variant",
                },
            ]
        }
    )

    decisions, _ = decisions_from_answer(
        answer, batch, pattern=PATTERN, decided_by="kimi-k2.6"
    )

    assert {d.album_id: d.episode_num for d in decisions} == {
        "ep": 2,
        "box": 6,
        "special": None,
        "out": None,
    }
