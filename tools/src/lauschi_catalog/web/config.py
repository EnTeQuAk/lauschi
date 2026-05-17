"""Configuration and path resolution.

Paths point into the main lauschi repo so the web UI reads and writes
exactly the same files as the CLI tools.
"""

from __future__ import annotations

import os
from pathlib import Path

# Resolve the lauschi repo root.  The web package lives at
#   repo-root/tools/src/lauschi_catalog/web/
# so we walk up five levels to reach the repo root.
REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent.parent

SERIES_YAML = REPO_ROOT / "assets" / "catalog" / "series.yaml"
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

# SQLite database for job state (kept inside catalog-web, not the repo root).
DEFAULT_DB_PATH = Path(__file__).resolve().parent.parent.parent / "jobs.db"
DB_PATH = Path(os.environ.get("CATALOG_WEB_DB", str(DEFAULT_DB_PATH)))

# File lock for series.yaml (shared with CLI subprocesses).
SERIES_LOCK = REPO_ROOT / "assets" / "catalog" / ".series.yaml.lock"

# Feature flags
ENABLE_AI = os.environ.get("ENABLE_AI", "true").lower() in ("1", "true", "yes")
DEFAULT_MODEL = os.environ.get("CATALOG_MODEL", "kimi-k2.5")
VERIFY_MODEL = os.environ.get("VERIFY_MODEL", "minimax-m2.5")
