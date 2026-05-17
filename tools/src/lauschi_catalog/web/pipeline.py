"""Pipeline state computation for catalog series.

Derives the current pipeline step for a series by inspecting
curation JSON and series.yaml. Steps are ordered:

1. Discover  (artist IDs present in series.yaml)
2. Curate   (curation JSON exists with curated_at)
3. Review   (curation JSON has review.reviewed_at)
4. Verify   (curation JSON has review.verification)
5. Apply    (albums written to series.yaml)
6. Validate (validated_at in curation JSON)

"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.web.catalog_db import get_series_by_id
from lauschi_catalog.web.config import CURATION_DIR

_PIPELINE_STEPS = [
    ("discover", "Discover"),
    ("curate", "Curate"),
    ("review", "Review"),
    ("verify", "Verify"),
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

    # Check curation JSON
    curation_path = CURATION_DIR / f"{series_id}.json"
    curation: dict[str, Any] | None = None
    if curation_path.exists():
        curation = json.loads(curation_path.read_text())

    step_statuses: list[str] = []
    current_step = 0

    # Step 0: Discover — any provider has artist_ids
    has_artists = bool(series.providers)
    step_statuses.append("done" if has_artists else "current")
    if not has_artists:
        current_step = 0

    # Step 1: Curate — curation JSON exists with curated_at
    has_curation = curation is not None and curation.get("curated_at")
    if has_artists:
        step_statuses.append("done" if has_curation else "current")
        if not has_curation:
            current_step = 1

    # Step 2: Review — review block with reviewed_at
    has_review = curation is not None and curation.get("review", {}).get("reviewed_at")
    if has_curation:
        step_statuses.append("done" if has_review else "current")
        if not has_review:
            current_step = 2

    # Step 3: Verify — verification block exists
    verification = curation.get("review", {}).get("verification") if curation else None
    if has_review:
        if verification and verification.get("status") == "escalated":
            step_statuses.append("escalated")
            current_step = 3
        elif verification:
            step_statuses.append("done")
        else:
            step_statuses.append("current")
            current_step = 3

    # Step 4: Apply — albums are in series.yaml (any albums under provider config)
    has_applied = any(prov_cfg.has_albums for prov_cfg in series.providers.values())
    if verification and verification.get("status") != "escalated":
        step_statuses.append("done" if has_applied else "current")
        if not has_applied:
            current_step = 4

    # Step 5: Validate — validated_at in curation
    has_validated = curation is not None and curation.get("validated_at")
    if has_applied:
        step_statuses.append("done" if has_validated else "current")
        if not has_validated:
            current_step = 5

    # Fill any remaining steps (e.g. if series has no curation at all)
    while len(step_statuses) < len(_PIPELINE_STEPS):
        step_statuses.append("pending")

    # If every step is done, mark as fully complete
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
        2: "review",
        3: "verify",
        4: "apply",
        5: "validate",
    }
    return step_map.get(state.current_step, "validate")
