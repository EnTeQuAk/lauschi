"""A split-off sub-series shares its artist pages with the parent, so
curating it returns the parent's whole discography. Luna included 187
of Hanni und Nanni's albums on "Neue Abenteuer"; Kimi included 188 and
excluded the three real episodes as sub_series_bleed (2026-08-31).
Nothing about the prompt fixes that; the CLI must refuse."""

import asyncio

import pytest
from click.testing import CliRunner

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.series_ops import split_off_refusal
from lauschi_catalog.commands import curate as curate_mod


def _child() -> CatalogEntry:
    return CatalogEntry(
        id="hanni_und_nanni_neue_abenteuer",
        title="Hanni und Nanni - Neue Abenteuer",
        split_from="hanni_und_nanni",
    )


def test_the_message_names_both_series_and_the_way_out() -> None:
    text = split_off_refusal("hanni_und_nanni_neue_abenteuer", "hanni_und_nanni")
    assert "hanni_und_nanni_neue_abenteuer" in text
    assert "split from hanni_und_nanni" in text
    assert "catalog-edit" in text


def test_curate_refuses_a_split_off_series(monkeypatch: pytest.MonkeyPatch) -> None:
    def _refuse(query, cli_content_type=None):
        child = _child()
        raise ValueError(split_off_refusal(child.id, child.split_from))

    monkeypatch.setattr(curate_mod, "prepare_curation", _refuse)
    result = CliRunner().invoke(curate_mod.curate, ["Hanni und Nanni - Neue Abenteuer"])
    assert result.exit_code == 1
    assert "split from hanni_und_nanni" in result.output


def test_curate_all_skips_split_offs_even_with_force(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    called: list[str] = []

    async def fake_curate_one(query, providers, **kw):
        called.append(kw.get("series_id") or query)
        return curate_ops.CurateOneResult(ok=True)

    monkeypatch.setattr(curate_ops, "curate_one", fake_curate_one)
    parent = CatalogEntry(id="hanni_und_nanni", title="Hanni und Nanni")
    monkeypatch.setattr(curate_ops, "load_catalog", lambda: [parent, _child()])
    progress: list[str] = []
    result = asyncio.run(
        curate_ops.curate_all([], force=True, on_progress=progress.append)
    )
    assert called == ["hanni_und_nanni"]
    assert result.skipped == 1
    assert any("split from hanni_und_nanni" in p for p in progress)
