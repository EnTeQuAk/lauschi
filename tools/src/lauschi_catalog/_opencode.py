"""Shared model construction for AI providers.

Originally built for the opencode-zen relay; now also supports
Mistral via their native pydantic-ai integration.
"""

from __future__ import annotations

from pydantic_ai import InlineDefsJsonSchemaTransformer
from lauschi_catalog._mistral_patch import PatchedMistralModel
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.profiles.openai import OpenAIModelProfile
from pydantic_ai.providers.mistral import MistralProvider
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.settings import ModelSettings

OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"

# Per-phase defaults for deterministic analytical classification.
# temperature=0.0 for strict reproducibility; 0.1 for tasks needing slight
# exploration (clustering, interpretation). Same seed across phases
# because prompts are always different.
_DEFAULT_CURATE = ModelSettings(temperature=0.0, seed=42)
_DEFAULT_FINALIZE = ModelSettings(temperature=0.1, seed=42)
_DEFAULT_REVIEW = ModelSettings(temperature=0.1, seed=42)
_DEFAULT_VERIFY = ModelSettings(temperature=0.0, seed=42)

# Model-specific overrides. Keyed by model-name prefix; first match wins.
# Use this to tune per-model behavior as we discover what each model
# needs. Format: {prefix: {phase: ModelSettings(...)}}.
_OVERRIDES: dict[str, dict[str, ModelSettings]] = {
    # Mistral Small 4 needs reasoning_effort="high" for complex analytical
    # tasks (pattern construction, era discovery). Proven insufficient for
    # curation quality on Biene Maja, but the mechanism is correct.
    # See https://github.com/pydantic/pydantic-ai/issues/5285
    "mistral-small-2603": {
        "curate": ModelSettings(temperature=0.0, seed=42, thinking="high"),
        "finalize": ModelSettings(temperature=0.1, seed=42, thinking="high"),
        "review": ModelSettings(temperature=0.1, seed=42, thinking="high"),
        "verify": ModelSettings(temperature=0.0, seed=42),
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
        "review": _DEFAULT_REVIEW,
        "verify": _DEFAULT_VERIFY,
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
