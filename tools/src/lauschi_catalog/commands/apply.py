"""Apply approved curations to series.yaml.

Reads curation JSONs with status 'approved', extracts album IDs
per provider, and writes them into the providers section of series.yaml.
"""

from __future__ import annotations

import json
from pathlib import Path

import click
from rich.console import Console

from lauschi_catalog.catalog.lifecycle import apply_is_unsafe
from lauschi_catalog.catalog.loader import SERIES_YAML, load_raw, save_raw

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"


def _apply_one(series_id: str, data: dict, yaml_data: dict) -> bool:
    """Apply a single curation to the yaml data. Returns True if updated."""
    albums = data.get("albums", [])
    included = [a for a in albums if a.get("include")]

    if not included:
        console.print(f"  [dim]{series_id}: no included albums[/dim]")
        return False

    # Group by provider
    by_provider: dict[str, list[dict]] = {}
    for a in included:
        prov = a.get("provider", "spotify")
        by_provider.setdefault(prov, []).append(a)

    # Find the series entry in yaml
    yaml_series = None
    for entry in yaml_data.get("series", []):
        if entry.get("id") == series_id:
            yaml_series = entry
            break

    if yaml_series is None:
        console.print(f"  [yellow]{series_id}: not in series.yaml, skipping[/yellow]")
        return False

    if "providers" not in yaml_series:
        yaml_series["providers"] = {}

    updated = False

    for prov_name, prov_albums in by_provider.items():
        sorted_albums = sorted(
            prov_albums,
            # Numbered episodes by number, unnumbered fall back to
            # release_date (chronological for named-episode series).
            key=lambda a: (
                a.get("episode_num") is None, a.get("episode_num"),
                a.get("release_date") or "",
                a.get("title", ""),
            ),
        )

        if prov_name not in yaml_series["providers"]:
            yaml_series["providers"][prov_name] = {}

        prov_section = yaml_series["providers"][prov_name]

        # Build the albums list
        album_entries = []
        for a in sorted_albums:
            entry: dict = {"id": a["album_id"]}
            if a.get("episode_num") is not None:
                entry["episode"] = a["episode_num"]
            entry["title"] = a["title"]
            album_entries.append(entry)

        # Skip the write only when every (id, episode, title) is unchanged.
        # Comparing IDs alone misses pattern-update-driven episode number
        # changes: a review that re-extracts ep 47 from "047/Title" leaves
        # the album_id intact, so an ID-only check would silently skip
        # propagating the corrected episode number to series.yaml.
        existing = prov_section.get("albums", []) or []

        def _sig(entry: dict) -> tuple:
            return (entry.get("id"), entry.get("episode"), entry.get("title"))

        existing_ids = {e.get("id") for e in existing}
        new_ids = {e["id"] for e in album_entries}
        existing_sigs = {_sig(e) for e in existing}
        new_sigs = {_sig(e) for e in album_entries}

        if new_sigs != existing_sigs:
            prov_section["albums"] = album_entries
            updated = True
            ep_changed = len(new_sigs - existing_sigs) - len(new_ids - existing_ids)
            console.print(
                f"  {prov_name}: {len(album_entries)} albums "
                f"({len(new_ids - existing_ids)} new, "
                f"{len(existing_ids - new_ids)} removed, "
                f"{max(ep_changed, 0)} episode/title changes)",
            )

    # Sync episode_pattern in both directions FIRST, before the
    # content_type decision below. content_type's "is hoerspiel
    # redundant?" check uses the POST-sync pattern as the
    # alternative-signal check, so the pattern has to be settled
    # by then.
    pattern = data.get("episode_pattern")
    yaml_pattern = yaml_series.get("episode_pattern")
    if pattern != yaml_pattern:
        if pattern is None:
            yaml_series.pop("episode_pattern", None)
        else:
            yaml_series["episode_pattern"] = pattern
        updated = True

    # Write content_type to yaml when present in curation (music vs
    # hoerspiel). The Flutter app uses this for UI labels ("Titel" vs
    # "Folgen"). The default is hoerspiel, so where the yaml entry
    # has another hoerspiel signal (an episode_pattern), we strip
    # the redundant explicit content_type to keep the file clean.
    #
    # But when an entry has NO other signal (no episode_pattern,
    # no curation file yet), stripping content_type leaves
    # _resolve_is_music with nothing to go on and it falls back to
    # MUSIC — re-introducing the original misclassification bug. In
    # that case keep `content_type: hoerspiel` explicit so future
    # re-curates (even after deleting the curation JSON) pick the
    # right mode.
    ct = data.get("content_type")
    yaml_ct = yaml_series.get("content_type")
    has_other_hoerspiel_signal = yaml_series.get("episode_pattern") is not None
    if ct == "hoerspiel":
        if yaml_ct is not None and has_other_hoerspiel_signal:
            del yaml_series["content_type"]
            updated = True
        elif yaml_ct != "hoerspiel" and not has_other_hoerspiel_signal:
            # No other signal — keep content_type explicit so a
            # future re-curate doesn't fall back to music. If yaml
            # had "music" before, this clears it.
            yaml_series["content_type"] = "hoerspiel"
            updated = True
    elif ct and ct != yaml_ct:
        yaml_series["content_type"] = ct
        updated = True

    # Also update provider artist IDs from curation
    prov_artist_ids = data.get("provider_artist_ids", {})
    for prov_name, aids in prov_artist_ids.items():
        if aids and prov_name in yaml_series["providers"]:
            current = yaml_series["providers"][prov_name].get("artist_ids", [])
            if set(str(a) for a in aids) != set(str(a) for a in current):
                yaml_series["providers"][prov_name]["artist_ids"] = [
                    str(a) for a in aids
                ]
                updated = True

    # Update aliases
    aliases = data.get("aliases")
    if aliases and aliases != yaml_series.get("aliases"):
        yaml_series["aliases"] = aliases
        updated = True

    # Update series_facts: write only confirmed facts (discovered_by
    # and confirmed_by present). Drop unconfirmed/flagged facts so
    # the yaml doesn't carry low-trust data.
    facts = data.get("series_facts")
    if facts:
        confirmed = _filter_confirmed_facts(facts)
        if confirmed != yaml_series.get("series_facts"):
            if confirmed:
                yaml_series["series_facts"] = confirmed
            else:
                yaml_series.pop("series_facts", None)
            updated = True

    return updated


