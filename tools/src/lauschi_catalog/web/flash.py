"""Query-param flash messages.

Routes redirect with ``?message=`` (success) or ``?error=`` via
:func:`redirect_with_flash`. A template context processor exposes the
params to every template as ``flash_message`` / ``flash_error``, and
``base.html`` renders the banner once for all pages. No sessions: the
message lives in the URL of the page it lands on.
"""

from __future__ import annotations

from urllib.parse import urlencode

from fastapi import Request
from fastapi.responses import RedirectResponse


def redirect_with_flash(
    url: str,
    *,
    message: str = "",
    error: str = "",
    status_code: int = 303,
) -> RedirectResponse:
    """Redirect to ``url`` carrying a flash message or error."""
    params = {}
    if message:
        params["message"] = message
    if error:
        params["error"] = error
    if params:
        sep = "&" if "?" in url else "?"
        url = f"{url}{sep}{urlencode(params)}"
    return RedirectResponse(url=url, status_code=status_code)


def flash_context(request: Request) -> dict[str, str]:
    """Template context processor: flash params for every render."""
    return {
        "flash_message": request.query_params.get("message", ""),
        "flash_error": request.query_params.get("error", ""),
    }
