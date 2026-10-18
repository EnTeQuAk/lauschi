"""Quality check of the catalog against the reference index, one entry at a time.

The deterministic match (``reference_map.match_entry``) settles most of
an entry. What it leaves open on either side goes to a model, in a run of
its own for each entry, with that entry's index lines and nothing else of
the catalog: which open index episode the entry ships under other words,
which it should ship, which it rightly leaves out, and which shipped album
looks out of place. The result is a report for a person to act on; the
catalog does not change.
"""

import json
from collections import Counter
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Literal

from pydantic import BaseModel
from pydantic_ai import Agent, ModelRetry, RunContext, ToolOutput
from pydantic_ai.models import Model
from pydantic_ai.usage import RunUsage

from lauschi_catalog._opencode import build_model, get_model_settings, model_api_key
from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.partition import family_of
from lauschi_catalog.catalog.paths import curation_path
from lauschi_catalog.catalog.reference_map import (
    EntryMapping,
    EntryMatch,
    IndexEpisode,
    ShippedAlbum,
    barcode_key,
    brand_words,
    fold_word,
    load_overrides,
    map_catalog,
    match_entry,
    same_story,
    shipped_titles,
    story_words,
)
from lauschi_catalog.fanout import run_bounded
from lauschi_catalog.providers import CatalogProvider
from lauschi_catalog.providers.apple_music import AppleMusicProvider
from lauschi_catalog.providers.spotify import SpotifyProvider
from lauschi_catalog.reference import ReferenceIndex
from lauschi_catalog.retry import describe_failure
from lauschi_catalog.run import (
    END_STRATEGY,
    run_agent,
    run_with_attempts,
    usage_summary,
)

FindingKind = Literal[
    "same_story", "should_ship", "rightly_absent", "out_of_place", "unlisted"
]

_NEEDS: dict[str, tuple[bool, bool]] = {
    # kind: (needs an index ref, needs an album ref)
    "same_story": (True, True),
    "should_ship": (True, False),
    "rightly_absent": (True, False),
    "out_of_place": (False, True),
    "unlisted": (False, True),
}

#: left-out albums shown to the model, the ones nearest an open index episode
_MAX_EXCLUDED = 40

INSTRUCTIONS = """\
You check one entry of a children's audio catalog against a public
reference index: a publisher-fed list of Hörspiel brands, their lines and
the episodes in each line. Parents use the catalog to find a series'
episodes, so what matters is main content the entry is missing and albums
that do not belong in it.

A script has already paired what it could. You get what is left on both
sides: index episodes no shipped album matched (I1, I2, ...) and shipped
albums no index episode matched (A1, A2, ...). Account for every one of
them with exactly one finding:

- same_story: an index episode and a shipped album tell the same story in
  other words. Give both refs.
- should_ship: the index episode belongs to this entry's lines and the
  entry does not ship it. Give the index ref.
- rightly_absent: the entry is right not to ship it, for example a box of
  episodes it ships one by one, another format of a story it ships, or an
  album it leaves out for a reason the list of left-out albums names.
  Give the index ref.
- out_of_place: the shipped album does not belong in these lines: another
  brand, another line, or no release for children. An album the store
  credits to the entry's own artist is theirs, whether the index lists it
  or not. Two albums of one
  story are a duplicate only on the same store, since the stores title
  their releases differently. Give the album ref.
- unlisted: the shipped album fits the entry and the index just does not
  list it. The index lists only what its owner licenses and lags behind
  the stores, so this is common. Give the album ref.

An index line can hold another kind of content than the entry (songs in
a Hörspiel entry, readings in a music entry). What such a line holds is
rightly absent.

Each finding gives its reason in one plain English sentence. Judge only
by the index lines and the lists you are given. Never invent a title or
an episode number.
"""


class QaFinding(BaseModel):
    kind: FindingKind
    index_ref: str | None = None
    album_ref: str | None = None
    reason: str


class QaAnswer(BaseModel):
    findings: list[QaFinding]


