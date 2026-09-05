"""Library functions for applying curations to series.yaml.

Pure business logic with no console output. Progress is reported via
callbacks so both the CLI and the web UI can consume it.
"""

import json
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from lauschi_catalog.catalog.canonical import album_sort_key
from lauschi_catalog.catalog.io import locked_raw, safe_write_yaml
from lauschi_catalog.catalog.lifecycle import (
    CurationState,
    apply_blockers,
)
from lauschi_catalog.catalog.paths import (
    curation_dir,
    curation_path,
    series_yaml_path,
)

Progress = Callable[[str], None]


def _noop(_msg: str) -> None:
    pass


@dataclass
class ApplyOneResult:
    """Result of applying a single curation.

    ``refused`` marks a gate block (incomplete run, stale audit,
    escalated, missing file, filename/id mismatch): the run must fail
    so the refusal cannot scroll past. A plain "not approved" skip is
    normal pipeline state, not a refusal.
    """

    series_id: str
    updated: bool = False
    skipped_reason: str | None = None
    refused: bool = False


@dataclass
class ApplyResult:
    """Result of applying curations."""

    applied: int = 0
    skipped: int = 0
    details: list[ApplyOneResult] = field(default_factory=list)
    written: bool = False


def filter_confirmed_facts(facts: dict) -> dict | None:
    """The audited subset of a curation's series facts.

    Facts are frozen into series.yaml only once audit confirms them;
    one stale item is enough to tag the whole block as still in motion.
    """
    result: dict = {}
    for key in ("era_boundaries", "known_gaps", "sub_series"):
        kept = []
        for item in facts.get(key, []):
            audited = item.get("audited_by")
            if audited:
                kept.append(item)
        if kept:
            result[key] = kept
    return result if result else None


def _load_curation_file(path: Path) -> dict:
    """Read one curation JSON by its path; load_curation keys by id."""
    return json.loads(path.read_text(encoding="utf-8"))


def _yaml_series(yaml_data: dict, series_id: str) -> dict | None:
    for entry in yaml_data.get("series", []):
        if entry.get("id") == series_id:
            return entry
    return None


def should_apply(data: dict, allow_unreviewed: bool = False) -> str | None:
    """Return a human-readable refusal reason, or None if safe to apply.

    The one review gate: any critical problem (incomplete run, stale
    audit, critical regression) blocks regardless of the review status,
    an escalated series stays blocked by name, and anything not
    approved must be audited first. ``--allow-unreviewed`` skips
    exactly this gate; the loss guard is its own decision
    (--allow-loss), so a refusing run still protects against a fetch
    failure wiping the catalog.
    """
    if allow_unreviewed:
        return None
    state = CurationState.from_curation(data)
    for blocker in apply_blockers(state):
        return f"refusing to apply — {blocker} (use --allow-unreviewed to override)"
    return None


