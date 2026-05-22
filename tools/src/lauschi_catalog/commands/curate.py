"""AI-assisted series curation (CLI wrapper).

Interactive CLI layer over catalog.curate_ops. Models, agent builders,
async orchestration, and persistence live in the library module. This
module handles CLI display with Rich formatting.
"""

from __future__ import annotations

import asyncio
import json

import click
from rich import box
from rich.console import Console
from rich.markup import escape
from rich.panel import Panel
from rich.table import Table

from lauschi_catalog.catalog.curate_ops import (
    AlbumDecision,
    BatchResult,
    CurateDeps,
    CurateOneResult,
    CuratedSeries,
    EpisodeUpdate,
    FinalizeResult,
    PatternCoverageReport,
    SeriesMetadata,
    _BATCH_SIZE,
    _DEFAULT_MODEL,
    _build_batch_agent,
    _build_batch_summary,
    _build_metadata_agent,
    _get_album_details,
    _reextract_episode_numbers,
    _restore_dropped_albums,
    _stratified_sample,
    _validate_episode_pattern,
    curate_all,
    curate_one,
    load_existing_facts,
    lock_series_id,
    lookup_catalog_entry,
    resolve_content_type,
    save_curation,
    write_cover_cache,
)
from lauschi_catalog.catalog.matcher import (
    compute_pattern_coverage as _compute_pattern_coverage,
)
from lauschi_catalog.catalog.paths import CURATION_DIR
from lauschi_catalog.prompts import load_curate_skill
from lauschi_catalog.providers.apple_music import AppleMusicProvider
from lauschi_catalog.providers.spotify import SpotifyProvider

console = Console()

# Re-export library functions so existing imports keep working.
__all__ = [
    "AlbumDecision",
    "BatchResult",
    "CurateDeps",
    "CuratedSeries",
    "EpisodeUpdate",
    "FinalizeResult",
    "PatternCoverageReport",
    "SeriesMetadata",
    "_build_batch_agent",
    "_build_batch_summary",
    "_build_metadata_agent",
    "_reextract_episode_numbers",
    "_restore_dropped_albums",
    "_stratified_sample",
    "_validate_episode_pattern",
    "save_curation",
    "write_cover_cache",
]

# Keep old private names pointing to public versions for backward compat.
_resolve_content_type = resolve_content_type
_lookup_catalog_entry = lookup_catalog_entry
_load_existing_facts = load_existing_facts
_lock_series_id = lock_series_id


def print_summary(series: CuratedSeries) -> None:
    included = series.included()
    excluded = [a for a in series.albums if not a.include]
    eps = [a.episode_num for a in included if a.episode_num is not None]
    providers_used = sorted(set(a.provider for a in included))

    ep_pat = series.episode_pattern or "(none)"
    pattern = escape(str(ep_pat))

    console.print(Panel(
        f"[bold]{escape(series.title)}[/]  [dim]{series.id}[/]\n"
        f"Providers: {', '.join(f'{k}: {v}' for k, v in series.provider_artist_ids.items())}\n"
        f"Episodes: {len(included)} included · {len(excluded)} excluded\n"
        f"Range: {min(eps) if eps else '—'}–{max(eps) if eps else '—'}\n"
        f"Pattern: {pattern}",
        title="Curated",
        border_style="green",
    ))

    if eps:
        gaps = sorted(set(range(min(eps), max(eps) + 1)) - set(eps))
        if gaps:
            console.print(
                f"[yellow]Gaps: {gaps[:20]}"
                f"{'...' if len(gaps) > 20 else ''}[/]",
            )

    table = Table(box=box.SIMPLE, title=f"Included (first 10 of {len(included)})")
    table.add_column("Ep", width=5, justify="right")
    table.add_column("Provider", width=12)
    table.add_column("Title", min_width=40)
    table.add_column("ID", width=14, style="dim")
    for a in included[:10]:
        table.add_row(
            str(a.episode_num) if a.episode_num else "—",
            a.provider, a.title[:50], a.album_id[:14],
        )
    if len(included) > 10:
        table.add_row("...", "", f"({len(included) - 10} more)", "")
    console.print(table)

    if series.age_note:
        console.print(f"\nAge: {series.age_note}")

    if series.curator_notes:
        console.print(f"\n[dim]Notes: {escape(series.curator_notes[:200])}[/]")

    if excluded:
        console.print(f"\n[dim]Excluded ({len(excluded)}):[/dim]")
        for a in excluded[:5]:
            console.print(f"  [dim]{a.provider}: {a.title} — {a.exclude_reason}[/dim]")

    console.print(f"\n[dim]Audit with: mise run catalog-audit -- {series.id}[/]")


