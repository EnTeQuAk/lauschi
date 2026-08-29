"""Score every sample curation under a scratch root against ground truth."""

from __future__ import annotations

import json
from pathlib import Path

from lauschi_catalog.eval.critic import CriticScore, critic_score
from lauschi_catalog.eval.discography import fetch_discography
from lauschi_catalog.eval.sample import SAMPLE_IDS
from lauschi_catalog.eval.score import Score, score
from lauschi_catalog.eval.truth import load_truth


def load_verdicts(path: Path) -> dict[str, dict]:
    """Canon audit verdicts keyed by series id.

    Accepts either a JSON object ``{series_id: verdict}`` or the raw
    agent journal (JSON lines with a ``result`` per record), so the
    extracted file and the original source score identically.
    """
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".jsonl":
        verdicts: dict[str, dict] = {}
        for line in text.splitlines():
            if not line.strip():
                continue
            result = json.loads(line).get("result")
            if isinstance(result, dict) and result.get("id"):
                verdicts[result["id"]] = result
        return verdicts
    return json.loads(text)


def score_critic_root(
    curator_root: Path,
    audited_root: Path,
    *,
    critic: str,
    truth_curation_dir: Path,
    providers: list,
    verdicts: dict[str, dict],
    series_ids: tuple[str, ...] = SAMPLE_IDS,
) -> tuple[list[CriticScore], list[str]]:
    """Score a critic by comparing the curator's output under
    ``curator_root`` with the audited copy under ``audited_root``.
    Series missing from either root are reported, never skipped."""
    scores: list[CriticScore] = []
    missing: list[str] = []
    for sid in series_ids:
        rel = Path("assets") / "catalog" / "curation" / f"{sid}.json"
        before_path, after_path = curator_root / rel, audited_root / rel
        if not (before_path.is_file() and after_path.is_file()):
            missing.append(sid)
            continue
        before = json.loads(before_path.read_text(encoding="utf-8"))
        after = json.loads(after_path.read_text(encoding="utf-8"))
        truth = load_truth(
            sid,
            curation_path=truth_curation_dir / f"{sid}.json",
            discography=fetch_discography(
                providers, before.get("provider_artist_ids") or {}
            ),
            verdict=verdicts.get(sid),
        )
        scores.append(critic_score(before, after, truth, critic=critic))
    return scores, missing


def score_root(
    scratch_root: Path,
    *,
    model: str,
    truth_curation_dir: Path,
    providers: list,
    verdicts: dict[str, dict],
    series_ids: tuple[str, ...] = SAMPLE_IDS,
) -> tuple[list[Score], list[str]]:
    """Returns scores for every sample series with a curation under
    ``scratch_root`` and the ids that have none (a run that failed or
    has not finished). Missing ones are reported, never skipped silently."""
    scores: list[Score] = []
    missing: list[str] = []
    for sid in series_ids:
        candidate = scratch_root / "assets" / "catalog" / "curation" / f"{sid}.json"
        if not candidate.is_file():
            missing.append(sid)
            continue
        curation = json.loads(candidate.read_text(encoding="utf-8"))
        truth = load_truth(
            sid,
            curation_path=truth_curation_dir / f"{sid}.json",
            discography=fetch_discography(
                providers, curation.get("provider_artist_ids") or {}
            ),
            verdict=verdicts.get(sid),
        )
        scores.append(score(curation, truth, model=model))
    return scores, missing
