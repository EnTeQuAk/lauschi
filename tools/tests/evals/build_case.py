"""Freeze an eval case from the catalog, the curation and the provider cache.

    cd tools/
    python -m tests.evals.build_case hexe_lilli --list
    python -m tests.evals.build_case hexe_lilli main_keeps_its_episodes \\
        --match "Folge [1-5]:" --albums spotify:4xY...

``--list`` prints the series' artist pages with the current decision per
album, to pick from. The second form writes fixtures/<name>.json with the
series facts, the prior decisions and the picked albums in full.

What it cannot write is the expectation. Every album gets an ``expect``
with a ``todo`` instead: the lines of the line index that list the title,
and what the curation says today. The loader refuses the file until each
``todo`` is replaced by a decision and its source, by hand. The index is
the gold standard for which line a title belongs to. Where it does not
list a title, the expectation is a hand decision and says so.

Run it again with the same name to refresh the frozen data: the question
and the expectations already written are kept.
"""

import argparse
import json
import re
import unicodedata
from pathlib import Path
from typing import Any

from lauschi_catalog.catalog.curate_ops import _root_title
from lauschi_catalog.catalog.loader import load_catalog, sibling_series
from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.paths import curation_path
from lauschi_catalog.catalog.prompt import album_to_dict
from lauschi_catalog.providers.apple_music import AppleMusicProvider
from lauschi_catalog.providers.base import CatalogProvider
from lauschi_catalog.providers.spotify import SpotifyProvider
from lauschi_catalog.reference import ReferenceIndex, ReferenceSeries

from .case_files import FIXTURES

_STOP = frozenset(
    "der die das und ein eine einer eines den dem des im in am an auf zu zum zur "
    "von vom mit für folge teil hörspiel das cd episode the and of a".split()
)


def _words(text: str, drop: frozenset[str] = frozenset()) -> frozenset[str]:
    """The words of a title that tell stories apart, spelling folded."""
    text = unicodedata.normalize("NFC", text).lower()
    text = re.sub(r"\(.*?\)|\[.*?\]", " ", text)
    folded: set[str] = set()
    for word in re.findall(r"[a-zäöüß]+", text):
        if word in _STOP or len(word) < 2:
            continue
        for plain, umlaut in (("ae", "ä"), ("oe", "ö"), ("ue", "ü"), ("ss", "ß")):
            word = word.replace(umlaut, plain)
        folded.add(re.sub(r"(.)\1+", r"\1", word))
    return frozenset(folded - drop)


def index_evidence(title: str, series: ReferenceSeries) -> list[str]:
    """The index episodes that tell the story of a store title, as
    "<line> <number>: <title>". A proposal for a human, not a verdict:
    three quarters of the shorter title's words have to be shared."""
    brand = _words(series.name)
    wanted = _words(title, brand)
    hits: list[str] = []
    for line in series.lines:
        for episode in line.episodes:
            words = _words(episode.title, brand)
            if not wanted or not words:
                continue
            if len(wanted & words) / min(len(wanted), len(words)) >= 0.75:
                number = f" {episode.number}" if episode.number else ""
                hits.append(f"{line.name}{number}: {episode.title}")
    return hits


def series_context(
    entry: CatalogEntry,
    catalog: list[CatalogEntry],
    page: list[dict[str, Any]],
    main_series_title: str | None,
) -> dict[str, Any]:
    """The catalog facts a run reads about the series."""
    years = [
        int(str(row["release_date"])[:4])
        for row in page
        if str(row.get("release_date") or "")[:4].isdigit()
    ]
    context: dict[str, Any] = {
        "id": entry.id,
        "title": entry.title,
        "content_type": entry.content_type or "hoerspiel",
        "episode_pattern": entry.episode_pattern,
        "aliases": list(entry.aliases),
        "discography_span_years": max(years) - min(years) if len(years) >= 2 else None,
        "sibling_titles": sibling_series(entry.id, entry.all_artist_ids(), catalog),
        "ships": [
            [provider, album["id"]]
            for provider, config in sorted(entry.providers.items())
            for album in config.albums
        ],
    }
    if entry.split_from:
        context["split_from"] = entry.split_from
        context["main_series_title"] = main_series_title
    return context


def decided_rows(
    entry: CatalogEntry,
    curation_albums: list[dict[str, Any]],
    asked: set[tuple[str, str]],
) -> list[dict[str, Any]]:
    """What the run has decided before the batch: the curation's rows
    that are not asked. A sub-series brings only what it includes, since
    it inherits no decision from the main series."""
    rows: list[dict[str, Any]] = []
    for album in curation_albums:
        if (album["provider"], album["album_id"]) in asked:
            continue
        if entry.split_from and not album["include"]:
            continue
        row = {
            "album_id": album["album_id"],
            "provider": album["provider"],
            "title": album["title"],
            "include": album["include"],
            "episode_num": album.get("episode_num"),
            "release_date": album.get("release_date"),
        }
        if not album["include"]:
            row["exclude_reason"] = album.get("exclude_reason")
            if album.get("notes"):
                row["notes"] = album["notes"]
        if album.get("decided_by") == "operator":
            row["decided_by"] = "operator"
        rows.append(row)
    return rows


