"""Interactive TUI for reviewing curations.

Wraps the existing scripts/review-curation.py which uses Textual for
a full interactive review experience. This command ensures the right
dependencies are available and launches the TUI.

The TUI reads curation JSONs from assets/catalog/curation/ and lets
you approve/reject/edit individual albums, then writes approved
curations to series.yaml.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import click
from rich.console import Console

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "review-curation.py"


@click.command("review-tui")
@click.argument("series_id", required=False)
def review_tui(series_id: str | None):
    """Open the interactive TUI for reviewing curations.

    Shows all curations with their approval status. Lets you
    approve, reject, and edit individual albums interactively.
    """
    if not SCRIPT_PATH.exists():
        console.print(f"[red]TUI script not found: {SCRIPT_PATH}[/red]")
        raise SystemExit(1)

    cmd = ["uv", "run", str(SCRIPT_PATH)]
    if series_id:
        cmd.append(series_id)

    console.print("[dim]Launching review TUI...[/dim]")
    result = subprocess.run(
        cmd,
        cwd=str(REPO_ROOT),
        env={**os.environ},
    )
    raise SystemExit(result.returncode)
