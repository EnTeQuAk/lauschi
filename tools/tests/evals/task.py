"""Task function for curation evals.

Runs one batch through the production batch agent, the production
prompt and the deterministic steps that follow a batch, so a case is
scored on what the catalog would ship. Nothing here builds an agent or
a prompt of its own.

A case carries its own copy of the catalog facts the run reads
(`SeriesContext`). The live catalog changes with every apply, and a case
must not change with it.
"""

import os
from dataclasses import dataclass, field

from pydantic_ai.models import Model

from lauschi_catalog._opencode import build_model, model_api_key
from lauschi_catalog.catalog.curate_ops import (
    BatchResult,
    CurateDeps,
    _build_batch_agent,
    _run_agent,
    _run_with_retry,
    build_batch_prompt,
    settle_batch_decisions,
)
from lauschi_catalog.catalog.episode_range import range_facts
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.prompt import format_albums_xml

MODEL_NAME = os.environ.get("EVAL_MODEL", "kimi-k2.6")


@dataclass(frozen=True)
class SeriesContext:
    """What series.yaml says about the series of a case."""

    id: str
    title: str
    content_type: str = "hoerspiel"
    episode_pattern: str | list[str] | None = None
    aliases: list[str] = field(default_factory=list)
    discography_span_years: int | None = None
    #: set for a sub-series, together with the main series' title
    split_from: str | None = None
    main_series_title: str | None = None
    #: titles of the other entries on the same artist pages
    sibling_titles: list[str] = field(default_factory=list)
    #: (provider, album_id) of what the entry ships today
    ships: list[tuple[str, str]] = field(default_factory=list)

    def entry(self) -> CatalogEntry:
        providers: dict[str, ProviderConfig] = {}
        for provider, album_id in self.ships:
            config = providers.setdefault(provider, ProviderConfig())
            config.album_ids.append(album_id)
            config.albums.append({"id": album_id})
        return CatalogEntry(
            id=self.id,
            title=self.title,
            aliases=list(self.aliases),
            episode_pattern=self.episode_pattern,
            content_type=self.content_type,
            split_from=self.split_from,
            providers=providers,
        )


@dataclass
class BatchInput:
    """One batch: the series context and the albums to decide."""

    series: SeriesContext
    albums: list[dict]
    #: other releases on the same provider pages, as discovery rows with
    #: "provider", "id", "name" and "release_date". They are not decided,
    #: but an episode range fact is computed against the whole page. The
    #: batch's own albums always count.
    page: list[dict] = field(default_factory=list)
    prior_summary: str = ""


def _page_rows(inp: BatchInput) -> list[dict]:
    own = [
        {
            "provider": a["provider"],
            "id": a["id"],
            "name": a["title"],
            "release_date": a.get("release_date"),
        }
        for a in inp.albums
    ]
    return own + inp.page


async def run_batch_curation(
    inp: BatchInput, *, model: Model | None = None
) -> BatchResult:
    """Decide one batch the way a curate run does, and settle the result.

    This is the task function pydantic_evals calls per case. ``model``
    replaces the eval model in the offline tests.
    """
    series = inp.series
    agent = _build_batch_agent(
        model or build_model(MODEL_NAME, model_api_key()),
        model_name=MODEL_NAME,
        content_type=series.content_type,
        discography_span_years=series.discography_span_years,
    )
    page = _page_rows(inp)
    run_facts = range_facts(page, series.episode_pattern)
    albums = [
        {**a, "episode_range": run_facts[key]}
        if (key := (a["provider"], a["id"])) in run_facts
        else a
        for a in inp.albums
    ]
    prompt = build_batch_prompt(
        series_title=series.title,
        pattern=series.episode_pattern,
        progress_text="Progress: 0 included, 0 excluded.",
        rolling=inp.prior_summary,
        structural_hints=[],
        sibling_titles=series.sibling_titles,
        batch_num=1,
        n_batches=1,
        n_albums=len(inp.albums),
        albums_xml=format_albums_xml(albums, include_tracks=True),
        line_of=series.main_series_title,
    )
    seen_details = {f"{a['provider']}:{a['id']}": a for a in inp.albums}
    deps = CurateDeps(
        pattern=series.episode_pattern,
        pattern_from_catalog=series.episode_pattern is not None,
        titles=[a["title"] for a in inp.albums],
        seen_details=seen_details,
    )
    deps.current_batch_ids = {(a["provider"], a["id"]) for a in inp.albums}

    result: BatchResult = await _run_with_retry(
        lambda: _run_agent(agent, prompt, deps), phase="eval batch"
    )
    decisions = list(result.albums)
    settle_batch_decisions(
        decisions,
        discovered=page,
        pattern=deps.pattern,
        entry=series.entry(),
        line_of=series.main_series_title,
        series_names=[series.title, *series.aliases],
        seen_details=seen_details,
    )
    return BatchResult(albums=decisions)
