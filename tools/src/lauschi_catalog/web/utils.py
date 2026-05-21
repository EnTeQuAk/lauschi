"""Small utilities for the web UI.

Re-exports atomic I/O from the catalog library so existing web
imports keep working.
"""

from lauschi_catalog.catalog.io import (  # noqa: F401
    safe_write_json,
    safe_write_text,
    safe_write_yaml,
)
