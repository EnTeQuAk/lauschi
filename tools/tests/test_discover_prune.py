"""Pin the `--prune-broken` behaviour in catalog-discover.

The pruner walks every catalog entry, calls ``provider.artist_exists``
on each existing artist_id, and removes only the 404s. Non-404 errors
must NOT cause a removal — a transient API outage would otherwise wipe
real catalog data.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
import requests
from click.testing import CliRunner

from lauschi_catalog.catalog import discover_ops, loader as loader_mod
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.commands import discover as discover_mod


def _entry(sid: str, *, spotify_ids: list[str], apple_ids: list[str]):
    return CatalogEntry(
        id=sid,
        title=sid.replace("_", " ").title(),
        providers={
            "spotify": ProviderConfig(artist_ids=spotify_ids),
            "apple_music": ProviderConfig(artist_ids=apple_ids),
        },
    )


@pytest.fixture
def fake_providers(monkeypatch):
    """Two provider mocks that report ids "spotify-bad" / "apple-bad"
    as 404 and everything else as fine."""
    sp = MagicMock(name="SpotifyProvider")
    sp.name = "spotify"
    sp.artist_exists = MagicMock(side_effect=lambda aid: aid != "spotify-bad")
    am = MagicMock(name="AppleMusicProvider")
    am.name = "apple_music"
    am.artist_exists = MagicMock(side_effect=lambda aid: aid != "apple-bad")
    return [sp, am]


@pytest.fixture
def fake_catalog(monkeypatch):
    entries = [
        _entry("clean", spotify_ids=["spotify-good"], apple_ids=["apple-good"]),
        _entry(
            "half_broken",
            spotify_ids=["spotify-good", "spotify-bad"],
            apple_ids=["apple-good"],
        ),
        _entry("apple_broken", spotify_ids=["spotify-good"], apple_ids=["apple-bad"]),
    ]
    monkeypatch.setattr(loader_mod, "load_catalog", lambda: entries)
    captured: dict = {}

    def fake_update(*, updates):
        captured["updates"] = updates
        return len(updates)

    monkeypatch.setattr(loader_mod, "update_provider_ids", fake_update)
    return captured


def test_prune_keeps_clean_ids_removes_only_404s(fake_providers, fake_catalog):
    """Only the explicit "*-bad" ids should be removed. Verifies the
    pruner doesn't over-fire on the half_broken entry's good id."""
    discover_ops.prune_broken(fake_providers, write=True)

    updates = fake_catalog["updates"]
    # 'clean' is untouched.
    assert "clean" not in updates
    # 'half_broken' keeps only the good spotify id.
    assert updates["half_broken"]["spotify"] == ["spotify-good"]
    # 'apple_broken' loses its only apple id, ending up with [].
    assert updates["apple_broken"]["apple_music"] == []


def test_prune_dry_run_does_not_write(fake_providers, fake_catalog):
    discover_ops.prune_broken(fake_providers, write=False)
    # No write happened.
    assert "updates" not in fake_catalog


def test_prune_keeps_id_on_transient_provider_error(fake_providers, fake_catalog):
    """A non-404 exception (e.g. timeout, 503) must NOT cause removal.

    Otherwise a brief provider outage would silently wipe real catalog
    data. The id stays put and the operator can re-run later."""
    sp, am = fake_providers
    sp.artist_exists = MagicMock(side_effect=requests.Timeout("flaky"))
    am.artist_exists = MagicMock(return_value=True)

    discover_ops.prune_broken(fake_providers, write=True)

    # No removals captured — everything was kept despite the error.
    assert fake_catalog.get("updates", {}) == {}


def test_cli_query_with_prune_broken_is_rejected():
    """``--prune-broken`` is a catalog-wide audit; combining it with a
    QUERY would be a confusing no-op. Reject explicitly."""
    runner = CliRunner()
    result = runner.invoke(discover_mod.discover, ["some-query", "--prune-broken"])
    assert result.exit_code == 2
    assert "cannot be combined" in result.output