@dataclass(frozen=True)
class QaPrompt:
    """What one entry's run is told, and what its refs stand for."""

    text: str
    index_refs: dict[str, IndexEpisode]
    album_refs: dict[str, ShippedAlbum]
    match: EntryMatch
    elsewhere: list[tuple[IndexEpisode, str]]
    #: open albums a person placed with catalog-edit, not put to the model again
    by_hand: list[ShippedAlbum]


@dataclass(frozen=True)
class Finding:
    kind: FindingKind
    reason: str
    index_title: str | None = None
    index_line: str | None = None
    index_number: int | None = None
    album_title: str | None = None
    album_number: int | None = None


@dataclass
class EntryQa:
    entry_id: str
    title: str
    mapping: EntryMapping
    match: EntryMatch
    #: open index episodes another member of the family ships, with its id
    elsewhere: list[tuple[IndexEpisode, str]]
    by_hand: list[ShippedAlbum] = field(default_factory=list)
    findings: list[Finding] = field(default_factory=list)
    usage: dict[str, int] = field(default_factory=dict)
    error: str | None = None

    def to_json(self) -> dict:
        m = self.match

        def ep(e: IndexEpisode) -> dict:
            return {"line": e.line, "number": e.number, "title": e.title}

        def album(a: ShippedAlbum) -> dict:
            return {
                "number": a.number,
                "title": a.title,
                "providers": list(a.providers),
            }

        return {
            "entry": self.entry_id,
            "title": self.title,
            "how": self.mapping.how,
            "index_series": self.mapping.series.name if self.mapping.series else None,
            "index_series_id": self.mapping.series.id if self.mapping.series else None,
            "lines": [line.name for line in self.mapping.lines],
            "index_episodes": sum(len(line.episodes) for line in self.mapping.lines),
            "matched": m.matched,
            "bundled": m.bundled,
            "in_tracks": m.in_tracks,
            "number_differs": [
                {"index": ep(p.index), "ours": album(p.ours)} for p in m.number_differs
            ],
            "title_differs": [
                {"index": ep(p.index), "ours": album(p.ours)} for p in m.title_differs
            ],
            "unnumbered": [
                {"index": ep(p.index), "ours": album(p.ours)} for p in m.unnumbered
            ],
            "newer": [album(a) for a in m.newer],
            "elsewhere": [
                {"index": ep(e), "entry": sibling} for e, sibling in self.elsewhere
            ],
            "by_hand": [album(a) for a in self.by_hand],
            "findings": [f.__dict__ for f in self.findings],
            "usage": self.usage,
            "error": self.error,
        }


def _near(title: str, open_titles: list[str], drop: frozenset[str]) -> bool:
    words = story_words(title, drop)
    for other in open_titles:
        if same_story(title, other, drop):
            return True
        theirs = story_words(other, drop)
        if (
            words
            and theirs
            and len(words & theirs) / min(len(words), len(theirs)) >= 0.5
        ):
            return True
    return False


def _shipped_by(
    episode: IndexEpisode, entries: Sequence[CatalogEntry], drop: frozenset[str]
) -> str | None:
    """The first of ``entries`` that ships the episode's release or story."""
    words = {fold_word(w) for w in story_words(episode.title, drop)}
    for other in entries:
        if episode.barcode and any(
            barcode_key(album.get("barcode") or "") == episode.barcode
            for cfg in other.providers.values()
            for album in cfg.albums
        ):
            return other.id
        for title in shipped_titles(other):
            theirs = {fold_word(w) for w in story_words(title, drop)}
            # the word check spares most titles the slower comparison
            if words and not words & theirs:
                continue
            if same_story(episode.title, title, drop):
                return other.id
    return None


