"""Tests for catalog.providers_init module."""

from __future__ import annotations

from lauschi_catalog.catalog.providers_init import init_providers


def test_init_providers_without_credentials():
    """Without real credentials, both providers should fail with warnings."""
    result = init_providers("all")
    assert len(result.warnings) > 0


def test_init_providers_spotify_only():
    result = init_providers("spotify")
    assert any("Spotify" in w for w in result.warnings) or len(result.providers) == 1


def test_init_providers_apple_music_only():
    result = init_providers("apple_music")
    assert any("Apple" in w for w in result.warnings) or len(result.providers) == 1


def test_init_providers_unknown_ignores():
    """Passing an unknown provider name returns empty results."""
    result = init_providers("nonexistent")
    assert result.providers == []
    assert result.warnings == []
