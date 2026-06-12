"""Shared model construction for AI providers.

All models route through the opencode-zen relay, an OpenAI-compatible
endpoint. Model-specific tuning (temperature, seed) is centralized
here so agents don't carry per-model configuration.
"""

from __future__ import annotations

from pydantic_ai import InlineDefsJsonSchemaTransformer
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.profiles.openai import OpenAIModelProfile
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.settings import ModelSettings

OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"

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
_OVERRIDES: dict[str, dict[str, ModelSettings]] = {}


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


def build_model(model_name: str, api_key: str) -> OpenAIChatModel:
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
