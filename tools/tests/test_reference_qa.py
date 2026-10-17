"""The reference index QA, offline: what one entry's run is told, how its
answer is checked and resolved, and when no model runs at all."""

import asyncio
import json
from datetime import date

import pytest
from pydantic_ai.messages import ModelMessage, ModelRequest, ModelResponse, ToolCallPart
from pydantic_ai.models.function import AgentInfo, FunctionModel

from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.reference_map import EntryMapping
from lauschi_catalog.catalog.reference_qa import (
    build_qa_agent,
    qa_entry,
    qa_prompt,
)
from lauschi_catalog.reference import ReferenceEpisode, ReferenceLine, ReferenceSeries

TODAY = date(2026, 10, 17)


def _entry(series_id: str, title: str, *albums: tuple[int | None, str]) -> CatalogEntry:
    rows = [
        {
            "id": f"{series_id}-{i}",
            "episode": n,
            "title": t,
            "release_date": "2001-01-01",
        }
        for i, (n, t) in enumerate(albums)
    ]
    return CatalogEntry(
        id=series_id, title=title, providers={"spotify": ProviderConfig(albums=rows)}
    )


LINE = ReferenceLine(
    "Hörspiele",
    [
        ReferenceEpisode("1", "Die Zauberschule", None),
        ReferenceEpisode("2", "Im wilden Wilden Westen", None),
        ReferenceEpisode("3", "Der Drache", None),
        ReferenceEpisode("4", "Feiert Geburtstag", None),
    ],
)
SERIES = ReferenceSeries(10, "Hexe Lilli", [LINE])
MAPPING = EntryMapping("hexe_lilli", SERIES, (LINE,), "name")
LILLI = _entry(
    "hexe_lilli",
    "Hexe Lilli",
    (1, "Folge 1: Die Zauberschule"),
    (None, "Hexe Lilli und der Western-Spaß"),
    (None, "Lilli im Zirkus"),
)
ERSTLESER = _entry(
    "hexe_lilli_erstleser",
    "Hexe Lilli: Erstleser",
    (None, "Hexe Lilli feiert Geburtstag"),
)
EXCLUDED = [
    {
        "title": "Hexe Lilli: Der Drache (Box)",
        "include": False,
        "exclude_reason": "compilation",
        "provider": "spotify",
    }
]


def _prompt_of(messages: list[ModelMessage]) -> str:
    request = messages[0]
    assert isinstance(request, ModelRequest)
    return "\n".join(
        str(p.content) for p in request.parts if p.part_kind == "user-prompt"
    )


def test_the_prompt_names_only_what_the_match_leaves_open() -> None:
    prompt = qa_prompt(LILLI, MAPPING, [ERSTLESER], EXCLUDED, today=TODAY).text
    assert "I1 [Hörspiele 2] Im wilden Wilden Westen" in prompt
    assert "I2 [Hörspiele 3] Der Drache" in prompt
    assert "A1 Hexe Lilli und der Western-Spaß (spotify)" in prompt
    assert "A2 Lilli im Zirkus (spotify)" in prompt
    # matched under its number, and shipped by another family member
    assert "Die Zauberschule" not in prompt
    assert "Feiert Geburtstag" not in prompt
    # the left-out album near an open index episode, with its reason
    assert "Hexe Lilli: Der Drache (Box): compilation" in prompt


def _answer(findings: list[dict]) -> ModelResponse:
    return ModelResponse(parts=[ToolCallPart("submit_qa", {"findings": findings})])


COMPLETE = [
    {
        "kind": "same_story",
        "index_ref": "I1",
        "album_ref": "A1",
        "reason": "Western story.",
    },
    {
        "kind": "rightly_absent",
        "index_ref": "I2",
        "reason": "Shipped as a box, left out.",
    },
    {
        "kind": "unlisted",
        "album_ref": "A2",
        "reason": "A main episode the index lacks.",
    },
]


def test_an_answer_resolves_to_titles_and_lines() -> None:
    agent = build_qa_agent(
        FunctionModel(lambda m, i: _answer(COMPLETE)), model_name="test"
    )
    result = asyncio.run(
        qa_entry(LILLI, MAPPING, [ERSTLESER], EXCLUDED, agent=agent, today=TODAY)
    )
    same, absent, unlisted = result.findings
    assert (same.kind, same.index_title, same.album_title) == (
        "same_story",
        "Im wilden Wilden Westen",
        "Hexe Lilli und der Western-Spaß",
    )
    assert (absent.index_line, absent.index_number) == ("Hörspiele", 3)
    assert unlisted.album_title == "Lilli im Zirkus"
    assert [(ep.title, sibling) for ep, sibling in result.elsewhere] == [
        ("Feiert Geburtstag", "hexe_lilli_erstleser")
    ]
    json.dumps(result.to_json())


def test_an_answer_that_skips_an_open_item_is_sent_back() -> None:
    calls: list[int] = []

    def respond(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        calls.append(len(messages))
        return _answer(COMPLETE[:2] if len(calls) == 1 else COMPLETE)

    agent = build_qa_agent(FunctionModel(respond), model_name="test")
    result = asyncio.run(
        qa_entry(LILLI, MAPPING, [ERSTLESER], EXCLUDED, agent=agent, today=TODAY)
    )
    assert len(calls) == 2
    assert len(result.findings) == 3


def test_an_entry_with_nothing_open_runs_no_model() -> None:
    def respond(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        pytest.fail("the model ran for an entry the match settled")

    line = ReferenceLine("Hörspiele", [ReferenceEpisode("1", "Die Zauberschule", None)])
    mapping = EntryMapping(
        "hexe_lilli", ReferenceSeries(10, "Hexe Lilli", [line]), (line,), "name"
    )
    settled = _entry("hexe_lilli", "Hexe Lilli", (1, "Folge 1: Die Zauberschule"))
    agent = build_qa_agent(FunctionModel(respond), model_name="test")
    result = asyncio.run(qa_entry(settled, mapping, [], [], agent=agent, today=TODAY))
    assert result.findings == []
    assert result.match.matched == 1


def test_an_index_episode_another_family_ships_is_shipped_there() -> None:
    conni = _entry("conni", "Conni", (None, "Hexe Lilli: Der Drache"))
    prompt = qa_prompt(LILLI, MAPPING, [ERSTLESER, conni], EXCLUDED, today=TODAY)
    assert "Der Drache" not in prompt.text.split("Albums this entry leaves out")[0]
    assert [(e.title, owner) for e, owner in prompt.elsewhere] == [
        ("Der Drache", "conni"),
        ("Feiert Geburtstag", "hexe_lilli_erstleser"),
    ]


def test_an_open_album_shows_who_the_store_credits() -> None:
    prompt = qa_prompt(
        LILLI,
        MAPPING,
        [ERSTLESER],
        EXCLUDED,
        today=TODAY,
        credits=lambda album: "Hexe Lilli" if "Zirkus" in album.title else None,
    )
    assert "A2 Lilli im Zirkus (spotify; credited to Hexe Lilli)" in prompt.text
    assert "A1 Hexe Lilli und der Western-Spaß (spotify)" in prompt.text


def test_an_album_placed_by_hand_is_not_put_to_the_model_again() -> None:
    by_hand = [
        {
            "album_id": "hexe_lilli-2",
            "provider": "spotify",
            "include": True,
            "decided_by": "operator",
        }
    ]
    prompt = qa_prompt(LILLI, MAPPING, [ERSTLESER], EXCLUDED + by_hand, today=TODAY)
    assert "Lilli im Zirkus" not in prompt.text
    assert [a.title for a in prompt.by_hand] == ["Lilli im Zirkus"]
