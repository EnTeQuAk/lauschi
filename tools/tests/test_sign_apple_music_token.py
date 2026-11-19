"""The server-side signer in tool/sign_apple_music_token.py."""

import importlib.util
import stat
from pathlib import Path
from types import ModuleType

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

_SCRIPT = Path(__file__).resolve().parents[2] / "tool" / "sign_apple_music_token.py"


def _load_signer() -> ModuleType:
    spec = importlib.util.spec_from_file_location("sign_apple_music_token", _SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signer = _load_signer()


@pytest.fixture
def key() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def _pem(key: ec.EllipticCurvePrivateKey) -> str:
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


def test_the_token_names_team_and_key_and_lasts_thirty_days(
    key: ec.EllipticCurvePrivateKey,
) -> None:
    token = signer.sign_token(_pem(key), "KEY123", "TEAM42", now=1_700_000_000)

    claims = jwt.decode(
        token,
        key.public_key(),
        algorithms=["ES256"],
        options={"verify_exp": False},
    )
    assert claims == {
        "iss": "TEAM42",
        "iat": 1_700_000_000,
        "exp": 1_700_000_000 + 30 * 24 * 3600,
    }
    assert jwt.get_unverified_header(token) == {
        "alg": "ES256",
        "kid": "KEY123",
        "typ": "JWT",
    }


def test_writing_replaces_the_served_file_and_leaves_nothing_behind(
    tmp_path: Path,
) -> None:
    served = tmp_path / "apple_music_token"
    served.write_text("old")

    signer.write_token(served, "new")

    assert served.read_text() == "new"
    assert stat.S_IMODE(served.stat().st_mode) == 0o644
    assert [p.name for p in tmp_path.iterdir()] == ["apple_music_token"]
