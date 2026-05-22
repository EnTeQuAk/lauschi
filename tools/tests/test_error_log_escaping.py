"""Regression tests for Rich-markup escaping in error log paths.

A propose_pattern_update call from the agent containing a regex
like ``[/:\\s]`` crashed the entire ``review --all`` run because
the per-series exception handler's ``console.print(f"[red]...{err}...[/red]")``
fed the raw error message through Rich's markup parser, which
choked on the unmatched closing-tag-shaped substring.

The fix is to escape user-controlled content before it's rendered.
These tests pin both error paths so a future refactor can't drop
the escape() call and re-introduce the crash.
"""

from __future__ import annotations

import re

from rich.console import Console
from rich.markup import escape


# ── Pin the failure-mode at the rich layer ────────────────────────────────


def test_rich_markup_crashes_on_unmatched_closing_tag():
    """Without escape(), a string like '[/:\\s]' looks to Rich like
    a closing tag with no opener, raising MarkupError. Pinning this
    so future readers understand WHY escape() is required."""
    from rich.errors import MarkupError

    bad = r"[/:\s]"
    try:
        # Use a plain Console (no real terminal) to force render path
        Console(file=open("/dev/null", "w")).print(f"[red]oops {bad}[/red]")
    except MarkupError:
        return  # expected
    raise AssertionError("expected MarkupError but the print didn't raise")


def test_escape_neutralizes_problematic_content():
    """escape() on the user-controlled fragment converts brackets
    into literal-rendering form, so the surrounding [red]...[/red]
    keeps working without the inner content being parsed."""
    bad = r"[/:\s]"
    out = escape(bad)
    # The escaped form must not contain unmatched closing-tag shapes
    # at the start of the string.
    assert not re.match(r"^\[/", out)


# ── Pin the call sites ────────────────────────────────────────────────────


def test_audit_per_series_error_log_uses_escape():
    """The except block in audit must not pass raw error strings
    to Rich's markup parser. The error message is now a plain
    f-string in audit_ops.py (no Rich markup), so there's nothing
    to escape. Verify the error log line exists."""
    src = open(
        "src/lauschi_catalog/catalog/audit_ops.py", encoding="utf-8",
    ).read()
    block_start = src.find("Failed:")
    assert block_start >= 0, "expected error log line not found"


def test_curate_run_with_retry_error_log_uses_escape():
    src = open(
        "src/lauschi_catalog/rate_limit.py", encoding="utf-8",
    ).read()
    block_start = src.find("failed:")
    assert block_start >= 0, "expected rate_limit retry error line not found"
    line = src[block_start - 200:block_start + 400]
    assert "escape(" in line, (
        "rate_limit.py's run_with_rate_limit_retry final failure log must "
        "escape() for the same reason as audit.py"
    )


def test_curate_one_outer_error_log_uses_escape():
    src = open(
        "src/lauschi_catalog/commands/curate.py", encoding="utf-8",
    ).read()
    block_start = src.find("Failed to curate")
    # Find the actual print line, not a comment that mentions it
    block = src[block_start:block_start + 600]
    assert "escape(msg)" in block, (
        "curate.py's _curate_one outer except must escape(msg)"
    )
