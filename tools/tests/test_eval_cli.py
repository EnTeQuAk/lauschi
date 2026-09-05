"""The eval command scores any root's series, with or without verdicts.

The fixed 12-series sample is the default, but a before/after check on a
prompt change needs the boundary series that change touches, and the
canon verdicts file is optional: precision and recall against the
committed truth need no verdicts, only gap recovery does.
"""

from pathlib import Path

import pytest
from click.testing import CliRunner

from lauschi_catalog.commands import eval as eval_mod


class _Result:
    warnings: list[str] = []
    providers = ["spotify", "apple_music"]


def test_series_option_selects_what_is_scored(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    seen: dict = {}

    def fake_score_root(root, **kw):
        seen.update(kw)
        return [], []

    monkeypatch.setattr(eval_mod, "init_providers", lambda **_: _Result())
    monkeypatch.setattr(eval_mod, "score_root", fake_score_root)
    root = tmp_path / "scratch"
    (root / "assets/catalog/curation").mkdir(parents=True)
    result = CliRunner().invoke(
        eval_mod.eval_cmd,
        [
            "--root",
            str(root),
            "--model",
            "m",
            "-s",
            "kira_kolumna",
            "-s",
            "was_ist_was",
        ],
    )
    assert result.exit_code == 0, result.output
    assert seen["series_ids"] == ("kira_kolumna", "was_ist_was")
    assert seen["verdicts"] == {}


def test_without_series_the_fixed_sample_is_scored(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    seen: dict = {}

    def fake_score_root(root, **kw):
        seen.update(kw)
        return [], []

    monkeypatch.setattr(eval_mod, "init_providers", lambda **_: _Result())
    monkeypatch.setattr(eval_mod, "score_root", fake_score_root)
    root = tmp_path / "scratch"
    root.mkdir()
    result = CliRunner().invoke(
        eval_mod.eval_cmd, ["--root", str(root), "--model", "m"]
    )
    assert result.exit_code == 0, result.output
    assert seen["series_ids"] == eval_mod.SAMPLE_IDS
