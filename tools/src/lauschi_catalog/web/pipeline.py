"""Pipeline state computation for catalog series.

Derives the current pipeline step for a series by inspecting
curation JSON and series.yaml. Steps are ordered:

1. Discover  (artist IDs present in series.yaml)
2. Curate    (curation JSON exists with curated_at)
3. Audit     (curation JSON has review.audited_at)
4. Apply     (albums written to series.yaml)
5. Validate  (validated_at in curation JSON)

"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.paths import curation_path
from lauschi_catalog.web.catalog_store import get_series_by_id

_PIPELINE_STEPS = [
    ("discover", "Discover"),
    ("curate", "Curate"),
    ("audit", "Audit"),
    ("apply", "Apply"),
    ("validate", "Validate"),
]


@dataclass
class PipelineState:
    series_id: str
    current_step: int  # 0-indexed; -1 if not in series.yaml at all
    current_label: str
    status: str  # done | current | missing | escalated | error
    step_labels: list[str]
    step_statuses: list[str]  # per-step: done | current | pending | error | escalated


def pipeline_status(
    series_id: str, series: CatalogEntry | None = None
) -> PipelineState:
    """Compute pipeline state for a series.

    Args:
        series_id: The series identifier.
        series: Pre-loaded series entry (avoids re-parsing series.yaml).
    """
    if series is None:
        series = get_series_by_id(series_id)
    if series is None:
        return PipelineState(
            series_id=series_id,
            current_step=-1,
            current_label="missing",
            status="missing",
            step_labels=[label for _, label in _PIPELINE_STEPS],
            step_statuses=["missing"] * len(_PIPELINE_STEPS),
        )

    cur_path = curation_path(series_id)
    curation: dict[str, Any] | None = None
    if cur_path.exists():
        text = cur_path.read_text().strip()
        if text:
            try:
                curation = json.loads(text)
            except json.JSONDecodeError:
                pass

    step_statuses: list[str] = []
    current_step = 0

    # Step 0: Discover
    has_artists = bool(series.providers)
    step_statuses.append("done" if has_artists else "current")
    if not has_artists:
        current_step = 0

    # Step 1: Curate
    has_curation = curation is not None and curation.get("curated_at")
    if has_artists:
        step_statuses.append("done" if has_curation else "current")
        if not has_curation:
            current_step = 1

    # Step 2: Audit
    review = curation.get("review", {}) if curation else {}
    has_audit = bool(review.get("audited_at"))
    audit_status = review.get("status", "")
    if has_curation:
        if audit_status == "escalated":
            step_statuses.append("escalated")
            current_step = 2
        elif has_audit:
            step_statuses.append("done")
        else:
            step_statuses.append("current")
            current_step = 2

    # Step 3: Apply
    has_applied = any(prov_cfg.has_albums for prov_cfg in series.providers.values())
    if has_audit and audit_status != "escalated":
        step_statuses.append("done" if has_applied else "current")
        if not has_applied:
            current_step = 3

    # Step 4: Validate
    has_validated = curation is not None and curation.get("validated_at")
    if has_applied:
        step_statuses.append("done" if has_validated else "current")
        if not has_validated:
            current_step = 4

    while len(step_statuses) < len(_PIPELINE_STEPS):
        step_statuses.append("pending")

    if all(s == "done" for s in step_statuses):
        current_step = len(_PIPELINE_STEPS)
        current_label = "Done"
        status = "done"
    elif any(s == "escalated" for s in step_statuses):
        current_label = _PIPELINE_STEPS[current_step][1]
        status = "escalated"
    elif step_statuses[current_step] == "current":
        current_label = _PIPELINE_STEPS[current_step][1]
        status = "current"
    elif step_statuses[current_step] == "missing":
        current_label = _PIPELINE_STEPS[current_step][1]
        status = "missing"
    else:
        current_label = _PIPELINE_STEPS[current_step][1]
        status = "done"

    return PipelineState(
        series_id=series_id,
        current_step=current_step,
        current_label=current_label,
        status=status,
        step_labels=[label for _, label in _PIPELINE_STEPS],
        step_statuses=step_statuses,
    )


def next_action(series_id: str, state: PipelineState | None = None) -> str:
    """Return the CLI command that should run next for this series."""
    if state is None:
        state = pipeline_status(series_id)
    if state.current_step >= len(_PIPELINE_STEPS):
        return "done"
    step_map = {
        0: "discover",
        1: "curate",
        2: "audit",
        3: "apply",
        4: "validate",
    }
    return step_map.get(state.current_step, "validate")
