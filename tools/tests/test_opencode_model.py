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
    """The relay fronts both kimi-k2.6 (curate) and minimax-m2.5/m2.7
    (audit). The helper must work for any string the callers pick."""
    for name in ("kimi-k2.6", "minimax-m2.5", "minimax-m2.7"):
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

    s = get_model_settings("audit", "kimi-k2.6")
    assert "openai_reasoning_effort" not in s
    assert "max_tokens" not in s


def test_curate_and_finalize_carry_the_same_backstop_as_audit():
    """Curate survived the July run without a cap, so the setting was
    left alone. On 2026-09-05 a batch of 30 Wieso? Weshalb? Warum?
    albums died twice with "token limit (provider default) exceeded
    before any response was generated", so curate and finalize now carry
    the backstop the audit already had."""
    from lauschi_catalog._opencode import get_model_settings

    assert get_model_settings("curate", "kimi-k2.6").get("max_tokens") == 32768
    assert get_model_settings("finalize", "kimi-k2.6").get("max_tokens") == 32768


# ── transport follows the model ───────────────────────────────────────


def test_gpt_5_6_routes_to_the_responses_api():
    """opencode-zen serves the GPT-5.6 family on /responses; on
    /chat/completions it returns "Internal server error" (verified live
    2026-08-30). The transport must follow the model name."""
    from pydantic_ai.models.openai import OpenAIResponsesModel

    from lauschi_catalog._opencode import uses_responses_api

    assert uses_responses_api("gpt-5.6-luna")
    model = build_model("gpt-5.6-luna", api_key="test-key")
    assert isinstance(model, OpenAIResponsesModel)
    assert model.model_name == "gpt-5.6-luna"


def test_everything_else_stays_on_chat_completions():
    """Every audit was probed on chat completions and the 276 one-shot
    series run on it. Adding a Responses-API route must not move them."""
    from pydantic_ai.models.openai import OpenAIChatModel

    from lauschi_catalog._opencode import uses_responses_api

    for name in ("kimi-k2.6", "minimax-m2.7", "minimax-m3", "glm-5.2"):
        assert not uses_responses_api(name), name
        assert isinstance(build_model(name, api_key="test-key"), OpenAIChatModel), name


def test_chat_completions_keeps_the_inline_defs_transformer():
    """The chat-completions relay cannot resolve $ref; InlineDefs is why
    build_model exists. The 276 one-shot audits run on this path."""
    model = build_model("kimi-k2.6", api_key="test-key")
    assert model.profile.json_schema_transformer is InlineDefsJsonSchemaTransformer


def test_responses_api_uses_the_strict_mode_transformer():
    """Zen's Responses endpoint enforces strict tool schemas: every object
    must carry additionalProperties: false, which InlineDefs does not
    emit ("'additionalProperties' is required to be supplied and to be
    false", verified live 2026-08-30). pydantic-ai's strict transformer
    emits it. It leaves $ref in place, and that is fine here: the same
    probe showed the Responses path resolves a $ref-bearing strict
    schema for the nested BatchResult, unlike the chat relay."""
    from pydantic_ai.profiles.openai import OpenAIJsonSchemaTransformer

    model = build_model("gpt-5.6-luna", api_key="test-key")
    assert model.profile.json_schema_transformer is OpenAIJsonSchemaTransformer


def test_gpt_5_6_runs_every_phase_at_low_reasoning():
    """Luna's effort dial is honored on /responses (reasoning_tokens 0 at
    low, verified live). Curation is classification against provider
    data; low keeps the output budget for the verdict, on every phase."""
    from lauschi_catalog._opencode import get_model_settings

    for phase in ("curate", "finalize", "audit"):
        s = get_model_settings(phase, "gpt-5.6-luna")
        assert s.get("openai_reasoning_effort") == "low", phase


def test_gpt_5_6_sends_no_sampling_parameters():
    """The endpoint rejects temperature, seed and top_p for this family
    ("'temperature' is not supported with this model", verified live
    2026-08-30). The phase defaults carry temperature and seed; the Luna
    override must not inherit them or every curate call fails with 400."""
    from lauschi_catalog._opencode import get_model_settings

    for phase in ("curate", "finalize", "audit"):
        s = get_model_settings(phase, "gpt-5.6-luna")
        assert "temperature" not in s, phase
        assert "seed" not in s, phase
