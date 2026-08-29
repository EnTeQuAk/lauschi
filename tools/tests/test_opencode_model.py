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


def test_minimax_audit_uses_low_reasoning_and_caps_output():
    """MiniMax M2.x started returning extended reasoning it did not in
    June. The audit sends a whole series in one request; on Bibi
    Blocksberg (~490 albums) full reasoning spent the entire output
    budget narrating albums and never produced a verdict, even at
    max_tokens=32768. Disabling reasoning outright broke the other way:
    with no working memory across turns the model re-ran the same
    search 18 times until it hit the request budget. Low effort is the
    middle that June's working audits effectively ran at."""
    from lauschi_catalog._opencode import get_model_settings

    s = get_model_settings("audit", "minimax-m2.7")
    assert s.get("openai_reasoning_effort") == "low"
    assert s.get("max_tokens") == 32768
    assert "extra_body" not in s


def test_minimax_override_matches_any_m2_variant():
    """The relay fronts minimax-m2.5 and m2.7 for audit; the fix must
    not silently lapse when the default audit model is bumped."""
    from lauschi_catalog._opencode import get_model_settings

    for name in ("minimax-m2.5", "minimax-m2.7", "minimax-m3"):
        assert (
            get_model_settings("audit", name).get("openai_reasoning_effort") == "low"
        ), name


def test_non_minimax_audit_model_keeps_plain_default():
    """The thinking switch is a MiniMax request field. Sending it to
    another audit model would be an invalid request, so the override is
    scoped by model prefix and every other model gets the plain default."""
    from lauschi_catalog._opencode import get_model_settings

    s = get_model_settings("audit", "kimi-k2.5")
    assert "openai_reasoning_effort" not in s
    assert "max_tokens" not in s


def test_curate_and_finalize_keep_provider_default_output_cap():
    """Curate and finalize survived the reasoning-heavy July pipeline
    run without a cap; only audit overflowed. Their settings are left
    alone on purpose so this change stays scoped to the failing phase."""
    from lauschi_catalog._opencode import get_model_settings

    assert "max_tokens" not in get_model_settings("curate", "kimi-k2.5")
    assert "max_tokens" not in get_model_settings("finalize", "kimi-k2.5")
