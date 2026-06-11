"""Shared model construction for AI providers.

Originally built for the opencode-zen relay; now also supports
Mistral via their native pydantic-ai integration.
"""

from __future__ import annotations

import os

import httpx
from pydantic_ai import InlineDefsJsonSchemaTransformer
from lauschi_catalog._mistral_patch import PatchedMistralModel
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.profiles.openai import OpenAIModelProfile
from pydantic_ai.providers.mistral import MistralProvider
from pydantic_ai.providers.ollama import OllamaProvider
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.settings import ModelSettings

OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"

# Model names with this prefix run against a local Ollama server
# instead of a hosted API. The prefix is stripped before the name
# reaches the server: ``ollama:gemma4:12b`` -> ``gemma4:12b``.
OLLAMA_PREFIX = "ollama:"

# Local CPU inference is slow: a thinking model at single-digit tok/s
# can spend far more than the OpenAI client's default 600s on one
# turn. A client-side cancel mid-generation surfaces as an Ollama 500
# and retries deterministically hit the same wall.
OLLAMA_REQUEST_TIMEOUT_S = 1800

# Model names with this prefix run against a configurable
# OpenAI-compatible endpoint (Cloudflare Workers AI, OpenRouter,
# DeepInfra, ...). Endpoint and key come from OPENAI_COMPAT_BASE_URL
# and OPENAI_COMPAT_API_KEY. The prefix is stripped before the name
# reaches the provider.
OPENAI_COMPAT_PREFIX = "openai:"

# Per-phase defaults for deterministic analytical classification.
# temperature=0.0 for strict reproducibility; 0.1 for tasks needing slight
# exploration (clustering, interpretation). Same seed across phases
# because prompts are always different.
_DEFAULT_CURATE = ModelSettings(temperature=0.0, seed=42)
_DEFAULT_FINALIZE = ModelSettings(temperature=0.1, seed=42)
_DEFAULT_AUDIT = ModelSettings(temperature=0.0, seed=42)

# Model-specific overrides. Keyed by model-name prefix; first match wins.
# Use this to tune per-model behavior as we discover what each model
# needs. Format: {prefix: {phase: ModelSettings(...)}}.
_OVERRIDES: dict[str, dict[str, ModelSettings]] = {
    # Mistral Small 4: experimentation shows pattern induction (regex
    # construction) is the capability gap, not reasoning. Higher
    # temperature improves calibration but doesn't fix regex abstraction.
    # See model-comparison.md for full analysis.
    "mistral-small-2603": {
        "curate": ModelSettings(temperature=0.0, seed=42, extra_body={"reasoning_effort": "none"}),
        "finalize": ModelSettings(temperature=0.1, seed=42, extra_body={"reasoning_effort": "none"}),
        "audit": ModelSettings(temperature=0.0, seed=42, extra_body={"reasoning_effort": "none"}),
    },
    # Gemma 4 on local CPU: unbounded thinking blows past any sane
    # request timeout (observed 30-minute reasoning marathons on a
    # single metadata turn at ~8 tok/s). Ollama maps reasoning_effort
    # "none" to think-off; answers stay correct on the smoke task.
    "ollama:gemma4": {
        "curate": ModelSettings(temperature=0.0, seed=42, extra_body={"reasoning_effort": "none"}),
        "finalize": ModelSettings(temperature=0.1, seed=42, extra_body={"reasoning_effort": "none"}),
        "audit": ModelSettings(temperature=0.0, seed=42, extra_body={"reasoning_effort": "none"}),
    },
}


def get_model_settings(phase: str, model_name: str) -> ModelSettings:
    """Return ModelSettings for a given pipeline phase and model.

    Looks up model-specific overrides by prefix match, falls back to
    phase defaults. Use this in every Agent constructor so tuning is
    centralized and model-aware.
    """
    defaults = {
        "curate": _DEFAULT_CURATE,
        "finalize": _DEFAULT_FINALIZE,
        "audit": _DEFAULT_AUDIT,
    }
    for prefix, phases in _OVERRIDES.items():
        if model_name.startswith(prefix):
            return phases.get(phase, defaults[phase])
    return defaults[phase]


def build_opencode_model(model_name: str, api_key: str) -> OpenAIChatModel:
    """Construct an OpenAIChatModel pointed at opencode-zen with
    ``$defs`` inlined in the output schema.

    The inlined-defs transformer drops every ``$ref`` indirection
    in favour of the resolved value, so the schema we send is
    flat and self-contained. No-op when the schema has no nested
    pydantic models; correctness-preserving when it does.
    """
    provider = OpenAIProvider(base_url=OPENCODE_BASE_URL, api_key=api_key)
    return OpenAIChatModel(
        model_name,
        provider=provider,
        profile=OpenAIModelProfile(
            json_schema_transformer=InlineDefsJsonSchemaTransformer,
        ),
    )


def build_ollama_model(model_name: str) -> OpenAIChatModel:
    """Construct an OpenAIChatModel pointed at a local Ollama server.

    Accepts the model name with or without the ``ollama:`` prefix.
    The server defaults to the standard local port; set
    ``OLLAMA_BASE_URL`` to target a different one. No API key needed.

    Uses the same inline-defs schema transformer as the opencode
    relay: small local models handle flat schemas better than
    ``$ref`` chains.
    """
    base_url = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434/v1")
    provider = OllamaProvider(
        base_url=base_url,
        http_client=httpx.AsyncClient(
            timeout=httpx.Timeout(OLLAMA_REQUEST_TIMEOUT_S, connect=10),
        ),
    )
    return OpenAIChatModel(
        model_name.removeprefix(OLLAMA_PREFIX),
        provider=provider,
        profile=OpenAIModelProfile(
            json_schema_transformer=InlineDefsJsonSchemaTransformer,
        ),
    )


def build_openai_compat_model(model_name: str) -> OpenAIChatModel:
    """Construct an OpenAIChatModel for any OpenAI-compatible endpoint.

    One generic mechanism for hosted open-weights providers instead of
    a branch per provider. Example for Cloudflare Workers AI:

        OPENAI_COMPAT_BASE_URL=https://api.cloudflare.com/client/v4/accounts/<id>/ai/v1
        OPENAI_COMPAT_API_KEY=<token>
        --model openai:@cf/google/gemma-4-26b-a4b-it
    """
    base_url = os.environ.get("OPENAI_COMPAT_BASE_URL", "")
    if not base_url:
        raise ValueError("OPENAI_COMPAT_BASE_URL not set")
    api_key = os.environ.get("OPENAI_COMPAT_API_KEY", "")
    if not api_key:
        raise ValueError("OPENAI_COMPAT_API_KEY not set")
    provider = OpenAIProvider(base_url=base_url, api_key=api_key)
    return OpenAIChatModel(
        model_name.removeprefix(OPENAI_COMPAT_PREFIX),
        provider=provider,
        profile=OpenAIModelProfile(
            json_schema_transformer=InlineDefsJsonSchemaTransformer,
        ),
    )


def build_mistral_model(model_name: str, api_key: str) -> PatchedMistralModel:
    """Construct a patched MistralModel with reasoning_effort support.

    Uses pydantic-ai's Mistral integration with a monkey-patch that
    forwards ``reasoning_effort`` to the Mistral client. Needed for
    Mistral Small 4 and Medium 3.5 which support adjustable reasoning.

    Remove once https://github.com/pydantic/pydantic-ai/issues/5285
    is resolved.
    """
    provider = MistralProvider(api_key=api_key)
    return PatchedMistralModel(model_name, provider=provider)
