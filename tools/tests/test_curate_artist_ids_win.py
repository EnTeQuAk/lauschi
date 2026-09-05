"""Tests that discovered artist IDs always win."""

import pytest
from pydantic_ai import Agent
from pydantic_ai.models.test import TestModel

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import (
    CurateDeps,
    DiscoveryResult,
    SeriesMetadata,
)


class _FakeProvider:
    """Minimal provider stand-in."""

    name = "spotify"

    def search_artists(self, _query: str):
        return []

    def artist_albums(self, _artist_id: str):
        return []


@pytest.fixture
def fake_model(monkeypatch):
    """All model requests route to TestModel so no network is needed."""
    monkeypatch.setenv("OPENCODE_API_KEY", "test")
    monkeypatch.setattr(
        curate_ops,
        "build_model",
        lambda _name, _key: TestModel(call_tools=[]),
    )


@pytest.mark.anyio
async def test_provider_artist_ids_always_equal_discovery(fake_model, monkeypatch):
    """The metadata model cannot override artist IDs discovered by code."""
    discovered = {"spotify": ["discovered_artist_1"], "apple_music": ["am_artist_1"]}

    async def fake_run_discovery(*_args, **_kwargs) -> DiscoveryResult:
        return DiscoveryResult(
            all_albums=[],
            artist_ids=discovered,
            provider_errors=[],
            incomplete=False,
        )

    monkeypatch.setattr(curate_ops, "_run_discovery", fake_run_discovery)

    def fake_build_metadata_agent(
        model, *, model_name="", content_type="hoerspiel", discography_span_years=None
    ):  # noqa: ARG001
        agent: Agent[CurateDeps, SeriesMetadata] = Agent(
            model,
            output_type=SeriesMetadata,
            instructions="",
            model_settings={},
        )

        @agent.output_validator
        def _noop(_ctx, meta: SeriesMetadata) -> SeriesMetadata:  # type: ignore[no-untyped-def]
            return meta

        return agent

    monkeypatch.setattr(curate_ops, "_build_metadata_agent", fake_build_metadata_agent)

    result = await curate_ops._run_large(
        "Kira",
        [_FakeProvider()],  # type: ignore[arg-type]
        model_name="test",
        api_key="test",
        timeout=60,
        content_type="music",
        known_artist_ids={"spotify": ["discovered_artist_1"]},
    )

    assert result.provider_artist_ids == discovered
    assert "apple_music" in result.provider_artist_ids


@pytest.mark.anyio
async def test_metadata_model_cannot_inject_artist_ids(fake_model):
    """Even if a future metadata model tries to return provider_artist_ids,
    the field is gone from SeriesMetadata so it cannot reach the curation.
    """
    # If provider_artist_ids were still on SeriesMetadata, this would have
    # parsed. Because we removed the field, it is silently ignored by
    # pydantic (extra="ignore" is the default). The test verifies the
    # field cannot carry data.
    meta = SeriesMetadata(
        id="kira",
        title="Kira",
        provider_artist_ids={"spotify": ["injected"]},  # type: ignore[call-arg]
    )
    assert not hasattr(meta, "provider_artist_ids") or meta.provider_artist_ids is None  # type: ignore[attr-defined]
