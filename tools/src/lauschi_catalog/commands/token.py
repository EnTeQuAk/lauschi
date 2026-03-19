"""Generate provider tokens."""

from __future__ import annotations

import time
from pathlib import Path

import click
import jwt
from rich.console import Console

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
KEY_PATH = REPO_ROOT / "android" / "app" / "AuthKey_PWHK2R76T9.p8"
TEAM_ID = "QDF8U52UF4"
KEY_ID = "PWHK2R76T9"


@click.command()
@click.argument("provider", type=click.Choice(["apple-music"]))
@click.option("--days", default=180, help="Token validity in days (max 180)")
def token(provider: str, days: int):
    """Generate a developer token for a provider."""
    if provider == "apple-music":
        _generate_apple_music_token(days)


def _generate_apple_music_token(days: int):
    if not KEY_PATH.exists():
        console.print(f"[red]Key not found at {KEY_PATH}[/red]")
        raise SystemExit(1)

    key = KEY_PATH.read_text()
    now = int(time.time())
    lifetime = min(days, 180) * 24 * 60 * 60

    tok = jwt.encode(
        {"iss": TEAM_ID, "iat": now, "exp": now + lifetime},
        key,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )

    console.print(tok)
    console.print()
    console.print(f"Add to .env.app: APPLE_MUSIC_DEVELOPER_TOKEN={tok}")
