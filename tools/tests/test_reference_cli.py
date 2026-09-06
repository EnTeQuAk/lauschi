"""`lauschi-catalog reference` prints a series' lines from the index."""

from click.testing import CliRunner

from lauschi_catalog.commands import reference as reference_cmd
from lauschi_catalog.reference import ReferenceIndex
from tests.test_reference_index import fake_fetch


def test_reference_prints_lines_and_numbered_episodes(monkeypatch):
    monkeypatch.setattr(
        reference_cmd,
        "ReferenceIndex",
        lambda: ReferenceIndex(
            "https://example.test/api", fetch=fake_fetch, use_cache=False
        ),
    )
    result = CliRunner().invoke(reference_cmd.reference, ["Kugelblitz"])
    assert result.exit_code == 0, result.output
    assert "Hörspiele zu den Büchern (2)" in result.output
    assert "Die rote Socke" in result.output


def test_reference_refuses_without_configuration(monkeypatch):
    monkeypatch.delenv("REFERENCE_INDEX_URL", raising=False)
    result = CliRunner().invoke(reference_cmd.reference, ["Kugelblitz"])
    assert result.exit_code == 1
    assert "REFERENCE_INDEX_URL" in result.output
