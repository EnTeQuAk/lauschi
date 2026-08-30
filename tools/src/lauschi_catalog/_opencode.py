"""Shared model construction for AI providers.

All models route through the opencode-zen relay, an OpenAI-compatible
endpoint. Model-specific tuning (temperature, seed) is centralized
here so agents don't carry per-model configuration.
"""

from dataclasses import dataclass

from pydantic_ai import InlineDefsJsonSchemaTransformer
from pydantic_ai.models import Model
from pydantic_ai.models.openai import OpenAIChatModel, OpenAIResponsesModel
from pydantic_ai.profiles.openai import OpenAIJsonSchemaTransformer, OpenAIModelProfile
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


@dataclass(frozen=True)
class ModelProfile:
    """Provider-agnostic limits for a model family.

    These are empirically probed values, not theoretical maxima. A
    model that fails at the default should get its own entry in
    _PROFILES with measured numbers.
    """

    request_limit: int = 200
    #: How many times an identical audit query may be answered before the
    # tool refuses (repeated queries are a reasoning-loop signal).
    search_repeat_allowance: int = 2
    #: Largest one-shot audit prompt known to produce a verdict, in the
    # same units prompt_size() reports.
    one_shot_max_tokens: int = 14_000
    #: Second stop for chunking: even if a cluster fits the token budget,
    # very large included-album counts can still fail because the model
    # narrates instead of judging. Bound the chunk by count too.
    chunk_max_included: int = 200


# Model-specific profiles. Keyed by model-name prefix; first match wins.
_PROFILES: dict[str, ModelProfile] = {
    # MiniMax M2.7 (audit model): at low reasoning the audit needs enough
    # turns to verify the whole series but not so many that it narrates
    # albums. 40 is the probed backstop. The one-shot boundary was probed
    # alongside the size limit. For chunked audits, M2.7 failed at 163
    # included albums on Benjamin and passed at 179 on another shape, so
    # 60 bounds the narration-driven failure without removing it.
    "minimax-": ModelProfile(
        request_limit=40,
        search_repeat_allowance=2,
        one_shot_max_tokens=14_000,
        chunk_max_included=60,
    ),
}


# Model-specific overrides. Keyed by model-name prefix; first match wins.
# Use this to tune per-model behavior as we discover what each model
# needs. Format: {prefix: {phase: ModelSettings(...)}}.
_OVERRIDES: dict[str, dict[str, ModelSettings]] = {
    # MiniMax M2.x started returning extended reasoning it did not in
    # June. The audit sends a whole series in one request, and on a
    # large one (Bibi Blocksberg, ~490 albums) full reasoning spent the
    # entire output budget narrating albums and never produced a
    # verdict, even at max_tokens=32768. Disabling reasoning outright
    # (MiniMax's thinking switch) fixed that but broke the other way:
    # with no working memory across turns the model re-ran the same
    # search_included_albums query 18 times until it hit the request
    # budget. Low effort is the middle: enough reasoning to remember
    # what it already checked and stop (June's audits, which worked,
    # reasoned lightly and finished in ~9 calls), bounded enough to
    # leave room for the verdict. max_tokens stays as a backstop.
    "minimax-": {
        "audit": ModelSettings(
            temperature=0.0,
            seed=42,
            max_tokens=32768,
            openai_reasoning_effort="low",
        ),
    },
    # GPT-5.6 Luna is a reasoning model with an explicit effort dial
    # (none/low/medium/high/xhigh/max). Verified against Zen's
    # /responses endpoint 2026-08-30: at "low" it returns
    # reasoning_tokens 0 and still makes strict tool calls correctly.
    # Curation is classification against provider data, not open-ended
    # reasoning, so low keeps the output budget for the verdict.
    #
    # No temperature, seed or top_p: the endpoint rejects all three for
    # this family ("'temperature' is not supported with this model",
    # verified live 2026-08-30). The pipeline's temperature=0/seed=42
    # determinism principle cannot be applied here; run-to-run variance
    # on Luna is measured by the eval harness rather than assumed away.
    "gpt-5.6-": {
        "curate": ModelSettings(openai_reasoning_effort="low"),
        "finalize": ModelSettings(openai_reasoning_effort="low"),
        "audit": ModelSettings(openai_reasoning_effort="low"),
    },
}

# Model-name prefixes that opencode-zen serves on the OpenAI Responses
# API (`/responses`) rather than chat completions. Verified 2026-08-30:
# gpt-5.6-luna returns "Internal server error" on /chat/completions and
# works on /responses, with strict function calling and reasoning
# effort honored. Everything not listed uses chat completions, which is
# what the whole pipeline has run on and what every audit was probed on.
_RESPONSES_API_PREFIXES = ("gpt-5.6-",)


def uses_responses_api(model_name: str) -> bool:
    return model_name.startswith(_RESPONSES_API_PREFIXES)


def get_model_profile(model_name: str) -> ModelProfile:
    """Return the operational profile for a model family."""
    for prefix, profile in _PROFILES.items():
        if model_name.startswith(prefix):
            return profile
    return ModelProfile()


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


def build_model(model_name: str, api_key: str) -> Model:
    """Construct a model pointed at opencode-zen with ``$defs`` inlined
    in the output schema.

    The transport follows the model: the GPT-5.6 family is served on
    Zen's Responses API, everything else on chat completions. Both get
    the same provider and the same profile, so a model swap changes
    nothing but the wire format.

    The inlined-defs transformer drops every ``$ref`` indirection
    in favour of the resolved value, so the schema we send is
    flat and self-contained. No-op when the schema has no nested
    pydantic models; correctness-preserving when it does.
    """
    provider = OpenAIProvider(base_url=OPENCODE_BASE_URL, api_key=api_key)
    if uses_responses_api(model_name):
        # The Responses API enforces strict tool schemas: every object
        # needs additionalProperties: false, which InlineDefs does not
        # emit (verified live 2026-08-30: "'additionalProperties' is
        # required to be supplied and to be false"). pydantic-ai's
        # strict-mode transformer emits it and also resolves $ref, so
        # the relay's $defs limitation is covered on this path too.
        return OpenAIResponsesModel(
            model_name,
            provider=provider,
            profile=OpenAIModelProfile(
                json_schema_transformer=OpenAIJsonSchemaTransformer,
            ),
        )
    return OpenAIChatModel(
        model_name,
        provider=provider,
        profile=OpenAIModelProfile(
            json_schema_transformer=InlineDefsJsonSchemaTransformer,
        ),
    )
