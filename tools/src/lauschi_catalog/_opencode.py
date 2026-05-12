"""Shared model construction for the opencode-zen relay.

The relay (https://opencode.ai/zen/v1) fronts different backends —
kimi-k2.5 for curate/review, minimax-m2.5 for verify. Both are
served via an OpenAI-compatible API, but the relay's schema
resolver can't dereference pydantic's `$defs`/`$ref` chains.
``verify`` hit this with a 400 the first time a curation carried
a split proposal:

    Error from provider: Error resolving schema reference
    '#/$defs/OverrideVerdict':
    AttributeError("'NoneType' object has no attribute 'lookup'")

Pydantic-ai ships ``InlineDefsJsonSchemaTransformer`` for exactly
this pattern; the same fix is hardcoded for Meta, Amazon, Qwen,
and OpenRouter integrations in pydantic-ai's source. We need to
apply it explicitly here because pydantic-ai has no MiniMax
profile and falls back to the default OpenAI profile (which
preserves refs).

Use ``build_opencode_model(name, api_key)`` instead of constructing
the model+provider pair directly. Centralised so the next provider
quirk lands in one place.
"""

from __future__ import annotations

from pydantic_ai import InlineDefsJsonSchemaTransformer
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.profiles.openai import OpenAIModelProfile
from pydantic_ai.providers.openai import OpenAIProvider

OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"


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
