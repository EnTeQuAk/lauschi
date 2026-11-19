#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyJWT[crypto]>=2.7"]
# ///
"""Signs an Apple Music developer token and writes it to a file.

The Android app fetches its developer token from auth.lauschi.app instead of
signing one itself, so the MusicKit private key never ships in the app. The
server runs this from a weekly timer with its system Python and Ubuntu's
python3-jwt package:

    python3 sign_apple_music_token.py --key /etc/lauschi/AuthKey_ABC123.p8 \\
        --key-id ABC123 --out /var/www/lauschi-token/apple_music_token

A token lasts 30 days and the app fetches a new one when fewer than 14 are
left, so a leaked token stops working within a month, and the app keeps
working through a missed run or two. The token itself isn't secret: the app
sends it with every Apple Music request.
"""

import argparse
import os
import tempfile
import time
from pathlib import Path

import jwt

TEAM_ID = "QDF8U52UF4"
LIFETIME_SECONDS = 30 * 24 * 3600


def sign_token(
    private_key: str, key_id: str, team_id: str = TEAM_ID, now: int | None = None
) -> str:
    """A developer token for MusicKit, valid for LIFETIME_SECONDS.

    See https://developer.apple.com/documentation/applemusicapi/generating-developer-tokens
    """
    issued = int(time.time()) if now is None else now
    return jwt.encode(
        {"iss": team_id, "iat": issued, "exp": issued + LIFETIME_SECONDS},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id},
    )


def write_token(path: Path, token: str) -> None:
    """Replace the file at path with the token in one step, so nginx never
    serves a half-written file."""
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(token)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--key", type=Path, required=True, help="the MusicKit .p8 file")
    parser.add_argument(
        "--key-id", required=True, help="the key's id in Apple Developer"
    )
    parser.add_argument("--team-id", default=TEAM_ID)
    parser.add_argument("--out", type=Path, required=True, help="the file nginx serves")
    args = parser.parse_args()
    write_token(args.out, sign_token(args.key.read_text(), args.key_id, args.team_id))


if __name__ == "__main__":
    main()