def qa_prompt(
    entry: CatalogEntry,
    mapping: EntryMapping,
    family: list[CatalogEntry],
    albums: list[dict],
    *,
    today: date,
    tracks: Callable[[], list[str]] | None = None,
    credits: Callable[[ShippedAlbum], str | None] | None = None,
    rest: Sequence[CatalogEntry] = (),
    barcodes: Mapping[int, str] | None = None,
) -> QaPrompt:
    """Match the entry deterministically and phrase what stays open.

    ``family`` holds the entry's other family members and ``rest`` the
    catalog's other entries: an open index episode one of them ships is
    theirs and goes to nobody's model run. ``albums`` are the rows of the
    entry's curation: the albums it leaves out, and those a person placed
    by hand. ``credits`` names who the store credits for an open album.
    ``barcodes`` holds the index series' barcodes by product id.
    """
    assert mapping.series is not None
    drop = brand_words(mapping.series.name, entry.title, *(m.title for m in family))
    match = match_entry(
        entry,
        mapping.lines,
        today=today,
        drop=drop,
        tracks=tracks,
        barcodes=barcodes,
    )

    elsewhere: list[tuple[IndexEpisode, str]] = []
    open_index: list[IndexEpisode] = []
    for episode in match.open_index:
        owner = _shipped_by(episode, [*family, *rest], drop)
        if owner is not None:
            elsewhere.append((episode, owner))
        else:
            open_index.append(episode)

    hand = {
        (a.get("provider"), a.get("album_id"))
        for a in albums
        if a.get("include") and a.get("decided_by") == "operator"
    }
    by_hand = [a for a in match.open_ours if any(key in hand for key in a.ids)]
    open_ours = [a for a in match.open_ours if a not in by_hand]
    excluded = [a for a in albums if not a.get("include")]
    #: the left-out album of an open index episode's release, by its barcode
    left_out = {barcode_key(x["barcode"]): x for x in excluded if x.get("barcode")}

    index_refs = {f"I{n}": e for n, e in enumerate(open_index, start=1)}
    album_refs = {f"A{n}": a for n, a in enumerate(open_ours, start=1)}
    open_titles = [e.title for e in open_index]
    near = [
        x
        for x in excluded
        if barcode_key(x.get("barcode") or "") in {e.barcode for e in open_index}
        or _near(x.get("title") or "", open_titles, drop)
    ]

    mine = {line.name for line in mapping.lines}
    other_lines = [line.name for line in mapping.series.lines if line.name not in mine]
    out = [
        f"Entry: {entry.title} ({entry.content_type or 'hoerspiel'})",
        f"Index series: {mapping.series.name}",
        f"This entry's index lines: {', '.join(sorted(mine))}",
    ]
    if other_lines:
        out.append(f"Other lines of the index series: {', '.join(other_lines)}")
    if family:
        out.append(
            "Other entries of the family: "
            + ", ".join(f"{m.title} ({m.id})" for m in family)
        )
    out.append(
        f"Already paired: {match.matched} episodes, {match.bundled} bundled in an album, "
        f"{match.in_tracks} named by track titles."
    )
    out.append("")
    out.append("Index episodes no shipped album matched:")
    for ref, e in index_refs.items():
        where = f"{e.line} {e.number}" if e.number is not None else e.line
        x = left_out.get(e.barcode) if e.barcode else None
        release = (
            f" (its release is on the store as {x.get('title')!r}, which this "
            f"entry leaves out: {x.get('exclude_reason') or 'unspecified'})"
            if x is not None
            else ""
        )
        out.append(f"{ref} [{where}] {e.title}{release}")
    if not index_refs:
        out.append("(none)")
    out.append("")
    out.append("Shipped albums no index episode matched:")
    for ref, a in album_refs.items():
        number = f"[Folge {a.number}] " if a.number is not None else ""
        credit = credits(a) if credits is not None else None
        stores = ", ".join(a.providers) + (f"; credited to {credit}" if credit else "")
        out.append(f"{ref} {number}{a.title} ({stores})")
    if not album_refs:
        out.append("(none)")
    if near:
        out.append("")
        out.append(
            "Albums this entry leaves out, near an open index episode (title: reason):"
        )
        out += [
            f"- {x.get('title')}: {x.get('exclude_reason') or 'unspecified'}"
            for x in near[:_MAX_EXCLUDED]
        ]
    return QaPrompt("\n".join(out), index_refs, album_refs, match, elsewhere, by_hand)


