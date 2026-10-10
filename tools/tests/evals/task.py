"""Task function for curation evals.

Runs one batch through the production batch agent, the production
prompt and the deterministic steps that follow a batch, so a case is
scored on what the catalog would ship. Nothing here builds an agent or
a prompt of its own.

A case is one batch somewhere in a run. It carries what the run reads
besides the batch itself: the catalog facts of the series
(`SeriesContext`) and what the run had decided before this batch
(`BatchInput.decided`). The live catalog changes with every apply, and
a case must not change with it.
"""

import os
from dataclasses import dataclass, field

from pydantic import ConfigDict
from pydantic.dataclasses import dataclass as checked_dataclass
from pydantic_ai.models import Model

from lauschi_catalog._opencode import build_model, model_api_key
from lauschi_catalog.catalog.curate_ops import (
    AlbumDecision,
    BatchResult,
    CurateDeps,
    _build_batch_agent,
    _run_agent,
    _run_with_retry,
    batch_prompt,
    settle_batch_decisions,
    shared_page_reference,
)
from lauschi_catalog.catalog.episode_range import numbers_released_alone, range_facts
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig

MODEL_NAME = os.environ.get("EVAL_MODEL", "kimi-k2.6")


@checked_dataclass(frozen=True, config=ConfigDict(extra="forbid"))
class SeriesContext:
    """What series.yaml says about the series of a case.

    Checked on construction, so a case file with a misspelt or mistyped
    fact is refused when it is loaded.
    """

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
    """One batch of a run: the series, the albums to decide, and what
    the run had decided before."""

    series: SeriesContext
    albums: list[dict]
    #: curation records (album_id, provider, title, include, episode_num,
    #: exclude_reason, release_date) of the albums decided before this
    #: batch. For a sub-series these are the albums it ships.
    decided: list[dict] = field(default_factory=list)


async def run_batch_curation(
    inp: BatchInput, *, model: Model | None = None
) -> BatchResult:
    """Decide one batch the way a curate run does, and settle the result.

    This is the task function pydantic_evals calls per case. ``model``
    replaces the eval model in the offline tests.
    """
    series = inp.series
    shared_page = bool(series.sibling_titles or series.main_series_title)
    agent = _build_batch_agent(
        model or build_model(MODEL_NAME, model_api_key()),
        model_name=MODEL_NAME,
        content_type=series.content_type,
        discography_span_years=series.discography_span_years,
        # read live, like the tools: the line index is not part of a case
        page_reference=shared_page_reference(series.main_series_title or series.title)
        if shared_page
        else "",
    )
    decisions = [AlbumDecision.model_validate(row) for row in inp.decided]
    batch = [
        {
            "provider": a["provider"],
            "id": a["id"],
            "name": a["title"],
            "release_date": a.get("release_date"),
        }
        for a in inp.albums
    ]
    page = batch + [
        {
            "provider": d.provider,
            "id": d.album_id,
            "name": d.title,
            "release_date": d.release_date,
        }
        for d in decisions
    ]
    seen_details = {f"{a['provider']}:{a['id']}": a for a in inp.albums}
    prompt = batch_prompt(
        batch,
        decisions,
        series_title=series.title,
        pattern=series.episode_pattern,
        seen_details=seen_details,
        run_facts=range_facts(
            page, series.episode_pattern, numbers_released_alone(decisions)
        ),
        sibling_titles=series.sibling_titles,
        line_of=series.main_series_title,
        batch_num=1,
        n_batches=1,
    )
    deps = CurateDeps(
        pattern=series.episode_pattern,
        pattern_from_catalog=series.episode_pattern is not None,
        titles=[a["name"] for a in page],
        seen_details=seen_details,
    )
    deps.current_batch_ids = {(a["provider"], a["id"]) for a in batch}

    result: BatchResult = await _run_with_retry(
        lambda: _run_agent(agent, prompt, deps), phase="eval batch"
    )
    decisions.extend(result.albums)
    settle_batch_decisions(
        decisions,
        discovered=page,
        pattern=deps.pattern,
        entry=series.entry(),
        line_of=series.main_series_title,
        series_names=[series.title, *series.aliases],
        seen_details=seen_details,
    )
    return BatchResult(
        albums=[
            d for d in decisions if (d.provider, d.album_id) in deps.current_batch_ids
        ]
    )
