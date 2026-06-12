"""4-eye audit CLI wrapper.

Thin CLI layer over catalog.audit_ops. All business logic lives in
the library module.
"""

from __future__ import annotations

import asyncio
import json

import click
from rich.console import Console

from lauschi_catalog.catalog.audit_ops import (
    _DEFAULT_MODEL,
    audit_series,
)
from lauschi_catalog.catalog.loader import load_raw
from lauschi_catalog.catalog.paths import CURATION_DIR
from lauschi_catalog.catalog.providers_init import init_providers

console = Console()


@click.command(name="audit")
@click.option("-s", "--series", help="Series ID (default: all missing)")
@click.option("-m", "--model", default=_DEFAULT_MODEL, help="Audit model")
@click.option("-t", "--timeout", default=600, help="Timeout per series")
@click.option("--force", is_flag=True, help="Re-audit even if already done")
@click.option("--dry-run", is_flag=True, help="Print, don't save")
def audit(
    series: str | None,
    model: str,
    timeout: int,
    force: bool,
    dry_run: bool,
) -> None:
    """Run 4-eye audit on curated series."""
    if series:
        series_ids = [series]
    else:
        catalog = load_raw()
        series_ids = []
        for entry in catalog.get("series", []):
            sid = entry.get("id", "")
            path = CURATION_DIR / f"{sid}.json"
            if not path.exists():
                continue
            curation = json.loads(path.read_text())
            review = curation.get("review", {})
            status = review.get("status", "")
            if status not in ("approved", "audited", "rejected") or force:
                series_ids.append(sid)

    if not series_ids:
        console.print("[dim]No series to audit.[/]")
        return

    prov_result = init_providers()
    for w in prov_result.warnings:
        console.print(f"[yellow]{w}[/yellow]")

    asyncio.run(
        audit_series(
            series_ids,
            model_name=model,
            timeout=timeout,
            force=force,
            dry_run=dry_run,
            providers=prov_result.providers,
            on_progress=lambda msg: console.print(msg),
        )
    )