def build_qa_agent(model: Model, *, model_name: str) -> Agent[QaPrompt, QaAnswer]:
    agent: Agent[QaPrompt, QaAnswer] = Agent(
        model,
        name="reference_qa",
        deps_type=QaPrompt,
        output_type=ToolOutput(
            QaAnswer,
            name="submit_qa",
            description="Submit one finding for every open index episode and album.",
        ),
        instructions=INSTRUCTIONS,
        model_settings=get_model_settings("audit", model_name),
        retries={"output": 2},
        end_strategy=END_STRATEGY,
    )

    @agent.output_validator
    def every_open_item_once(ctx: RunContext[QaPrompt], answer: QaAnswer) -> QaAnswer:
        seen: set[str] = set()
        for f in answer.findings:
            needs_index, needs_album = _NEEDS[f.kind]
            for ref, needed, known in (
                (f.index_ref, needs_index, ctx.deps.index_refs),
                (f.album_ref, needs_album, ctx.deps.album_refs),
            ):
                if needed and ref not in known:
                    raise ModelRetry(
                        f"A {f.kind} finding needs a known ref, got {ref!r}."
                    )
                if ref is not None and needed:
                    seen.add(ref)
        left = [
            r for r in (*ctx.deps.index_refs, *ctx.deps.album_refs) if r not in seen
        ]
        if left:
            raise ModelRetry(
                f"Give a finding for each of these as well: {', '.join(left)}."
            )
        return answer

    return agent


def _resolve(prompt: QaPrompt, finding: QaFinding) -> Finding:
    needs_index, needs_album = _NEEDS[finding.kind]
    ep = prompt.index_refs.get(finding.index_ref or "") if needs_index else None
    album = prompt.album_refs.get(finding.album_ref or "") if needs_album else None
    return Finding(
        kind=finding.kind,
        reason=finding.reason,
        index_title=ep.title if ep else None,
        index_line=ep.line if ep else None,
        index_number=ep.number if ep else None,
        album_title=album.title if album else None,
        album_number=album.number if album else None,
    )


async def qa_entry(
    entry: CatalogEntry,
    mapping: EntryMapping,
    family: list[CatalogEntry],
    albums: list[dict],
    *,
    agent: Agent[QaPrompt, QaAnswer],
    today: date,
    tracks: Callable[[], list[str]] | None = None,
    credits: Callable[[ShippedAlbum], str | None] | None = None,
    rest: Sequence[CatalogEntry] = (),
    barcodes: Mapping[int, str] | None = None,
) -> EntryQa:
    """Check one mapped entry. The model runs only when the match leaves
    something open."""
    prompt = qa_prompt(
        entry,
        mapping,
        family,
        albums,
        today=today,
        tracks=tracks,
        credits=credits,
        rest=rest,
        barcodes=barcodes,
    )
    result = EntryQa(
        entry.id, entry.title, mapping, prompt.match, prompt.elsewhere, prompt.by_hand
    )
    if not prompt.index_refs and not prompt.album_refs:
        return result
    tally = RunUsage()
    answer: QaAnswer = await run_agent(agent, prompt.text, prompt, tally=tally)
    result.findings = [_resolve(prompt, f) for f in answer.findings]
    result.usage = usage_summary(tally)
    return result


def write_report(results: list[EntryQa], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps([r.to_json() for r in results], ensure_ascii=False, indent=1) + "\n"
    )


#: GLM 5.3 Flash: cheap on the Ollama Cloud plan, and steady in the curator benchmark
DEFAULT_MODEL = "glm-5.3-flash"


def _curation_albums(entry_id: str) -> list[dict]:
    path = curation_path(entry_id)
    return json.loads(path.read_text()).get("albums", []) if path.exists() else []


