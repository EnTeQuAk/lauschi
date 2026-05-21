"""SQLite-backed catalog reads. YAML remains persistence layer.

On startup `sync_catalog_to_db()` loads series.yaml into SQLite.
All reads go through SQLite; writes update both SQLite and YAML.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime

from filelock import FileLock

from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.paths import series_lock_path, series_yaml_path
from lauschi_catalog.web.config import DB_PATH

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

SERIES_SCHEMA = """
CREATE TABLE IF NOT EXISTS series (
    id              TEXT PRIMARY KEY,
    title           TEXT NOT NULL,
    aliases_json    TEXT NOT NULL DEFAULT '[]',
    episode_pattern TEXT,
    content_type    TEXT,
    providers_json  TEXT NOT NULL DEFAULT '{}',
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_series_title ON series(title);
"""


def _conn() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def init_catalog_db() -> None:
    with _conn() as conn:
        conn.executescript(SERIES_SCHEMA)
        conn.commit()


def _now() -> str:
    return datetime.now(UTC).isoformat()


# ---------------------------------------------------------------------------
# Sync (YAML -> SQLite)
# ---------------------------------------------------------------------------


def sync_catalog_to_db() -> int:
    """Load series.yaml and upsert into SQLite. Deletes orphan rows. Returns count."""
    with FileLock(str(series_lock_path())):
        entries = load_catalog(series_yaml_path())
    ids = {e.id for e in entries}
    with _conn() as conn:
        for e in entries:
            conn.execute(
                """
                INSERT INTO series (id, title, aliases_json, episode_pattern,
                                    content_type, providers_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    aliases_json = excluded.aliases_json,
                    episode_pattern = excluded.episode_pattern,
                    content_type = excluded.content_type,
                    providers_json = excluded.providers_json,
                    updated_at = excluded.updated_at
                """,
                (
                    e.id,
                    e.title,
                    json.dumps(e.aliases),
                    _serialize_episode_pattern(e.episode_pattern),
                    e.content_type,
                    json.dumps(_providers_to_dict(e.providers)),
                    _now(),
                    _now(),
                ),
            )
        # Delete series no longer in YAML
        if ids:
            conn.execute(
                "DELETE FROM series WHERE id NOT IN ({})".format(
                    ",".join("?" * len(ids))
                ),
                list(ids),
            )
        conn.commit()
    return len(entries)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _serialize_episode_pattern(value: str | list[str] | None) -> str | None:
    """Store episode pattern(s) in SQLite: list -> JSON text, string -> as-is."""
    if value is None:
        return None
    if isinstance(value, list):
        return json.dumps(value)
    return value


def _deserialize_episode_pattern(value: str | None) -> str | list[str] | None:
    """Read episode pattern from SQLite: try JSON first, fall back to plain string."""
    if value is None:
        return None
    try:
        parsed = json.loads(value)
        if isinstance(parsed, list):
            return parsed
    except (json.JSONDecodeError, TypeError):
        pass
    return value


def _providers_to_dict(
    providers: dict[str, ProviderConfig],
) -> dict[str, dict[str, object]]:
    return {
        name: {
            "artist_ids": cfg.artist_ids,
            "episode_pattern": cfg.episode_pattern,
            "has_albums": cfg.has_albums,
        }
        for name, cfg in providers.items()
    }


def _row_to_entry(row: sqlite3.Row) -> CatalogEntry:
    providers_raw = json.loads(row["providers_json"])
    providers: dict[str, ProviderConfig] = {}
    for name, cfg in providers_raw.items():
        providers[name] = ProviderConfig(
            artist_ids=cfg.get("artist_ids", []),
            episode_pattern=cfg.get("episode_pattern"),
            has_albums=cfg.get("has_albums", False),
        )
    ep_pattern = _deserialize_episode_pattern(row["episode_pattern"])
    return CatalogEntry(
        id=row["id"],
        title=row["title"],
        aliases=json.loads(row["aliases_json"]),
        episode_pattern=ep_pattern,
        content_type=row["content_type"],
        providers=providers,
    )


# ---------------------------------------------------------------------------
# Reads
# ---------------------------------------------------------------------------


def get_all_series() -> list[CatalogEntry]:
    with _conn() as conn:
        rows = conn.execute(
            "SELECT * FROM series ORDER BY title COLLATE NOCASE"
        ).fetchall()
    return [_row_to_entry(r) for r in rows]


def get_series_by_id(series_id: str) -> CatalogEntry | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM series WHERE id = ?", (series_id,)).fetchone()
    return _row_to_entry(row) if row else None


def series_exists(series_id: str) -> bool:
    with _conn() as conn:
        row = conn.execute("SELECT 1 FROM series WHERE id = ?", (series_id,)).fetchone()
    return row is not None


# ---------------------------------------------------------------------------
# Writes (SQLite + YAML)
# ---------------------------------------------------------------------------


def insert_series(entry: CatalogEntry) -> None:
    """Insert into SQLite. Caller must write YAML separately."""
    with _conn() as conn:
        conn.execute(
            """
            INSERT INTO series (id, title, aliases_json, episode_pattern,
                                content_type, providers_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                entry.id,
                entry.title,
                json.dumps(entry.aliases),
                _serialize_episode_pattern(entry.episode_pattern),
                entry.content_type,
                json.dumps(_providers_to_dict(entry.providers)),
                _now(),
                _now(),
            ),
        )
        conn.commit()


def delete_series(series_id: str) -> None:
    """Delete from SQLite. Caller must write YAML separately."""
    with _conn() as conn:
        conn.execute("DELETE FROM series WHERE id = ?", (series_id,))
        conn.commit()
