"""Library functions for applying curations to series.yaml.

Pure business logic with no console output. Progress is reported via
callbacks so both the CLI and the web UI can consume it.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass, field

from lauschi_catalog.catalog.lifecycle import apply_is_unsafe
from lauschi_catalog.catalog.loader import load_raw, save_raw
from lauschi_catalog.catalog.paths import CURATION_DIR

Progress = Callable[[str], None]


def _noop(_msg: str) -> None:
    pass


@dataclass
class ApplyOneResult:
    """Result of applying a single curation."""

    series_id: str
    updated: bool = False
    skipped_reason: str | None = None


@dataclass
class ApplyResult:
    """Result of applying curations."""

    applied: int = 0
    skipped: int = 0
    details: list[ApplyOneResult] = field(default_factory=list)
    written: bool = False


def filter_confirmed_facts(facts: dict) -> dict | None:
    """Keep only audited facts for series.yaml.

    Facts without audited_by stay in the curation JSON for human
    review. Provenance fields are preserved in yaml as audit trail.
    """
    result: dict[str, list[dict]] = {}
    for key in ("era_boundaries", "known_gaps", "sub_series"):
        kept = []
        for item in facts.get(key, []):
            audited = item.get("audited_by")
            if audited:
                kept.append(item)
        if kept:
            result[key] = kept
    return result if result else None


def should_apply(data: dict, force: bool) -> str | None:
    """Return a human-readable refusal reason, or None if safe to apply.

    Defense-in-depth checks before apply_one writes to series.yaml.
    """
    if not force:
        unsafe = apply_is_unsafe(data)
        if unsafe is not None:
            return f"refusing to apply — {unsafe} (use --force to override)"

        cur_status = data.get("review", {}).get("status", "curated")
        if cur_status == "escalated":
            return (
                "refusing to apply — status is 'escalated' "
                "(audit flagged significant problems). Resolve via "
                "catalog-review, or use --force to override."
            )
        if cur_status not in ("approved", "ai_verified"):
            return (
                f"refusing to apply — status is '{cur_status}' "
                f"(run audit first). Use --force to override."
            )
    return None


def apply_one(
    series_id: str,
    data: dict,
    yaml_data: dict,
    *,
    on_progress: Progress = _noop,
) -> bool:
    """Apply a single curation to the yaml data. Returns True if updated."""
    albums = data.get("albums", [])
    included = [a for a in albums if a.get("include")]

    if not included:
        on_progress(f"  {series_id}: no included albums")
        return False

    by_provider: dict[str, list[dict]] = {}
    for a in included:
        prov = a.get("provider", "spotify")
        by_provider.setdefault(prov, []).append(a)

    yaml_series = None
    for entry in yaml_data.get("series", []):
        if entry.get("id") == series_id:
            yaml_series = entry
            break

    if yaml_series is None:
        on_progress(f"  {series_id}: not in series.yaml, skipping")
        return False

    if "providers" not in yaml_series:
        yaml_series["providers"] = {}

    updated = False

    for prov_name, prov_albums in by_provider.items():
        sorted_albums = sorted(
            prov_albums,
            key=lambda a: (
                a.get("episode_num") is None,
                a.get("episode_num"),
                a.get("release_date") or "",
                a.get("title", ""),
            ),
        )

        if prov_name not in yaml_series["providers"]:
            yaml_series["providers"][prov_name] = {}

        prov_section = yaml_series["providers"][prov_name]

        album_entries = []
        for a in sorted_albums:
            entry: dict[str, str | int | None] = {"id": a["album_id"]}
            if a.get("episode_num") is not None:
                entry["episode"] = a["episode_num"]
            entry["title"] = a["title"]
            album_entries.append(entry)

        existing: list[dict] = prov_section.get("albums", []) or []

        def _sig(entry: dict) -> tuple[str | None, int | None, str | None]:
            return (entry.get("id"), entry.get("episode"), entry.get("title"))

        existing_ids = {e.get("id") for e in existing}
        new_ids = {e["id"] for e in album_entries}
        existing_sigs = {_sig(e) for e in existing}
        new_sigs = {_sig(e) for e in album_entries}

        if new_sigs != existing_sigs:
            prov_section["albums"] = album_entries
            updated = True
            ep_changed = len(new_sigs - existing_sigs) - len(new_ids - existing_ids)
            on_progress(
                f"  {prov_name}: {len(album_entries)} albums "
                f"({len(new_ids - existing_ids)} new, "
                f"{len(existing_ids - new_ids)} removed, "
                f"{max(ep_changed, 0)} episode/title changes)",
            )

    pattern = data.get("episode_pattern")
    yaml_pattern = yaml_series.get("episode_pattern")
    if pattern != yaml_pattern:
        if pattern is None:
            yaml_series.pop("episode_pattern", None)
        else:
            yaml_series["episode_pattern"] = pattern
        updated = True

    ct = data.get("content_type")
    yaml_ct = yaml_series.get("content_type")
    has_other_hoerspiel_signal = yaml_series.get("episode_pattern") is not None
    if ct == "hoerspiel":
        if yaml_ct is not None and has_other_hoerspiel_signal:
            del yaml_series["content_type"]
            updated = True
        elif yaml_ct != "hoerspiel" and not has_other_hoerspiel_signal:
            yaml_series["content_type"] = "hoerspiel"
            updated = True
    elif ct and ct != yaml_ct:
        yaml_series["content_type"] = ct
        updated = True

    prov_artist_ids = data.get("provider_artist_ids", {})
    for prov_name, aids in prov_artist_ids.items():
        if aids and prov_name in yaml_series["providers"]:
            current = yaml_series["providers"][prov_name].get("artist_ids", [])
            if set(str(a) for a in aids) != set(str(a) for a in current):
                yaml_series["providers"][prov_name]["artist_ids"] = [
                    str(a) for a in aids
                ]
                updated = True

    aliases = data.get("aliases")
    if aliases and aliases != yaml_series.get("aliases"):
        yaml_series["aliases"] = aliases
        updated = True

    facts = data.get("series_facts")
    if facts:
        confirmed = filter_confirmed_facts(facts)
        if confirmed != yaml_series.get("series_facts"):
            if confirmed:
                yaml_series["series_facts"] = confirmed
            else:
                yaml_series.pop("series_facts", None)
            updated = True

    return updated


def apply_curations(
    series_id: str | None = None,
    *,
    run_all: bool = False,
    allowed_statuses: set[str] | None = None,
    dry_run: bool = False,
    force: bool = False,
    on_progress: Progress = _noop,
) -> ApplyResult:
    """Apply approved curations to series.yaml.

    With ``series_id``, applies a single curation. With ``run_all``,
    applies all approved curations. Returns a structured result.
    """
    if allowed_statuses is None:
        allowed_statuses = {"approved", "ai_verified"}

    if not series_id and not run_all:
        return ApplyResult()

    if series_id:
        paths = [CURATION_DIR / f"{series_id}.json"]
    else:
        paths = sorted(CURATION_DIR.glob("*.json"))

    yaml_data = load_raw()
    result = ApplyResult()

    for path in paths:
        if not path.exists():
            continue

        data = json.loads(path.read_text())
        sid = data.get("id", path.stem)

        review = data.get("review", {})
        cur_status = review.get("status", "curated")
        if cur_status not in allowed_statuses and not series_id:
            result.skipped += 1
            result.details.append(ApplyOneResult(sid, skipped_reason="status mismatch"))
            continue

        refusal = should_apply(data, force)
        if refusal is not None:
            on_progress(f"{data.get('title', sid)}: {refusal}")
            result.skipped += 1
            result.details.append(ApplyOneResult(sid, skipped_reason=refusal))
            continue

        title = data.get("title", sid)
        on_progress(f"{title} (status: {cur_status})")

        if apply_one(sid, data, yaml_data, on_progress=on_progress):
            result.applied += 1
            result.details.append(ApplyOneResult(sid, updated=True))
        else:
            result.skipped += 1
            result.details.append(ApplyOneResult(sid))

    if result.applied > 0 and not dry_run:
        save_raw(yaml_data)
        result.written = True
        on_progress(f"Applied {result.applied} curations to series.yaml")
    elif result.applied > 0:
        on_progress(f"Dry run: {result.applied} would be applied")
    else:
        on_progress(f"Nothing to apply ({result.skipped} skipped)")

    return result
