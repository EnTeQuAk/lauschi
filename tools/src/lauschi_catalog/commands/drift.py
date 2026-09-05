"""Detect albums whose provider record drifted away from ours (CLI wrapper).

Thin CLI layer over catalog.drift_ops. All logic lives in the library
module so it can be tested without the network.
"""

import json
from datetime import UTC, datetime
from pathlib import Path

import click
from rich.console import Console
from rich.markup import escape
from rich.table import Table

from lauschi_catalog.catalog.drift_ops import (
    DriftSeverity,
    apply_cosmetic_titles,
    detect_drift,
)
from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.paths import repo_root
from lauschi_catalog.catalog.providers_init import init_providers

console = Console()

_STYLES = {
    DriftSeverity.gone: "red",
    DriftSeverity.critical: "red",
    DriftSeverity.warning: "yellow",
    DriftSeverity.info: "dim",
    DriftSeverity.pending: "cyan",
}


@click.command()
@click.option(
    "--provider",
    "-p",
    type=click.Choice(["spotify", "apple_music", "all"]),
    default="all",
)
@click.option("--series", "-s", help="Filter to series whose title or id matches")
@click.option(
    "--all",
    "include_excluded",
    is_flag=True,
    help="Also check excluded albums (default: only what ships)",
)
@click.option(
    "--fix-titles",
    is_flag=True,
    help="Adopt provider wording for cosmetic-only title changes",
)
@click.option("--no-report", is_flag=True, help="Skip writing the JSON report")
def drift(
    provider: str,
    series: str | None,
    include_excluded: bool,
    fix_titles: bool,
    no_report: bool,
) -> None:
    """Check every stored album against its live provider record.

    Verifies that album IDs still resolve AND still point at the content
    we recorded. An ID that quietly moved to another episode is invisible
    to `validate`, which only checks that it resolves.
    """
    result_init = init_providers(provider, use_cache=False)
    for warning in result_init.warnings:
        console.print(f"[yellow]{warning}[/yellow]")
    providers = result_init.providers
    if not providers:
        console.print("[red]No providers available[/red]")
        raise SystemExit(1)

    entries = load_catalog()
    if series:
        needle = series.lower()
        entries = [e for e in entries if needle in e.title.lower() or needle in e.id]
        if not entries:
            console.print(f"[red]No series matching {series!r}[/red]")
            raise SystemExit(1)

    result = detect_drift(
        entries,
        providers,
        included_only=not include_excluded,
        on_progress=lambda msg: console.print(msg, markup=False),
    )

    for severity in DriftSeverity:
        findings = result.by_severity(severity)
        if not findings:
            continue
        table = Table(title=f"{severity.value.upper()} ({len(findings)})")
        table.add_column("Series", style="cyan", max_width=26)
        table.add_column("Prov", width=4)
        table.add_column("Album ID", max_width=24)
        table.add_column("Recorded", max_width=32)
        table.add_column("Live", max_width=32)
        table.add_column("What moved", max_width=40)
        for f in findings:
            table.add_row(
                escape(f.series_id),
                f.provider[:2],
                f.album_id,
                escape(f.stored_title[:32]),
                escape((f.live_title or "—")[:32]),
                escape(f.detail[:40]),
                style=_STYLES[severity],
            )
        console.print(table)

    if result.divergence:
        table = Table(title=f"YAML/CURATION DIVERGENCE ({len(result.divergence)})")
        table.add_column("Difference", max_width=140)
        for message in result.divergence:
            table.add_row(escape(message))
        console.print(table)

    checked = sum(result.checked.values())
    if not result.findings:
        console.print(f"[green]No drift across {checked} albums[/green]")
    else:
        summary = ", ".join(f"{n} {name}" for name, n in result.counts.items())
        console.print(f"\n[bold]{checked} albums checked:[/bold] {summary}")
    if result.unverified:
        console.print(
            f"[yellow]{len(result.unverified)} albums could not be reached "
            f"and were skipped (not treated as missing)[/yellow]"
        )
    if result.unresolved_series:
        console.print(
            f"[yellow]{len(result.unresolved_series)} series had albums in "
            f"series.yaml but no curation records to compare[/yellow]"
        )

    if fix_titles:
        healed = apply_cosmetic_titles(result)
        console.print(
            f"[green]Adopted provider wording for {healed} cosmetic "
            f"title changes[/green]"
            if healed
            else "[dim]No cosmetic title changes to adopt[/dim]"
        )
        console.print("[dim]Run catalog-apply to push them into series.yaml[/dim]")

    if not no_report:
        stamp = datetime.now(tz=UTC).strftime("%Y%m%d-%H%M%S")
        path = Path(repo_root()) / "logs" / "catalog" / f"drift-{stamp}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {
                    "checked": result.checked,
                    "counts": result.counts,
                    "divergence": result.divergence,
                    "unresolved_series": result.unresolved_series,
                    "unverified": result.unverified,
                    "findings": [
                        {
                            "series_id": f.series_id,
                            "provider": f.provider,
                            "album_id": f.album_id,
                            "severity": f.severity.value,
                            "detail": f.detail,
                            "stored_title": f.stored_title,
                            "live_title": f.live_title,
                            "stored_episode": f.stored_episode,
                            "live_episode": f.live_episode,
                        }
                        for f in result.findings
                    ],
                },
                indent=2,
                ensure_ascii=False,
            )
            + "\n"
        )
        console.print(f"[dim]Report: {path.relative_to(repo_root())}[/dim]")

    if result.by_severity(DriftSeverity.critical) or result.by_severity(
        DriftSeverity.gone
    ):
        raise SystemExit(2)