def _credit_reader(
    providers: Sequence[CatalogProvider],
) -> Callable[[ShippedAlbum], str | None] | None:
    """Who the stores credit for an album, from the first store in
    ``providers`` that ships it and names an artist."""
    if not providers:
        return None

    def read(album: ShippedAlbum) -> str | None:
        for provider in providers:
            ids = [i for name, i in album.ids if name == provider.name]
            details = provider.album_details_many(ids[:1]) if ids else {}
            credit = next((d.artists for d in details.values() if d.artists), None)
            if credit:
                return credit
        return None

    return read


def _track_reader(
    entry: CatalogEntry, spotify: SpotifyProvider | None
) -> Callable[[], list[str]] | None:
    cfg = entry.providers.get("spotify")
    if spotify is None or cfg is None or not cfg.albums:
        return None
    ids = [a["id"] for a in cfg.albums]

    def read() -> list[str]:
        return [
            t.name
            for album in spotify.album_details_many(ids).values()
            for t in album.tracks
        ]

    return read


async def run_reference_qa(
    series_ids: list[str] | None,
    *,
    model_name: str = DEFAULT_MODEL,
    concurrency: int = 2,
    today: date | None = None,
    on_progress: Callable[[str], None] = lambda _: None,
) -> list[EntryQa]:
    """Check every entry the index maps (or the named ones), one model run
    per entry that has something open."""
    catalog = load_catalog()
    index = ReferenceIndex()
    mapping = map_catalog(catalog, index, load_overrides())
    wanted = set(series_ids) if series_ids else None
    targets = [
        e for e in catalog if mapping[e.id].lines and (wanted is None or e.id in wanted)
    ]
    if wanted is not None:
        for sid in sorted(wanted - {e.id for e in targets}):
            on_progress(
                f"  {sid}: not mapped to index lines ({mapping[sid].how if sid in mapping else 'unknown id'})"
            )
    agent = build_qa_agent(
        build_model(model_name, model_api_key()), model_name=model_name
    )
    try:
        spotify: SpotifyProvider | None = SpotifyProvider()
    except (
        Exception
    ) as exc:  # no Spotify credentials: no track names, Apple credits only
        on_progress(f"  No Spotify ({type(exc).__name__}: {exc})")
        spotify = None
    try:
        apple: AppleMusicProvider | None = AppleMusicProvider()
    except Exception as exc:  # no MusicKit key: Spotify credits only
        on_progress(f"  No Apple Music ({type(exc).__name__}: {exc})")
        apple = None
    credits = _credit_reader([p for p in (apple, spotify) if p is not None])
    day = today or date.today()

    async def one(entry: CatalogEntry) -> EntryQa:
        series = mapping[entry.id].series
        assert series is not None
        family = list(family_of(entry, catalog).siblings_of(entry.id))
        rest = [e for e in catalog if e.id != entry.id and e not in family]
        try:
            result = await run_with_attempts(
                lambda: qa_entry(
                    entry,
                    mapping[entry.id],
                    family,
                    _curation_albums(entry.id),
                    agent=agent,
                    today=day,
                    tracks=_track_reader(entry, spotify),
                    credits=credits,
                    rest=rest,
                    barcodes=index.barcodes(series.id),
                ),
                attempts=2,
                label=entry.id,
                on_progress=on_progress,
            )
        except Exception as exc:
            result = EntryQa(entry.id, entry.title, mapping[entry.id], EntryMatch(), [])
            result.error = describe_failure(exc)
        kinds = Counter(f.kind for f in result.findings)
        on_progress(
            f"  {entry.id}: {result.match.matched} matched, "
            + (
                ", ".join(f"{n} {k}" for k, n in sorted(kinds.items()))
                or "nothing open"
            )
            + (f", FAILED {result.error}" if result.error else "")
        )
        return result

    on_progress(
        f"Checking {len(targets)} entries against the reference index with {model_name}"
    )
    return await run_bounded(one, targets, concurrency=concurrency)
