"""Query-param flash messages.

Routes redirect with one or more typed messages encoded as repeated
``?flash=type:value`` params via :func:`redirect_with_flash`. A
template context processor decodes them into ``flash_messages``
(a list of ``{"type", "value"}`` dicts) for every render, and
``base.html`` renders the banners once for all pages. No sessions:
the messages live in the URL of the page they land on.

Types map to CSS classes ``flash-<type>``; error, success, info and
warning ship with styles.
"""

from __future__ import annotations

from urllib.parse import urlencode

from fastapi import Request
from fastapi.responses import RedirectResponse

Flash = tuple[str, str]  # (type, value)


def redirect_with_flash(
    url: str,
    *flashes: Flash,
    error: str = "",
    message: str = "",
    status_code: int = 303,
) -> RedirectResponse:
    """Redirect to ``url`` carrying typed flash messages.

    Arbitrary types go through positional ``(type, value)`` tuples;
    ``error=`` and ``message=`` are ergonomic shorthands for the two
    common cases (message maps to type "success").
    """
    items = list(flashes)
    if error:
        items.append(("error", error))
    if message:
        items.append(("success", message))
    if items:
        query = urlencode([("flash", f"{t}:{v}") for t, v in items])
        sep = "&" if "?" in url else "?"
        url = f"{url}{sep}{query}"
    return RedirectResponse(url=url, status_code=status_code)


def make_flash(type_: str, value: str, *, safe: bool = False) -> dict:
    """Build a flash dict for a route's ``extra_flashes`` context.

    ``safe=True`` renders the value as HTML — only ever pass content
    rendered from our own templates (e.g. a confirm-action partial),
    never request data. Query-param flashes are always escaped.
    """
    return {"type": type_, "value": value, "safe": safe}


def flash_context(request: Request) -> dict[str, list[dict]]:
    """Template context processor: decoded flash messages for every render."""
    messages = []
    for raw in request.query_params.getlist("flash"):
        type_, _, value = raw.partition(":")
        if type_ and value:
            messages.append(make_flash(type_, value))
    return {"flash_messages": messages}
