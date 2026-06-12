"""Pin that build_model wires the inline-defs schema transformer
into the OpenAIChatModel profile.

Without that transformer, pydantic-ai sends schemas with $defs/$ref
chains; opencode-zen's relay can't resolve them and crashes with:

    Error from provider: Error resolving schema reference
    '#/$defs/OverrideVerdict':
    AttributeError("'NoneType' object has no attribute 'lookup'")

That's how the old verify step failed on kleiner_rabe_socke when the curation
carried a split proposal. The transformer flattens $defs inline so
the relay never has to follow a $ref. Same fix pydantic-ai uses
for Meta, Amazon, Qwen, and OpenRouter providers.
"""

from __future__ import annotations

from pydantic_ai import InlineDefsJsonSchemaTransformer

from lauschi_catalog._opencode import OPENCODE_BASE_URL, build_model


def test_helper_returns_chat_model_with_inline_defs_transformer():
    """The whole reason this helper exists. If a refactor swaps out
    InlineDefsJsonSchemaTransformer, every agent talking to opencode-
    zen breaks the next time a curation hits a complex schema."""
    model = build_model("minimax-m2.5", api_key="test-key")
    assert model.profile.json_schema_transformer is InlineDefsJsonSchemaTransformer


def test_helper_uses_opencode_base_url():
    """Pin the relay URL via the module-level constant."""
    assert OPENCODE_BASE_URL == "https://opencode.ai/zen/v1"


def test_helper_passes_through_arbitrary_model_name():
    """The relay fronts both kimi-k2.5 (curate) and minimax-m2.5/m2.7
    (audit). The helper must work for any string the callers pick."""
    for name in ("kimi-k2.5", "minimax-m2.5", "minimax-m2.7"):
        model = build_model(name, api_key="test-key")
        assert model.model_name == name
