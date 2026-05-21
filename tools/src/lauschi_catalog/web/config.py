"""Web-specific configuration."""

from __future__ import annotations

import os
from pathlib import Path

# SQLite database for job state (kept inside catalog-web, not the repo root).
DEFAULT_DB_PATH = Path(__file__).resolve().parent.parent.parent / "jobs.db"
DB_PATH = Path(os.environ.get("CATALOG_WEB_DB", str(DEFAULT_DB_PATH)))

# Feature flags
ENABLE_AI = os.environ.get("ENABLE_AI", "true").lower() in ("1", "true", "yes")
DEFAULT_MODEL = os.environ.get("CATALOG_MODEL", "kimi-k2.5")
VERIFY_MODEL = os.environ.get("VERIFY_MODEL", "minimax-m2.5")
