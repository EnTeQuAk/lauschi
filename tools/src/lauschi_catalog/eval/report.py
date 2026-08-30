"""Render scores as a table people read and a JSON file scripts re-read."""

from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

from lauschi_catalog.eval.critic import CriticScore
from lauschi_catalog.eval.sample import SAMPLE
from lauschi_catalog.eval.score import Score

_STRATUM = {s.id: s.stratum for s in SAMPLE}


def _pct(v: float | None) -> str:
    return "n/a" if v is None else f"{v * 100:5.1f}%"


def _mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def aggregate(scores: list[Score]) -> dict:
    """Aggregate over series with the disqualifier surfaced first.

    Precision and recall are averaged per series (macro), so a huge
    series cannot mask a small one. Hallucination is a total, because a
    single invented album anywhere is the fact that matters.
    """
    return {
        "n_series": len(scores),
        "hallucinated_total": sum(len(s.hallucinated) for s in scores),
        "series_with_hallucination": sorted(
            s.series_id for s in scores if s.hallucinated
        ),
        "undecided_total": sum(s.n_undecided for s in scores),
        "include_precision": _mean([s.include_precision for s in scores]),
        "include_recall": _mean([s.include_recall for s in scores]),
        "gap_recovery": _mean(
            [s.gap_recovery for s in scores if s.gap_recovery is not None]
        ),
    }


def render_table(scores: list[Score]) -> str:
    rows = [
        "| series | stratum | precision | recall | gaps | halluc. | undec. | included |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for s in sorted(scores, key=lambda x: (_STRATUM.get(x.series_id, ""), x.series_id)):
        name = f"{s.series_id} (INCOMPLETE run)" if s.incomplete else s.series_id
        rows.append(
            f"| {name} | {_STRATUM.get(s.series_id, '?')} | {_pct(s.include_precision)} "
            f"| {_pct(s.include_recall)} | {_pct(s.gap_recovery)} | {len(s.hallucinated)} "
            f"| {s.n_undecided} | {s.n_included}/{s.n_truth_included} |"
        )
    agg = aggregate(scores)
    rows.append(
        f"| **mean** | | {_pct(agg['include_precision'])} | {_pct(agg['include_recall'])} "
        f"| {_pct(agg['gap_recovery'])} | {agg['hallucinated_total']} "
        f"| {agg['undecided_total']} | |"
    )
    return "\n".join(rows)


def render_critic_table(scores: list[CriticScore]) -> str:
    rows = [
        "| series | mistakes | fixed | broken | fix rate | overrides | verdict |",
        "|---|---:|---:|---:|---:|---:|---|",
    ]
    verdict = {True: "approved", False: "escalated", None: "none"}
    for s in sorted(scores, key=lambda x: (_STRATUM.get(x.series_id, ""), x.series_id)):
        rows.append(
            f"| {s.series_id} | {s.n_mistakes} | {s.n_fixed} | {s.n_broken} "
            f"| {_pct(s.fix_rate)} | {s.n_overrides} | {verdict[s.approved]} |"
        )
    n_mistakes = sum(s.n_mistakes for s in scores)
    n_fixed = sum(s.n_fixed for s in scores)
    n_broken = sum(s.n_broken for s in scores)
    rate = n_fixed / n_mistakes if n_mistakes else None
    rows.append(
        f"| **total** | {n_mistakes} | {n_fixed} | {n_broken} | {_pct(rate)} "
        f"| {sum(s.n_overrides for s in scores)} | |"
    )
    return "\n".join(rows)


def render_details(scores: list[Score]) -> str:
    """Every disagreement, so a number can be traced to an album."""
    lines: list[str] = []
    for s in sorted(scores, key=lambda x: x.series_id):
        if not s.disagreements:
            continue
        lines.append(f"\n{s.series_id}: {len(s.disagreements)} disagreement(s)")
        for d in s.disagreements:
            arrow = "truth OUT, model IN" if d.model_include else "truth IN, model OUT"
            reason = f"  [{d.reason}]" if d.reason else ""
            lines.append(f"  {arrow}  {d.provider}:{d.album_id}  {d.title}{reason}")
    return "\n".join(lines)


def write_json(scores: list[Score], path: Path) -> None:
    payload = {
        "aggregate": aggregate(scores),
        "series": [
            {
                **asdict(s),
                "hallucinated": sorted(
                    f"{k.provider}:{k.album_id}" for k in s.hallucinated
                ),
            }
            for s in scores
        ],
    }
    path.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