def _filter_confirmed_facts(facts: dict) -> dict | None:
    """Strip unconfirmed/flagged facts before writing to series.yaml.

    Only keep facts that have been confirmed_by a verify pass or human
    review. Facts with verify_status='disagreed' or missing confirmed_by
    stay in the curation JSON for human review but don't pollute the
    canonical yaml.

    Provenance fields (discovered_by, confirmed_by, confirmed_at) are
    preserved in yaml — they're the audit trail that distinguishes
    documented history from hallucination.
    """
    result: dict[str, list[dict]] = {}
    for key in ("era_boundaries", "known_gaps", "sub_series"):
        kept = []
        for item in facts.get(key, []):
            if item.get("confirmed_by") and item.get("confirmed_at"):
                # Keep provenance in yaml; strip curation-time fields
                kept.append({
                    k: v for k, v in item.items()
                    if k not in ("verify_status", "verify_reasoning")
                })
        if kept:
            result[key] = kept
    return result if result else None


def _should_apply(data: dict, force: bool) -> str | None:
    """Return a human-readable refusal reason, or None if safe to apply.

    Defense-in-depth checks before _apply_one writes to series.yaml.
    """
    if not force:
        unsafe = apply_is_unsafe(data)
        if unsafe is not None:
            return f"refusing to apply — {unsafe} (use --force to override)"

        cur_status = data.get("review", {}).get("status", "curated")
        if cur_status == "escalated":
            return (
                "refusing to apply — status is 'escalated' "
                "(verify found incoherent output). Resolve via catalog-review, "
                "or use --force to override."
            )
        # ai_verified means verify approved but flagged some facts.
        # That's fine to apply — the facts are in the JSON for human
        # review but the album decisions are sound.
        if cur_status not in ("approved", "ai_verified"):
            return (
                f"refusing to apply — status is '{cur_status}' "
                f"(run verify first). Use --force to override."
            )
    return None


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Apply all approved curations")
@click.option(
    "--status", default="approved,ai_verified",
    help="Only apply curations with this status (comma-separated)",
)
@click.option("--dry-run", is_flag=True, help="Don't write changes")
@click.option(
    "--force",
    is_flag=True,
    help="Skip the lifecycle staleness check (apply even if review or verify is stale)",
)
def apply(series_id: str | None, run_all: bool, status: str, dry_run: bool, force: bool):
    """Apply approved curations to series.yaml.

    Reads curation JSONs, extracts per-provider album IDs, and writes
    them into the providers section of series.yaml. Only processes
    curations with the specified status (default: approved).
    """
    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    if series_id:
        paths = [CURATION_DIR / f"{series_id}.json"]
    else:
        paths = sorted(CURATION_DIR.glob("*.json"))

    yaml_data = load_raw()
    applied = 0
    skipped = 0

    for path in paths:
        if not path.exists():
            continue

        data = json.loads(path.read_text())
        sid = data.get("id", path.stem)

        # Check status
        review = data.get("review", {})
        cur_status = review.get("status", "curated")
        allowed = {s.strip() for s in status.split(",")}
        if cur_status not in allowed and not series_id:
            skipped += 1
            continue

        refusal = _should_apply(data, force)
        if refusal is not None:
            console.print(f"[yellow]{data.get('title', sid)}: {refusal}[/yellow]")
            skipped += 1
            continue

        console.print(f"[bold]{data.get('title', sid)}[/bold] (status: {cur_status})")

        if _apply_one(sid, data, yaml_data):
            applied += 1
        else:
            skipped += 1

    if applied > 0 and not dry_run:
        save_raw(yaml_data)
        console.print(f"\n[green]Applied {applied} curations to series.yaml[/green]")
    elif applied > 0:
        console.print(f"\n[dim]Dry run: {applied} would be applied[/dim]")
    else:
        console.print(f"\n[dim]Nothing to apply ({skipped} skipped)[/dim]")
