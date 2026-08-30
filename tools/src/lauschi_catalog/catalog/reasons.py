"""One policy vocabulary for exclude reasons.

The exclude_reason field is an enum shared by the curate agent, the
lint checks, and the reconcile pass. Each reason is declared once as a
Reason record; the Literal type, the lint content set, the reconcile
auto-flip/flag sets, and the batch prompt table are all rendered from
this module, so they cannot drift apart.

Kinds:
- "content": the album is the wrong kind of thing for the series.
- "redundancy": the album is a duplicate or variant of another album.
- "structural": the album belongs to a different series or sub-series.
"""

from dataclasses import dataclass
from typing import Literal

ReasonKind = Literal["content", "redundancy", "structural"]


@dataclass(frozen=True)
class Reason:
    key: str
    kind: ReasonKind
    #: whether reconcile auto-flips a same-title exclusion conflict
    auto_flip: bool
    description: str


#: Reasons the curate agent may return. Order matters: it is the order
#: the batch prompt table prints them in.
CURATE_REASONS: tuple[Reason, ...] = (
    Reason(
        "compilation",
        "content",
        auto_flip=True,
        description="Box sets, multi-episode compilations, 'Folge 1-10' range releases",
    ),
    Reason(
        "kinderlieder_compilation",
        "content",
        auto_flip=True,
        description="Children's song compilations (e.g. 'Die schönsten...')",
    ),
    Reason(
        "multi_artist_compilation",
        "content",
        auto_flip=True,
        description="Multi-artist compilations (e.g. 'Kinderparty' releases)",
    ),
    Reason(
        "wrong_content_type",
        "content",
        auto_flip=True,
        description="Audiobook reading in a Hörspiel series, music in a non-music series",
    ),
    Reason(
        "music_single",
        "content",
        auto_flip=True,
        description="Single track under 5 min, not an episode",
    ),
    Reason(
        "format_variant",
        "redundancy",
        auto_flip=True,
        description="Karaoke, instrumental, sped-up, nightcore versions",
    ),
    Reason(
        "sub_series_bleed",
        "structural",
        auto_flip=False,
        description="Belongs to a sub-series with its own catalog entry",
    ),
    Reason(
        "sub_series",
        "structural",
        auto_flip=False,
        description="Sub-series content that does not belong in the parent",
    ),
    Reason(
        "duplicate",
        "redundancy",
        auto_flip=False,
        description="Same content, same provider (keep the most recent)",
    ),
    Reason(
        "not_kids_content",
        "content",
        auto_flip=True,
        description="Adult content in a children's series",
    ),
    Reason(
        "different_series",
        "structural",
        auto_flip=False,
        description="Belongs to a completely different series",
    ),
    Reason(
        "partial_release",
        "content",
        auto_flip=True,
        description="Incomplete or preview release",
    ),
    Reason(
        "unspecified",
        "content",
        auto_flip=False,
        description="Catch-all when no other category fits (prefer including instead)",
    ),
)

#: Reasons set outside the curate agent (audit, manual edits).
EXTERNAL_REASONS: tuple[Reason, ...] = (
    Reason(
        "audit_override",
        "structural",
        auto_flip=False,
        description="Set by the audit pass overriding the curate decision",
    ),
    Reason(
        "same_provider_duplicate",
        "redundancy",
        auto_flip=False,
        description="Duplicate within the same provider, found by deterministic lint",
    ),
    Reason(
        "incomplete_release",
        "content",
        auto_flip=False,
        description="Release is missing episodes the series already has",
    ),
    Reason(
        "wrong_artist",
        "structural",
        auto_flip=False,
        description="Different artist entirely (e.g. a cover band sharing the name)",
    ),
    Reason(
        "compilation_as_episode",
        "content",
        auto_flip=False,
        description="A compilation whose title mimics a numbered episode",
    ),
)

_ALL_REASONS: tuple[Reason, ...] = CURATE_REASONS + EXTERNAL_REASONS

_REASON_BY_KEY: dict[str, Reason] = {r.key: r for r in _ALL_REASONS}

ALL_REASON_KEYS: frozenset[str] = frozenset(_REASON_BY_KEY)


def get_reason(key: str) -> Reason:
    return _REASON_BY_KEY[key]


#: Reason keys the curate agent may return; renders the ExcludeReason
#: Literal that AlbumDecision validates against.
CURATE_REASON_KEYS: tuple[str, ...] = tuple(r.key for r in CURATE_REASONS)

#: Reasons the batch prompt table shows, in table order.
CURATE_REASON_TABLE: tuple[tuple[str, str], ...] = tuple(
    (r.key, r.description) for r in CURATE_REASONS
)

#: Reasons reconcile auto-flips when the same title is included on the
#: other provider. Includes `compilation` because genuine compilations
#: have distinct titles ("Folge 1-10", "Sammelbox") that never match a
#: regular episode on the other provider; a title match means the label
#: is a false positive.
AUTO_FLIP_REASON_KEYS: frozenset[str] = frozenset(
    r.key for r in _ALL_REASONS if r.auto_flip
)

#: Structural decisions that may be correct on both sides, so reconcile
#: flags them for human review instead of flipping. `wrong_artist` is
#: likewise structural, but reconcile has never flagged it; it is listed
#: here for completeness and kept out of the reconcile set.
FLAG_REASON_KEYS: frozenset[str] = frozenset(
    {"sub_series_bleed", "sub_series", "different_series", "audit_override"}
)

#: Reasons that make a same-title decision pair contradictory: the same
#: content cannot be classified one way for one member and the opposite
#: way for a sibling. Redundancy reasons (duplicate, format_variant)
#: describe a relationship to another album, not the content, and a
#: split on them is deliberate. Includes the structural sub-series and
#: different-series reasons because splits on them are what a
#: contradiction check looks for.
CONTRADICTION_REASON_KEYS: frozenset[str] = frozenset(
    {
        "music_single",
        # Legacy value written by older lint passes.
        "music_album",
        "compilation",
        "multi_artist_compilation",
        "kinderlieder_compilation",
        "compilation_as_episode",
        "wrong_content_type",
        "not_kids_content",
        # Legacy value written by older lint passes.
        "audiobook",
        "sub_series",
        "sub_series_bleed",
        "different_series",
    }
)


def is_content_reason(reason: str) -> bool:
    return reason in CONTRADICTION_REASON_KEYS
