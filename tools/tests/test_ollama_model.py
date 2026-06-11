"""Pin that build_ollama_model routes ``ollama:``-prefixed model names
to a local Ollama server.

Local models let us experiment with curation without API costs. The
``ollama:`` prefix follows the pipeline's existing prefix-dispatch
convention (``mistral-*`` goes to Mistral, everything else to the
opencode relay). The prefix is stripped before the name reaches the
server: Ollama knows the model as ``gemma4:12b``, not
``ollama:gemma4:12b``.
"""

from __future__ import annotations

from pydantic_ai import InlineDefsJsonSchemaTransformer

from lauschi_catalog._opencode import build_ollama_model


def test_strips_ollama_prefix_from_model_name():
    """The dispatcher matches on the ``ollama:`` prefix, but the local
    server only knows the bare model tag."""
    model = build_ollama_model("ollama:gemma4:12b")
    assert model.model_name == "gemma4:12b"


def test_accepts_bare_model_name():
    """Stripping is idempotent so callers can pass either form."""
    model = build_ollama_model("gemma4:12b")
    assert model.model_name == "gemma4:12b"


def test_wires_inline_defs_transformer():
    """Small local models handle flat schemas better than $ref chains,
    same reasoning as the opencode relay (see test_opencode_model.py)."""
    model = build_ollama_model("ollama:gemma4:12b")
    assert model.profile.json_schema_transformer is InlineDefsJsonSchemaTransformer


def test_gemma4_disables_thinking_via_reasoning_effort():
    """gemma4 on CPU thinks itself past any sane request timeout
    (observed: 3x 30-minute reasoning marathons on one metadata turn).
    reasoning_effort=none maps to Ollama's think-off and cuts a toy
    answer from 202 completion tokens to 4."""
    from lauschi_catalog._opencode import get_model_settings

    for phase in ("curate", "finalize", "audit"):
        settings = get_model_settings(phase, "ollama:gemma4:12b")
        assert settings["extra_body"] == {"reasoning_effort": "none"}, phase


def test_default_base_url_is_local_ollama(monkeypatch):
    monkeypatch.delenv("OLLAMA_BASE_URL", raising=False)
    model = build_ollama_model("ollama:gemma4:12b")
    assert model._provider.base_url == "http://localhost:11434/v1/"


def test_generous_request_timeout_for_local_inference():
    """CPU inference is slow: a thinking model at ~8 tok/s can spend
    well over the OpenAI client's default 600s on a single turn. The
    client cancelling mid-generation surfaces as an Ollama 500 after
    exactly 10m0s, and retries deterministically hit the same wall."""
    model = build_ollama_model("ollama:gemma4:12b")
    assert model._provider.client.timeout.read >= 1800


def test_base_url_env_override(monkeypatch):
    """OLLAMA_BASE_URL lets experiments target a non-default port,
    e.g. a user-local server running next to the system service."""
    monkeypatch.setenv("OLLAMA_BASE_URL", "http://localhost:11435/v1")
    model = build_ollama_model("ollama:gemma4:12b")
    assert model._provider.base_url == "http://localhost:11435/v1/"
