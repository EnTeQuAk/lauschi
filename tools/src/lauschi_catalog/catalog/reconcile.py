"""Cross-provider reconciliation and exclude_reason normalization.

Detects same-title albums with inconsistent include/exclude decisions
across providers and either auto-fixes (flips) or flags them for
human review depending on the exclude_reason category.
"""

import re
from dataclasses import dataclass, field

from lauschi_catalog.catalog import reasons
from lauschi_catalog.catalog.analysis import normalize_title

EXCLUDE_REASONS: frozenset[str] = frozenset(reasons.CURATE_REASON_KEYS)

#: Reasons set outside the curate agent (audit, manual edits)
_EXTRA_VALID: frozenset[str] = frozenset(reasons.ALL_REASON_KEYS - EXCLUDE_REASONS)

ALL_KNOWN_REASONS: frozenset[str] = reasons.ALL_REASON_KEYS

# Auto-flip: these exclusions on one provider are almost certainly wrong
# when the same title is included on the other provider.
_AUTO_FLIP_REASONS: frozenset[str] = reasons.AUTO_FLIP_REASON_KEYS

# Flag for review: structural decisions that may be correct on both sides.
_FLAG_REASONS: frozenset[str] = reasons.FLAG_REASON_KEYS


def normalize_exclude_reason(reason: str | None) -> str | None:
    """Map verbose agent-generated reasons to their short label.

    Returns the reason unchanged if it's already a known label,
    extracts the label from verbose text if possible, or falls
    back to "unspecified".
    """
    if reason is None:
        return None
    if reason == "":
        return ""
    if reason in ALL_KNOWN_REASONS:
        return reason

    lower = reason.lower()

    # Try to extract a known label from the verbose text.
    # Check longest labels first to avoid partial matches.
    for label in sorted(EXCLUDE_REASONS, key=len, reverse=True):
        # Match the label as a distinct token (word boundary or punctuation).
        if re.search(rf"\b{re.escape(label)}\b", lower):
            return label

    # "wrong content type" with spaces instead of underscores
    if "wrong content type" in lower or "wrong_content_type" in lower:
        return "wrong_content_type"
    if "music single" in lower or "music_single" in lower:
        return "music_single"

    return "unspecified"


@dataclass
class ReconcileResult:
    flipped: int = 0
    flagged: int = 0
    details: list[dict] = field(default_factory=list)


def _norm_title(title: str) -> str:
    """Cross-provider title fold, shared with lint.

    Kept as a private alias so the reconcile call sites read the same
    as they always did; the definition lives in analysis.normalize_title.
    """
    return normalize_title(title)


def reconcile_cross_provider(albums: list[dict]) -> ReconcileResult:
    """Detect and fix cross-provider mismatches in a single curation.

    Mutates albums in place. Returns a summary of changes.

    Rules:
    - Content-classification reasons (wrong_content_type, music_single,
      compilation, etc.) on one provider + included on the other:
      auto-flip to include. Same content can't be a different type on
      a different provider.
    - Structural reasons (sub_series_bleed, different_series): flag for
      human review. These reflect catalog-level decisions that may be
      correct on both sides.
    """
    result = ReconcileResult()

    by_title: dict[str, list[dict]] = {}
    for a in albums:
        by_title.setdefault(_norm_title(a.get("title", "")), []).append(a)

    for title, entries in by_title.items():
        sp = [e for e in entries if e.get("provider") == "spotify"]
        am = [e for e in entries if e.get("provider") == "apple_music"]
        if not sp or not am:
            continue

        sp_has_include = any(e.get("include") for e in sp)
        am_has_include = any(e.get("include") for e in am)

        if sp_has_include == am_has_include:
            continue

        if sp_has_include and not am_has_include:
            excluded_side = am
        else:
            excluded_side = sp

        for album in excluded_side:
            if album.get("include"):
                continue
            reason = normalize_exclude_reason(album.get("exclude_reason"))
            original_title = album.get("title", title)
            if reason in _AUTO_FLIP_REASONS:
                album["include"] = True
                album.pop("exclude_reason", None)
                result.flipped += 1
                result.details.append(
                    {
                        "title": original_title,
                        "album_id": album["album_id"],
                        "provider": album.get("provider"),
                        "old_reason": reason,
                        "action": "flipped",
                    }
                )
            elif reason in _FLAG_REASONS:
                result.flagged += 1
                result.details.append(
                    {
                        "title": original_title,
                        "album_id": album["album_id"],
                        "provider": album.get("provider"),
                        "reason": reason,
                        "action": "flagged",
                    }
                )

    return result
