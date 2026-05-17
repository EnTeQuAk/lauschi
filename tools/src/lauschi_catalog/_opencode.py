"""Shared model construction for AI providers.

Originally built for the opencode-zen relay; now also supports
Mistral via their native pydantic-ai integration.
"""

from __future__ import annotations

from pydantic_ai import InlineDefsJsonSchemaTransformer
from pydantic_ai.models.mistral import MistralModel
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.profiles.openai import OpenAIModelProfile
from pydantic_ai.providers.mistral import MistralProvider
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


def build_mistral_model(model_name: str, api_key: str) -> MistralModel:
    """Construct a native MistralModel.

    Uses pydantic-ai's built-in Mistral integration which correctly
    handles tool calls, structured output, and streaming.
    """
    provider = MistralProvider(api_key=api_key)
    return MistralModel(model_name, provider=provider)