def _init_providers(provider: str, *, no_cache: bool = False) -> list:
    providers = []
    if provider in ("spotify", "all"):
        try:
            providers.append(SpotifyProvider(use_cache=not no_cache))
        except SystemExit:
            console.print("[yellow]Spotify credentials not set, skipping[/yellow]")
    if provider in ("apple_music", "all"):
        try:
            providers.append(AppleMusicProvider(use_cache=not no_cache))
        except FileNotFoundError:
            console.print("[yellow]Apple Music key not found, skipping[/yellow]")

    if not providers:
        console.print("[red]No providers available[/red]")
        raise SystemExit(1)
    return providers


def _dry_run_prompts(query: str, content_type: str = "hoerspiel", discography_span_years: int | None = None) -> None:
    """Print assembled prompts without calling the API."""
    batch = load_curate_skill(phase="batch", content_type=content_type, discography_span_years=discography_span_years)
    metadata = load_curate_skill(phase="metadata", content_type=content_type, discography_span_years=discography_span_years)
    finalize = load_curate_skill(phase="finalize", content_type=content_type, discography_span_years=discography_span_years)

    console.print(Panel("Batch system prompt", border_style="blue"))
    console.print(batch)
    console.print()

    console.print(Panel("Metadata system prompt", border_style="blue"))
    console.print(metadata)
    console.print()

    console.print(Panel("Finalize system prompt", border_style="blue"))
    console.print(finalize)
    console.print()

    sample_batch = [
        {"provider": "spotify", "id": "abc123", "name": "Folge 1: Der Anfang", "total_tracks": 3, "release_date": "2020-01-15"},
        {"provider": "apple_music", "id": "def456", "name": "Folge 2: Die Reise", "total_tracks": 4, "release_date": "2020-03-20"},
    ]
    album_lines = "\n".join(
        f"  {a['provider']}:{a['id']} | {a['name']} | {a['total_tracks']} tracks | {a['release_date']}"
        for a in sample_batch
    )
    sample_user = (
        f"Series: {query!r}\n"
        f"Episode pattern: ^Folge (\\d+):\n"
        f"Progress: 0 included, 0 excluded.\n\n"
        f"Batch 1/1 (2 albums):\n\n{album_lines}"
    )
    console.print(Panel("Sample batch user prompt", border_style="blue"))
    console.print(sample_user)


