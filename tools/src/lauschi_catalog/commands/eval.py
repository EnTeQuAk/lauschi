"""CLI wrapper for scoring a curator's scratch output against ground truth."""

from __future__ import annotations

from pathlib import Path

import click
from rich.console import Console

from lauschi_catalog.catalog.paths import CURATION_DIR
from lauschi_catalog.catalog.providers_init import init_providers
from lauschi_catalog.eval.report import render_table, write_json
from lauschi_catalog.eval.run import load_verdicts, score_root

console = Console()


@click.command(name="eval")
@click.option(
    "--root",
    "scratch_root",
    required=True,
    type=click.Path(exists=True, file_okay=False, path_type=Path),
    help="Scratch repo root the curator wrote into",
)
@click.option(
    "--model", required=True, help="Curator model name, recorded in the report"
)
@click.option(
    "--verdicts",
    required=True,
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    help="Canon audit verdicts (.json map or .jsonl journal)",
)
@click.option(
    "--out",
    "out_path",
    type=click.Path(dir_okay=False, path_type=Path),
    help="Write the scores as JSON here",
)
def eval_cmd(scratch_root: Path, model: str, verdicts: Path, out_path: Path | None):
    """Score the sample curations under a scratch root.

    Ground truth is the committed curation directory of the real repo,
    so run this without LAUSCHI_REPO_ROOT set. Provider discographies
    come from the warm cache; a cold cache means live calls.
    """
    truth_dir = CURATION_DIR
    if scratch_root.resolve() == truth_dir.parents[2].resolve():
        console.print(
            "[red]--root is the real repo; the truth would be scored against itself[/red]"
        )
        raise SystemExit(1)

    result = init_providers(use_cache=True)
    for warning in result.warnings:
        console.print(f"[yellow]{warning}[/yellow]")
    if len(result.providers) < 2:
        console.print(
            "[red]Both providers are needed; the curations were made with both[/red]"
        )
        raise SystemExit(1)

    scores, missing = score_root(
        scratch_root,
        model=model,
        truth_curation_dir=truth_dir,
        providers=result.providers,
        verdicts=load_verdicts(verdicts),
    )
    console.print(
        f"[bold]{model}[/bold] vs committed truth, {len(scores)} series scored"
    )
    if missing:
        console.print(f"[yellow]no curation yet for:[/yellow] {', '.join(missing)}")
    console.print(render_table(scores))
    if out_path:
        write_json(scores, out_path)
        console.print(f"wrote {out_path}")
