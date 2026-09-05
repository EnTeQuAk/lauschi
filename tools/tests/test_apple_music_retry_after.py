"""Tests for providers._retry.parse_retry_after.

The previous int(Retry-After) in apple_music crashed on float
values and HTTP-date strings. Both forms are spec-allowed for
Retry-After and Apple has been observed to send floats. A crash
here would propagate up through _request into provider calls and
stop the whole pipeline. Spotify uses the same helper now too.
"""

from datetime import datetime, timedelta, timezone
from email.utils import format_datetime

import pytest

from lauschi_catalog.providers._retry import (
    _RETRY_AFTER_DEFAULT,
    _RETRY_AFTER_MAX,
)
from lauschi_catalog.providers._retry import (
    parse_retry_after as _parse_retry_after,
)

# ── delta-seconds form ────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        pytest.param("5", 5.0, id="integer seconds"),
        pytest.param(
            "1.5", 1.5, id="float seconds (Apple sends floats; int() once crashed)"
        ),
        pytest.param("0", 0.0, id="zero"),
        pytest.param("-3", 0.0, id="a bogus negative clamps to zero"),
        pytest.param(
            "3600", _RETRY_AFTER_MAX, id="a five-minute wait clamps to the cap"
        ),
    ],
)
def test_seconds_form_parses_and_clamps(raw, expected):
    assert _parse_retry_after(raw) == expected


# ── HTTP-date form ────────────────────────────────────────────────────────


def test_parses_http_date_in_future():
    future = datetime.now(timezone.utc) + timedelta(seconds=10)
    header = format_datetime(future, usegmt=True)
    parsed = _parse_retry_after(header)
    # Allow ±2s for clock drift between format/parse.
    assert 8 <= parsed <= 12


def test_clamps_http_date_far_future_to_max():
    future = datetime.now(timezone.utc) + timedelta(hours=2)
    header = format_datetime(future, usegmt=True)
    assert _parse_retry_after(header) == _RETRY_AFTER_MAX


def test_clamps_http_date_in_past_to_zero():
    """A past date means "retry now"; 0s is the right interpretation."""
    past = datetime.now(timezone.utc) - timedelta(seconds=30)
    header = format_datetime(past, usegmt=True)
    assert _parse_retry_after(header) == 0.0


# ── error / fallback ──────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "raw",
    [
        None,
        "",
        "   ",
        "not a number",
        "abc123",
        "tomorrow",
    ],
)
def test_returns_default_on_unparseable(raw):
    assert _parse_retry_after(raw) == _RETRY_AFTER_DEFAULT


def test_strips_surrounding_whitespace():
    assert _parse_retry_after("  3  ") == 3.0
