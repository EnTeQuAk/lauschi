"""Tests for catalog.providers_init module."""

import pytest

from lauschi_catalog.catalog.providers_init import init_providers


class _FakeProvider:
    def __init__(self, *, use_cache: bool = True) -> None:
        self.use_cache = use_cache


class _NetworkError(RuntimeError):
    """Simulates a transient failure during provider construction."""


def _raise_system_exit(*_a, **_kw):
    raise SystemExit(1)


def _raise_filenotfound(*_a, **_kw):
    raise FileNotFoundError("key missing")


def test_init_providers_without_credentials(monkeypatch):
    """Missing credentials for both providers produce warnings."""
    import lauschi_catalog.providers.apple_music as apple_mod
    import lauschi_catalog.providers.spotify as spotify_mod

    monkeypatch.setattr(spotify_mod, "SpotifyProvider", _raise_system_exit)
    monkeypatch.setattr(apple_mod, "AppleMusicProvider", _raise_filenotfound)
    result = init_providers("all")
    assert len(result.warnings) == 2
    assert any("Spotify" in w for w in result.warnings)
    assert any("Apple" in w for w in result.warnings)
    assert result.providers == []


def test_init_providers_unknown_ignores():
    """Passing an unknown provider name returns empty results."""
    result = init_providers("nonexistent")
    assert result.providers == []
    assert result.warnings == []


def test_init_providers_spotify_only_success(monkeypatch):
    """When Spotify constructs, only Spotify is returned."""
    import lauschi_catalog.providers.apple_music as apple_mod
    import lauschi_catalog.providers.spotify as spotify_mod

    monkeypatch.setattr(spotify_mod, "SpotifyProvider", _FakeProvider)
    monkeypatch.setattr(apple_mod, "AppleMusicProvider", _raise_filenotfound)
    result = init_providers("spotify")
    assert len(result.providers) == 1
    assert isinstance(result.providers[0], _FakeProvider)
    assert result.warnings == []


def test_init_providers_catches_spotify_missing_credentials(monkeypatch):
    """Spotify missing credentials are reported, not raised."""
    import lauschi_catalog.providers.spotify as spotify_mod

    monkeypatch.setattr(spotify_mod, "SpotifyProvider", _raise_system_exit)
    result = init_providers("spotify")
    assert len(result.providers) == 0
    assert any("Spotify" in w and "credentials" in w for w in result.warnings)


def test_init_providers_catches_apple_missing_key(monkeypatch):
    """Apple Music missing key is reported, not raised."""
    import lauschi_catalog.providers.apple_music as apple_mod

    monkeypatch.setattr(apple_mod, "AppleMusicProvider", _raise_filenotfound)
    result = init_providers("apple_music")
    assert len(result.providers) == 0
    assert any("Apple" in w and "key" in w for w in result.warnings)


def test_init_providers_network_error_raises(monkeypatch):
    """A non-credential construction error must stop the run."""
    import lauschi_catalog.providers.spotify as spotify_mod

    def _raise_network(*_a, **_kw):
        raise _NetworkError("spotify down")

    monkeypatch.setattr(spotify_mod, "SpotifyProvider", _raise_network)
    with pytest.raises(_NetworkError):
        init_providers("spotify")
