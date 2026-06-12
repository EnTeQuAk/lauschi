"""Tests for providers/_validate.py.

Provider+id format mismatches were causing real curate failures —
the small-flow agent confused providers and called Apple Music with
Spotify-format ids, then 404'd. The validator at the tool boundary
catches that before the API call. Pinning the format rules so a
future refactor can't loosen them.
"""

from __future__ import annotations

import pytest

from lauschi_catalog.providers._validate import (
    explain_invalid,
    is_valid_id,
)


# ── Spotify ───────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "aid",
    [
        "39ePAp05xC1loWbb7bF46b",  # 22 chars, alnum
        "0nNcNNBedN3GKqhlUsAObU",
        "1l6d0RIxTL3JytlLGvWzYe",
    ],
)
def test_valid_spotify_ids(aid):
    assert is_valid_id("spotify", aid) is True


@pytest.mark.parametrize(
    "aid",
    [
        "1X8MD9Zf1qQhOnJWcP4aD",  # 21 chars (Tom Turbo hallucination)
        "39ePAp05xC1loWbb7bF46bX",  # 23 chars
        "39ePAp05-C1loWbb7bF46b",  # contains '-'
        "39ePAp05 C1loWbb7bF46b",  # contains space
        "",  # empty
        "403963841",  # all-digit (Apple Music format)
    ],
)
def test_invalid_spotify_ids(aid):
    assert is_valid_id("spotify", aid) is False


# ── Apple Music ───────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "aid",
    [
        "403963841",
        "1443995096",
        "253463055",  # 9-digit older form
        "12345678",  # 8-digit
    ],
)
def test_valid_apple_music_ids(aid):
    assert is_valid_id("apple_music", aid) is True


@pytest.mark.parametrize(
    "aid",
    [
        "5E8nho2JtN5wXmR8Y7JBxp",  # Spotify-format id used with apple_music
        "59bf2D81aHzl0ot28xzQbk",  # eule_findet_den_beat case
        "0a7ReNgiORz9sEajzbbmqw",  # spirit_hoerspiel case
        "Cars Hörspiel",  # literal title (cars_hoerspiel case)
        "",
        "abc123",  # mix of letters/digits
    ],
)
def test_invalid_apple_music_ids(aid):
    assert is_valid_id("apple_music", aid) is False


# ── unknown providers ─────────────────────────────────────────────────────


def test_unknown_provider_passes_through():
    """Conservative: a future provider whose format we don't know
    yet shouldn't be blocked. Only refuse what we explicitly know
    is wrong."""
    assert is_valid_id("future_provider", "anything-goes") is True


# ── error messages ────────────────────────────────────────────────────────


def test_explain_spotify_mismatch_suggests_apple_music():
    """When a Spotify call gets an Apple-format id, the error
    should point the agent at apple_music — that's the most likely
    cause of the mistake."""
    msg = explain_invalid("spotify", "403963841")
    assert "spotify" in msg.lower()
    assert "apple_music" in msg


def test_explain_apple_music_mismatch_suggests_spotify():
    msg = explain_invalid("apple_music", "5E8nho2JtN5wXmR8Y7JBxp")
    assert "apple music" in msg.lower() or "apple_music" in msg.lower()
    assert "spotify" in msg


def test_explain_returns_short_message():
    """Errors go back to the agent as tool responses; bounded length
    keeps the reasoning trace readable."""
    msg = explain_invalid("spotify", "x" * 200)
    assert len(msg) < 400


# ── non-string inputs ─────────────────────────────────────────────────────


@pytest.mark.parametrize("aid", [None, 123, [], {}])
def test_non_string_input_invalid(aid):
    assert is_valid_id("spotify", aid) is False
    assert is_valid_id("apple_music", aid) is False
