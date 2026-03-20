"""Web search and page fetching via Brave Search API.

Used by curate and verify agents to research series when provider
metadata alone is ambiguous. Searches default to German results
(country=DE, search_lang=de) since the catalog targets DACH.
"""

from __future__ import annotations

import os
import re

import requests

BRAVE_API_URL = "https://api.search.brave.com/res/v1/web/search"
_TIMEOUT = 15
_DEFAULT_COUNT = 5
_DEFAULT_COUNTRY = "DE"


def brave_search(
    query: str,
    *,
    count: int = _DEFAULT_COUNT,
    country: str = _DEFAULT_COUNTRY,
) -> list[dict[str, str]]:
    """Search the web via Brave Search API.

    Returns a list of dicts with: title, url, snippet, age.
    """
    api_key = os.environ.get("BRAVE_API_KEY", "")
    if not api_key:
        return [{"error": "BRAVE_API_KEY not set"}]

    try:
        r = requests.get(
            BRAVE_API_URL,
            headers={
                "X-Subscription-Token": api_key,
                "Accept": "application/json",
            },
            params={
                "q": query,
                "count": min(count, 10),
                "country": country,
                "search_lang": "de",
            },
            timeout=_TIMEOUT,
        )
        r.raise_for_status()
    except requests.RequestException as e:
        return [{"error": f"Search failed: {e}"}]

    results: list[dict[str, str]] = []
    for item in r.json().get("web", {}).get("results", []):
        results.append({
            "title": item.get("title", ""),
            "url": item.get("url", ""),
            "snippet": _strip_html(item.get("description", "")),
            "age": item.get("age", ""),
        })
    return results


def fetch_page(url: str, *, max_chars: int = 4000) -> str:
    """Fetch a URL and return a simplified text extract.

    Not a full readability parser, just strips HTML tags and collapses
    whitespace. Good enough for structured pages like hoerspiele.de
    episode listings.
    """
    try:
        r = requests.get(
            url,
            headers={"User-Agent": "lauschi-catalog/1.0"},
            timeout=_TIMEOUT,
        )
        r.raise_for_status()
        text = _strip_html(r.text)
        # Collapse runs of whitespace/newlines
        text = re.sub(r"\n{3,}", "\n\n", text)
        text = re.sub(r"[ \t]{2,}", " ", text)
        return text.strip()[:max_chars]
    except requests.RequestException as e:
        return f"Failed to fetch {url}: {e}"


def _strip_html(html: str) -> str:
    """Remove HTML tags and decode entities."""
    # Remove script/style/noscript blocks
    text = re.sub(
        r"<(script|style|noscript)[^>]*>.*?</\1>",
        "", html, flags=re.DOTALL | re.IGNORECASE,
    )
    # Remove HTML comments
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    # Replace <br>, <p>, <div>, <li>, <tr> with newlines
    text = re.sub(r"<(?:br|/p|/div|/li|/tr)[^>]*>", "\n", text, flags=re.IGNORECASE)
    # Remove image tags entirely (hoerspiele.de uses spacer gifs)
    text = re.sub(r"<img[^>]*>", "", text, flags=re.IGNORECASE)
    # Remove remaining tags
    text = re.sub(r"<[^>]+>", " ", text)
    # Decode common entities
    for entity, char in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                         ("&quot;", '"'), ("&#39;", "'"), ("&nbsp;", " ")]:
        text = text.replace(entity, char)
    # Collapse whitespace: multiple spaces/tabs to single space
    text = re.sub(r"[ \t]+", " ", text)
    # Strip leading/trailing whitespace from each line
    text = "\n".join(line.strip() for line in text.splitlines())
    # Remove empty lines
    text = "\n".join(line for line in text.splitlines() if line)
    return text.strip()
