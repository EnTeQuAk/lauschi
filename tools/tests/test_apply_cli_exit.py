"""Exit-code contract for the apply CLI (T18 scope: gates fail the run).

Apply must not report success when it refused work. A missing single
series file is an error; a curation file whose `id` disagrees with its
filename is refused (it would apply into someone else's yaml entry).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from lauschi_catalog.catalog import apply_ops
from lauschi_catalog.commands.apply import apply


def _curation(sid: str) -> dict:
    return {
        "id": sid,
        "title": "S",
        "review": {
            "status": "approved",
            "audited_at": "2026-08-01T00:00:00+00:00",
        },
        "curated_at": "2026-01-01T00:00:00+00:00",
        "albums": [],
    }


@pytest.fixture
def scratch(tmp_path, monkeypatch):
    catalog = tmp_path / "assets" / "catalog"
    (catalog / "curation").mkdir(parents=True)
    (catalog / "series.yaml").write_text(
        "series:\n  - id: s1\n    title: S1\n  - id: s2\n    title: S2\n"
    )
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    return catalog / "curation"


def test_apply_all_exits_zero_when_nothing_blocked(scratch, monkeypatch):
    (scratch / "s1.json").write_text(json.dumps(_curation("s1")))

    def fake_load_raw(_path=None):
        return {"series": [{"id": "s1", "title": "S1"}]}

    monkeypatch.setattr(apply_ops, "load_raw", fake_load_raw)
    monkeypatch.setattr(apply_ops, "save_raw", lambda *a, **k: None)
    result = CliRunner().invoke(apply, ["--all"])
    assert result.exit_code == 0


def test_apply_all_exits_one_when_a_refusal_happened(scratch, monkeypatch):
    """An approved series whose run was incomplete is refused; --all must
    not print 'Nothing to apply' semantics and exit 0 over it."""
    (scratch / "s1.json").write_text(json.dumps(_curation("s1")))
    (scratch / "s2.json").write_text(
        json.dumps(
            {
                **_curation("s2"),
                "incomplete": True,
                "incomplete_reason": "batch 3/7 failed",
            }
        )
    )
    # an empty album list means "no included albums" would return False
    # anyway; make one series actually applicable
    (scratch / "s1.json").write_text(
        json.dumps(
            {
                **_curation("s1"),
                "albums": [
                    {
                        "album_id": "a1",
                        "provider": "spotify",
                        "include": True,
                        "title": "Folge 1",
                    }
                ],
            }
        )
    )

    def fake_load_raw(_path=None):
        return {"series": [{"id": "s1", "title": "S1"}]}

    monkeypatch.setattr(apply_ops, "load_raw", fake_load_raw)
    monkeypatch.setattr(apply_ops, "save_raw", lambda *a, **k: None)

    result = CliRunner().invoke(apply, ["--all"])
    assert result.exit_code == 1, result.output
    assert "incomplete" in result.output


def test_missing_single_series_file_is_an_error(scratch):
    runner = CliRunner()
    result = runner.invoke(apply, ["nope"], catch_exceptions=False)
    assert result.exit_code == 1


def test_misnamed_file_is_refused(scratch):
    """The filename is what names the series; an id inside the file that
    disagrees would apply one series' albums into another's entry."""
    (scratch / "s1.json").write_text(json.dumps({**_curation("s1"), "id": "s2"}))
    runner = CliRunner()
    result = runner.invoke(apply, ["s1"], catch_exceptions=False)
    assert result.exit_code == 1
    assert "s1" in result.output


def test_status_flag_is_gone(scratch):
    """`--status` never did anything (should_apply refuses anything not
    approved); carrying it invites the belief that it can."""
    result = CliRunner().invoke(apply, ["--all", "--status", "curated"])
    assert result.exit_code != 0
    assert "No such option" in result.output