def _page(
    entry: CatalogEntry, providers: list[CatalogProvider]
) -> list[dict[str, Any]]:
    rows: dict[tuple[str, str], dict[str, Any]] = {}
    for provider in providers:
        for artist_id in entry.all_artist_ids().get(provider.name) or []:
            for album in provider.artist_albums(artist_id):
                rows[(provider.name, album.id)] = {
                    "provider": provider.name,
                    "id": album.id,
                    "name": album.name,
                    "release_date": album.release_date,
                }
    return sorted(
        rows.values(), key=lambda r: (r["provider"], str(r["release_date"]), r["name"])
    )


def dump(case: dict[str, Any]) -> str:
    """The case as JSON a diff can be read in: indented, with a track, a
    decided row and a shipped album each on one line."""
    text = json.dumps(case, ensure_ascii=False, indent=1)
    flat = re.compile(r"[\[{]\n\s+([^\[\]{}]*?)\n\s+[\]}]")

    def one_line(match: re.Match[str]) -> str:
        opening, closing = match.group(0)[0], match.group(0)[-1]
        return opening + re.sub(r"\n\s+", " ", match.group(1)) + closing

    return flat.sub(one_line, text) + "\n"


def _today(album: dict[str, Any] | None) -> str:
    if album is None:
        return "not in the curation"
    if album["include"]:
        number = album.get("episode_num")
        return "included" + (f" as {number}" if number is not None else ", no number")
    return f"excluded, {album.get('exclude_reason')}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("series_id")
    parser.add_argument("name", nargs="?", help="case name, the file's stem")
    parser.add_argument("--list", action="store_true", help="print the page and stop")
    parser.add_argument("--match", help="regex over the store title")
    parser.add_argument("--albums", nargs="*", default=[], metavar="PROVIDER:ID")
    parser.add_argument("--question", default="TODO: what does this case find out?")
    parser.add_argument("--index-name", help="the brand's name in the line index")
    args = parser.parse_args()

    catalog = load_catalog()
    entry = next(e for e in catalog if e.id == args.series_id)
    providers: list[CatalogProvider] = [SpotifyProvider(), AppleMusicProvider()]
    page = _page(entry, providers)
    path = curation_path(entry.id)
    curation = json.loads(path.read_text())["albums"] if path.exists() else []
    today = {(a["provider"], a["album_id"]): a for a in curation}

    if args.list:
        for row in page:
            key = (row["provider"], row["id"])
            print(
                f"{key[0]}:{key[1]}  {str(row['release_date'])[:10]:10}  "
                f"{row['name']}  [{_today(today.get(key))}]"
            )
        return
    if not args.name:
        parser.error("a case name is needed to write a file")

    picked = {tuple(ref.split(":", 1)) for ref in args.albums}
    asked = [
        row
        for row in page
        if (row["provider"], row["id"]) in picked
        or (args.match and re.search(args.match, row["name"], re.IGNORECASE))
    ]
    unknown = picked - {(row["provider"], row["id"]) for row in page}
    if unknown:
        parser.error(f"not on the page: {sorted(':'.join(ref) for ref in unknown)}")
    if not asked:
        parser.error("no album picked, see --list")

    out: Path = FIXTURES / f"{args.name}.json"
    before = json.loads(out.read_text()) if out.exists() else {}
    kept = {(a["provider"], a["id"]): a["expect"] for a in before.get("albums", [])}

    index = ReferenceIndex()
    brand = args.index_name or _root_title(entry) or entry.title
    reference = index.lines_for(brand) if index.configured else None

    albums: list[dict[str, Any]] = []
    for provider in providers:
        ids = [row["id"] for row in asked if row["provider"] == provider.name]
        details = provider.album_details_many(ids) if ids else {}
        for album_id in ids:
            album = album_to_dict(details[album_id])
            album["expect"] = kept.get((provider.name, album_id)) or {
                "todo": {
                    "index": index_evidence(album["title"], reference)
                    if reference
                    else "no index entry",
                    "curation": _today(today.get((provider.name, album_id))),
                }
            }
            albums.append(album)

    case = {
        "question": before.get("question") or args.question,
        "series": series_context(entry, catalog, page, _root_title(entry)),
        "decided": decided_rows(
            entry, curation, {(a["provider"], a["id"]) for a in albums}
        ),
        "albums": albums,
    }
    out.parent.mkdir(exist_ok=True)
    out.write_text(dump(case))
    print(
        f"{out}: {len(albums)} album(s) to decide, {len(case['decided'])} decided "
        f"before. Index: {reference.name if reference else 'none'}."
    )


if __name__ == "__main__":
    main()
