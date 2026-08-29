from lauschi_catalog._opencode import get_model_settings, uses_responses_api


def test_kimi_k3_audits_at_low_reasoning_with_the_pipeline_sampling() -> None:
    s = get_model_settings("audit", "kimi-k3")
    assert s["openai_reasoning_effort"] == "low"
    assert s["temperature"] == 0.0
    assert s["seed"] == 42


def test_kimi_k3_curates_with_the_defaults() -> None:
    # only the critic role is tuned; the curator role is not under evaluation
    assert "openai_reasoning_effort" not in get_model_settings("curate", "kimi-k3")


def test_kimi_k3_stays_on_chat_completions() -> None:
    assert not uses_responses_api("kimi-k3")
