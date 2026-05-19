"""Subclass MistralModel to forward reasoning_effort.

pydantic-ai 1.97.0 does not pass ``reasoning_effort`` to the Mistral
client for non-magistral thinking models (e.g. mistral-small-2603).
This module provides a drop-in replacement ``PatchedMistralModel``
that extracts ``reasoning_effort`` from ``ModelSettings.extra_body``
and maps ``ModelSettings.thinking`` to Mistral's ``reasoning_effort``
parameter.

Upstream issue: https://github.com/pydantic/pydantic-ai/issues/5285
Remove once pydantic-ai natively supports this.
"""

from __future__ import annotations

import logging
from typing import Any

from pydantic_ai.models.mistral import MistralModel
from pydantic_ai.settings import ModelSettings

logger = logging.getLogger(__name__)

_THINKING_TO_REASONING_EFFORT: dict[str | bool | None, str | None] = {
    True: "high",
    False: None,
    None: None,
    "high": "high",
    "xhigh": "high",
    "medium": "high",
    "low": "none",
    "minimal": "none",
}


def _log_payload(kwargs: dict[str, Any]) -> None:
    """Log key fields of the outbound Mistral API payload for debugging.

    Truncates message content to avoid spam; records tool presence,
    response_format, and reasoning_effort.
    """
    safe: dict[str, Any] = {}
    for k, v in kwargs.items():
        if k == "messages" and isinstance(v, list):
            safe["messages_count"] = len(v)
            safe["messages"] = [
                {
                    "role": m.get("role") if isinstance(m, dict) else getattr(m, "role", None),
                    "content_preview": (
                        (m.get("content", "")[:200] + "…")
                        if isinstance(m, dict) else
                        (str(getattr(m, "content", ""))[:200] + "…")
                    ),
                }
                for m in v[:3]
            ]
        elif k == "tools" and v:
            safe["tools_count"] = len(v)
            safe["tool_names"] = [
                t.get("function", {}).get("name") if isinstance(t, dict) else getattr(t, "name", None)
                for t in (v[:5] if isinstance(v, list) else [])
            ]
        elif k == "response_format" and v:
            safe["response_format"] = v
        else:
            safe[k] = v
    logger.debug("Mistral outbound payload: %s", safe)
    print(f"[MISTRAL PAYLOAD] {safe}", flush=True)


def _resolve_reasoning_effort(model_settings: ModelSettings | None) -> str | None:
    """Map pydantic-ai ModelSettings to Mistral reasoning_effort."""
    if model_settings is None:
        return None

    # Direct passthrough via extra_body (highest priority)
    extra_body = model_settings.get("extra_body")
    if isinstance(extra_body, dict) and "reasoning_effort" in extra_body:
        return extra_body["reasoning_effort"]

    # Unified thinking mapping
    thinking = model_settings.get("thinking")
    return _THINKING_TO_REASONING_EFFORT.get(thinking)


class _ChatProxy:
    """Wraps a Mistral Chat instance to inject reasoning_effort."""

    def __init__(self, underlying: Any, reasoning_effort: str | None) -> None:
        self._underlying = underlying
        self._reasoning_effort = reasoning_effort

    async def complete_async(self, *args: Any, **kwargs: Any) -> Any:
        if self._reasoning_effort is not None:
            kwargs["reasoning_effort"] = self._reasoning_effort
        _log_payload(kwargs)
        return await self._underlying.complete_async(*args, **kwargs)

    async def stream_async(self, *args: Any, **kwargs: Any) -> Any:
        if self._reasoning_effort is not None:
            kwargs["reasoning_effort"] = self._reasoning_effort
        _log_payload(kwargs)
        return await self._underlying.stream_async(*args, **kwargs)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._underlying, name)


class PatchedMistralModel(MistralModel):
    """MistralModel that forwards reasoning_effort to the Mistral API."""

    async def request(
        self,
        messages: Any,
        model_settings: ModelSettings | None,
        model_request_parameters: Any,
    ) -> Any:
        reasoning_effort = _resolve_reasoning_effort(model_settings)
        original_chat = self.client.chat
        if reasoning_effort is not None:
            self.client.chat = _ChatProxy(original_chat, reasoning_effort)
        try:
            return await super().request(
                messages, model_settings, model_request_parameters
            )
        finally:
            self.client.chat = original_chat

    async def request_stream(
        self,
        messages: Any,
        model_settings: ModelSettings | None,
        model_request_parameters: Any,
        run_context: Any = None,
    ) -> Any:
        reasoning_effort = _resolve_reasoning_effort(model_settings)
        original_chat = self.client.chat
        if reasoning_effort is not None:
            self.client.chat = _ChatProxy(original_chat, reasoning_effort)
        try:
            return await super().request_stream(
                messages, model_settings, model_request_parameters, run_context
            )
        finally:
            self.client.chat = original_chat