def apply_one(
    series_id: str,
    data: dict,
    yaml_data: dict,
    *,
    allow_loss: bool = False,
    on_progress: Progress = _noop,
) -> bool:
    """Apply a single curation to the yaml data. Returns True if updated.

    Atomic per entry: every guard runs before any mutation, so a
    tripped guard leaves the whole yaml entry exactly as it was. A
    curation including far fewer albums than yaml holds is a fetch
    failure in progress, not a decision; overriding that refusal is
    its own flag (--allow-loss). The review gates live in
    should_apply; this function only guards against data loss.
    """
    albums = data.get("albums", [])
    included = [a for a in albums if a.get("include")]

    if not included:
        yaml_series = _yaml_series(yaml_data, series_id)
        old_count = 0
        if yaml_series is not None:
            old_count = sum(
                len(p.get("albums") or [])
                for p in (yaml_series.get("providers") or {}).values()
            )
        if old_count:
            on_progress(
                f"  {series_id}: curation includes 0 albums but series.yaml "
                f"has {old_count}: not clearing (see catalog-drift)"
            )
        else:
            on_progress(f"  {series_id}: no included albums")
        return False

    yaml_series = _yaml_series(yaml_data, series_id)
    if yaml_series is None:
        on_progress(f"  {series_id}: not in series.yaml, skipping")
        return False

    by_provider: dict[str, list[dict]] = {}
    for a in included:
        prov = a.get("provider", "spotify")
        by_provider.setdefault(prov, []).append(a)

    if "providers" not in yaml_series:
        yaml_series["providers"] = {}

    # Pre-compute every provider's new album list and run ALL guards
    # before touching the entry, so a tripped guard cannot leave the
    # pattern or facts applied over the old albums.
    planned: dict[str, list[dict]] = {}
    for prov_name, prov_albums in by_provider.items():
        album_entries = []
        for a in sorted(prov_albums, key=album_sort_key):
            entry: dict[str, str | int | None] = {"id": a["album_id"]}
            if a.get("episode_num") is not None:
                entry["episode"] = a["episode_num"]
            entry["title"] = a["title"]
            # The app hides an album dated after today, so a pre-release
            # ships included and appears on its own once the date passes.
            if a.get("release_date"):
                entry["release_date"] = a["release_date"]
            album_entries.append(entry)
        planned[prov_name] = album_entries

    if not allow_loss:
        for prov_name, album_entries in planned.items():
            existing: list[dict] = (
                yaml_series.get("providers", {}).get(prov_name, {}).get("albums")
            ) or []
            if len(existing) >= 10 and len(album_entries) < len(existing) * 0.5:
                # Guard: refuse to replace when a provider's album count
                # drops by more than half. Catches API fetch issues (e.g.
                # Spotify returning only recent albums) that would
                # silently wipe curated data from series.yaml.
                on_progress(
                    f"  {prov_name}: REFUSED — would drop from "
                    f"{len(existing)} to {len(album_entries)} albums "
                    f"(>50% loss). Entry left unchanged; use --allow-loss "
                    f"if the drop is real."
                )
                return False

    def _sig(entry: dict) -> tuple[str | None, int | None, str | None, str | None]:
        return (
            entry.get("id"),
            entry.get("episode"),
            entry.get("title"),
            entry.get("release_date"),
        )

    updated = False
    for prov_name, album_entries in planned.items():
        prov_section = yaml_series.setdefault("providers", {}).setdefault(prov_name, {})
        existing: list[dict] = prov_section.get("albums", []) or []

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
    allow_unreviewed: bool = False,
    allow_loss: bool = False,
    dry_run: bool = False,
    on_progress: Progress = _noop,
) -> ApplyResult:
    """Apply approved curations to series.yaml.

    With ``series_id``, applies a single curation (a missing file or a
    filename/id mismatch is an error). With ``run_all``, applies every
    approved curation and skips the rest. The series.yaml read-
    modify-write holds the catalog lock the whole way, so a concurrent
    web edit can't be dropped between load and save.
    """
    if not series_id and not run_all:
        return ApplyResult()

    if series_id:
        paths = [curation_path(series_id)]
        single = True
    else:
        paths = sorted(curation_dir().glob("*.json"))
        single = False

    result = ApplyResult()
    with locked_raw() as yaml_data:
        for path in paths:
            if not path.exists():
                if single:
                    on_progress(f"No curation file for {series_id}: {path}")
                    result.details.append(
                        ApplyOneResult(
                            series_id or "",
                            skipped_reason="no curation file",
                            refused=True,
                        )
                    )
                continue

            data = _load_curation_file(path)
            sid = data.get("id", path.stem)

            if sid != path.stem:
                reason = (
                    f"curation file {path.name} declares id '{sid}'; refusing "
                    "to apply one series' albums into another's yaml entry"
                )
                on_progress(f"{path.name}: {reason}")
                result.skipped += 1
                result.details.append(
                    ApplyOneResult(sid, skipped_reason=reason, refused=True)
                )
                continue

            state = CurationState.from_curation(data)
            if state.status != "approved" and not single and not allow_unreviewed:
                result.skipped += 1
                result.details.append(
                    ApplyOneResult(sid, skipped_reason="not approved")
                )
                continue

            refusal = should_apply(data, allow_unreviewed)
            if refusal is not None:
                on_progress(f"{data.get('title', sid)}: {refusal}")
                result.skipped += 1
                result.details.append(
                    ApplyOneResult(sid, skipped_reason=refusal, refused=True)
                )
                continue

            title = data.get("title", sid)
            on_progress(f"{title} (status: {state.status})")

            if apply_one(
                sid,
                data,
                yaml_data,
                allow_loss=allow_loss,
                on_progress=on_progress,
            ):
                result.applied += 1
                result.details.append(ApplyOneResult(sid, updated=True))
            else:
                result.skipped += 1
                result.details.append(ApplyOneResult(sid))

        if result.applied > 0 and not dry_run:
            # Still inside locked_raw's window; the plain atomic writer,
            # save_raw's re-lock on the same path would deadlock.
            safe_write_yaml(series_yaml_path(), yaml_data)
            result.written = True
            on_progress(f"Applied {result.applied} curations to series.yaml")

    if result.applied > 0 and dry_run:
        on_progress(f"Dry run: {result.applied} would be applied")
    elif result.applied == 0:
        on_progress(f"Nothing to apply ({result.skipped} skipped)")

    return result
