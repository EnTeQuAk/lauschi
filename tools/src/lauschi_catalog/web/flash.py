"""Session-backed flash messages (one-shot, consumed on display).

Routes store typed messages in the session via :func:`add_flash` or
the convenience :func:`redirect_with_flash`.  A template context
processor (:func:`flash_context`) pops them on the next render so
they appear exactly once, then disappear.

Types map to CSS classes ``flash-<type>``; error, success, info and
warning ship with styles.

For same-request rendering (e.g. the confirm-action pattern), use
:func:`make_flash` to build dicts for the template's ``extra_flashes``
list.  These bypass the session entirely.
"""

from __future__ import annotations

from typing import Any

from fastapi import Request
from fastapi.responses import RedirectResponse

Flash = tuple[str, str]  # (type, value)
FlashDict = dict[str, Any]


def add_flash(request: Request, type_: str, value: str) -> None:
    """Store a flash message in the session for the next request."""
    flashes: list[dict[str, str]] = request.session.setdefault("_flash", [])
    flashes.append({"type": type_, "value": value})


def redirect_with_flash(
    request: Request,
    url: str,
    *flashes: Flash,
    error: str = "",
    message: str = "",
    status_code: int = 303,
) -> RedirectResponse:
    """Store flash messages in the session and redirect to *url*.

    Arbitrary types go through positional ``(type, value)`` tuples;
    ``error=`` and ``message=`` are ergonomic shorthands for the two
    common cases (message maps to type "success").
    """
    items = list(flashes)
    if error:
        items.append(("error", error))
    if message:
        items.append(("success", message))
    for type_, value in items:
        add_flash(request, type_, value)
    return RedirectResponse(url=url, status_code=status_code)


def make_flash(type_: str, value: str, *, safe: bool = False) -> FlashDict:
    """Build a flash dict for a route's ``extra_flashes`` context.

    ``safe=True`` renders the value as HTML; only ever pass content
    rendered from our own templates (e.g. a confirm-action partial),
    never request data.  Session flashes are always escaped.
    """
    return {"type": type_, "value": value, "safe": safe}


def flash_context(request: Request) -> dict[str, list[FlashDict]]:
    """Template context processor: pop flash messages from session."""
    messages: list[FlashDict] = []
    for stored in request.session.pop("_flash", []):
        messages.append({"type": stored["type"], "value": stored["value"], "safe": False})
    return {"flash_messages": messages}