@click.command()
@click.argument("query", required=False)
@click.option("--all", "run_all", is_flag=True, help="Curate all series in the catalog")
@click.option("--force", is_flag=True, help="Re-curate even if curation JSON exists")
@click.option("--model", default=_DEFAULT_MODEL, help="AI model to use")
@click.option(
    "--timeout", default=3600,
    help="Timeout per series in seconds (default 60 min). Big series "
    "with many batches and tool calls genuinely take 30+ min; the old "
    "1800 default was timing out 14 series in the catalog.",
)
@click.option("--provider", "-p", type=click.Choice(["spotify", "apple_music", "all"]), default="all")
@click.option("--no-cache", is_flag=True, help="Bypass provider API cache")
@click.option("--music", is_flag=True, help="Curate as music artist (not Hörspiel series)")
@click.option("--content-type", type=click.Choice(["hoerspiel", "music", "audiobook"]), default=None, help="Content type override")
@click.option("--dry-run", is_flag=True, help="Print assembled prompts without calling the API")
def curate(
    query: str | None,
    run_all: bool,
    force: bool,
    model: str,
    timeout: int,
    provider: str,
    no_cache: bool,
    music: bool,
    content_type: str | None,
    dry_run: bool,
):
    """AI-curate a Hörspiel series or music artist across providers.

    Pass a series name to curate one, or --all to curate the entire catalog.
    Existing curations are skipped unless --force is given.
    Use --music for children's music artists (includes albums, not episodes).
    """
    if not query and not run_all:
        console.print("[red]Provide a series name or use --all[/red]")
        raise SystemExit(1)

    providers = _init_providers(provider, no_cache=no_cache)
    provider_names = ", ".join(p.name for p in providers)

    cli_content_type: str | None = content_type
    if cli_content_type is None and music:
        cli_content_type = "music"

    if query and not run_all:
        entry = lookup_catalog_entry(query)
        if entry is not None:
            existing: dict | None = None
            curation_path = CURATION_DIR / f"{entry.id}.json"
            if curation_path.exists():
                try:
                    existing = json.loads(curation_path.read_text())
                except (OSError, json.JSONDecodeError):
                    existing = None
            entry_content_type = resolve_content_type(
                entry_content_type=entry.content_type,
                entry_has_pattern=bool(entry.episode_pattern),
                existing_content_type=(existing or {}).get("content_type"),
            )
            resolved_type = cli_content_type or entry_content_type
            console.print(
                Panel(
                    f"Curating [bold]{entry.title}[/bold] with {model}\n"
                    f"Catalog id: {entry.id}\n"
                    f"Content type: {resolved_type}\n"
                    f"Providers: {provider_names}",
                    title="lauschi-catalog curate",
                ),
            )
            if cli_content_type and cli_content_type != entry_content_type:
                console.print(
                    f"[yellow]Note: --content-type {cli_content_type} overrides "
                    f"series.yaml value {entry_content_type}. "
                    f"Edit series.yaml to make permanent.[/yellow]",
                )

            if dry_run:
                console.print(f"  [cyan]Mode: {resolved_type} (dry run)[/]")
                _dry_run_prompts(query, content_type=resolved_type)
                return

            result = asyncio.run(curate_one(
                entry.title, providers,
                model=model, timeout=timeout,
                series_id=entry.id,
                known_artist_ids=entry.all_artist_ids() or None,
                existing_curation=existing,
                content_type=resolved_type,
                existing_facts=load_existing_facts(entry),
                on_progress=lambda msg: console.print(msg),
            ))
            if result.ok and result.series:
                print_summary(result.series)
            if not result.ok:
                raise SystemExit(1)
            return

        # New series not yet in series.yaml
        resolved_type = cli_content_type or "hoerspiel"
        console.print(
            Panel(
                f"Curating [bold]{query}[/bold] with {model}\n"
                f"Providers: {provider_names}\n"
                f"[dim]Not in series.yaml; treating as new "
                f"{resolved_type}.[/dim]",
                title="lauschi-catalog curate",
            ),
        )

        if dry_run:
            console.print(f"  [cyan]Mode: {resolved_type} (dry run)[/]")
            _dry_run_prompts(query, content_type=resolved_type)
            return

        result = asyncio.run(curate_one(
            query, providers,
            model=model, timeout=timeout,
            content_type=resolved_type,
            on_progress=lambda msg: console.print(msg),
        ))
        if result.ok and result.series:
            print_summary(result.series)
        if not result.ok:
            raise SystemExit(1)
        return

    # --all mode
    console.print(
        Panel(
            f"Curating [bold]{len(providers)} provider(s)[/bold] with {model}\n"
            f"Providers: {provider_names}\n"
            f"Force: {force}",
            title="lauschi-catalog curate --all",
        ),
    )

    all_result = asyncio.run(curate_all(
        providers,
        model=model, timeout=timeout,
        force=force,
        on_progress=lambda msg: console.print(msg),
    ))

    console.print(
        f"\n[bold]Results:[/bold] {all_result.succeeded} curated, "
        f"{all_result.skipped} skipped, {all_result.failed} failed",
    )
    if all_result.failed_ids:
        console.print(f"[red]Failed: {', '.join(all_result.failed_ids)}[/red]")
