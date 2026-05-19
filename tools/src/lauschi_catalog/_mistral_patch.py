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

from typing import Any

from pydantic_ai.models.mistral import MistralModel
from pydantic_ai.settings import ModelSettings

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
        return await self._underlying.complete_async(*args, **kwargs)

    async def stream_async(self, *args: Any, **kwargs: Any) -> Any:
        if self._reasoning_effort is not None:
            kwargs["reasoning_effort"] = self._reasoning_effort
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
