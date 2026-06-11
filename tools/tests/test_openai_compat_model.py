"""Pin that build_openai_compat_model routes ``openai:``-prefixed
model names to a configurable OpenAI-compatible endpoint.

One generic mechanism covers hosted open-weights providers
(Cloudflare Workers AI, OpenRouter, DeepInfra) without per-provider
branches. The endpoint and key come from OPENAI_COMPAT_BASE_URL and
OPENAI_COMPAT_API_KEY; the prefix is stripped before the name reaches
the provider (Workers AI knows ``@cf/google/gemma-4-26b-a4b-it``, not
``openai:@cf/...``).
"""

from __future__ import annotations

import pytest
from pydantic_ai import InlineDefsJsonSchemaTransformer

from lauschi_catalog._opencode import build_openai_compat_model

CF_BASE = "https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1"


@pytest.fixture
def compat_env(monkeypatch):
    monkeypatch.setenv("OPENAI_COMPAT_BASE_URL", CF_BASE)
    monkeypatch.setenv("OPENAI_COMPAT_API_KEY", "test-token")


def test_strips_openai_prefix_from_model_name(compat_env):
    model = build_openai_compat_model("openai:@cf/google/gemma-4-26b-a4b-it")
    assert model.model_name == "@cf/google/gemma-4-26b-a4b-it"


def test_uses_configured_base_url(compat_env):
    model = build_openai_compat_model("openai:@cf/google/gemma-4-26b-a4b-it")
    assert model._provider.base_url == CF_BASE + "/"


def test_wires_inline_defs_transformer(compat_env):
    model = build_openai_compat_model("openai:some-model")
    assert model.profile.json_schema_transformer is InlineDefsJsonSchemaTransformer


def test_missing_base_url_raises(monkeypatch):
    monkeypatch.delenv("OPENAI_COMPAT_BASE_URL", raising=False)
    monkeypatch.setenv("OPENAI_COMPAT_API_KEY", "test-token")
    with pytest.raises(ValueError, match="OPENAI_COMPAT_BASE_URL"):
        build_openai_compat_model("openai:some-model")


def test_missing_api_key_raises(monkeypatch):
    monkeypatch.setenv("OPENAI_COMPAT_BASE_URL", CF_BASE)
    monkeypatch.delenv("OPENAI_COMPAT_API_KEY", raising=False)
    with pytest.raises(ValueError, match="OPENAI_COMPAT_API_KEY"):
        build_openai_compat_model("openai:some-model")
