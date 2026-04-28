"""Validation rules that gate the review agent's add_album tool.

Adding albums during review is the highest-risk tool: it mutates curation
data with the agent's chosen album_id, and a hallucinated id silently
pollutes the catalog. These rules force the agent to ground each add in
externally-verifiable evidence (a URL from prior research) before the
tool will accept it.
"""

from __future__ import annotations

from lauschi_catalog.commands.review_validation import validate_add_evidence


class _Deps:
    """Minimal shim mimicking the counters on Deps."""

    def __init__(self, search: int = 0, fetch: int = 0):
        self._search_count = search
        self._fetch_count = fetch


def test_rejects_empty_evidence_url():
    err = validate_add_evidence(_Deps(search=1), "")
    assert err is not None
    assert "evidence" in err.lower()


def test_rejects_non_http_evidence_url():
    err = validate_add_evidence(_Deps(search=1), "spotify:album:abc")
    assert err is not None
    assert "http" in err.lower()


def test_rejects_when_no_prior_research():
    """The agent must have used web_search or fetch_page first."""
    err = validate_add_evidence(_Deps(search=0, fetch=0), "https://hoerspiele.de/x")
    assert err is not None
    assert "search" in err.lower() or "research" in err.lower() or "fetch" in err.lower()


def test_accepts_https_url_after_web_search():
    err = validate_add_evidence(_Deps(search=1), "https://hoerspiele.de/tkkg")
    assert err is None


def test_accepts_http_url_after_web_search():
    err = validate_add_evidence(_Deps(search=1), "http://example.com/series")
    assert err is None


def test_accepts_after_fetch_only():
    """A direct fetch_page call also counts as research."""
    err = validate_add_evidence(_Deps(fetch=1), "https://hoerspiele.de/x")
    assert err is None


def test_rejects_spotify_domain():
    """Citing the album's own Spotify page is circular evidence."""
    err = validate_add_evidence(_Deps(search=1), "https://open.spotify.com/album/abc")
    assert err is not None
    assert "spotify.com" in err.lower() or "external" in err.lower()


def test_rejects_apple_music_domain():
    err = validate_add_evidence(_Deps(search=1), "https://music.apple.com/de/album/123")
    assert err is not None
    assert "apple" in err.lower() or "external" in err.lower()


def test_rejects_itunes_domain():
    err = validate_add_evidence(_Deps(search=1), "https://itunes.apple.com/album/123")
    assert err is not None


def test_rejects_provider_domain_with_www_prefix():
    err = validate_add_evidence(_Deps(search=1), "https://www.spotify.com/de")
    assert err is not None


def test_accepts_external_evidence_domains():
    for url in [
        "https://hoerspiele.de/serien/tkkg/folge-128",
        "https://de.wikipedia.org/wiki/TKKG",
        "https://www.europa-publishing.de/produkt/folge-128",
    ]:
        err = validate_add_evidence(_Deps(search=1), url)
        assert err is None, f"unexpectedly rejected: {url} → {err}"
