"""A person's verdict on an audit that escalated."""

import json
from dataclasses import dataclass
from datetime import UTC, datetime

from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.lifecycle import audit_is_stale, review_block
from lauschi_catalog.catalog.paths import curation_path


@dataclass
class ResolveResult:
    ok: bool
    error: str | None = None


def resolve_escalation(series_id: str, note: str) -> ResolveResult:
    """Approve an escalated curation a person has judged.

    The curation and its albums stay as the curator left them. The review
    turns approved and records who resolved it, when and why, so apply
    ships the entry and the review lists drop it. The next audit writes
    its own verdict over this one, and the next curate clears the review.
    """
    path = curation_path(series_id)
    if not path.exists():
        return ResolveResult(ok=False, error="curation not found")
    data = json.loads(path.read_text())
    review = review_block(data)
    if review.get("status") != "escalated":
        return ResolveResult(ok=False, error="not escalated, nothing to resolve")
    if audit_is_stale(data):
        return ResolveResult(
            ok=False,
            error="curate ran after the last audit, audit it again first",
        )
    review["status"] = "approved"
    review["resolved"] = {
        "by": "operator",
        "at": datetime.now(tz=UTC).isoformat(),
        "note": note,
    }
    data["review"] = review
    safe_write_json(path, data)
    return ResolveResult(ok=True)
