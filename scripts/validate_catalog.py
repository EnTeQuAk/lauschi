#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests>=2.31", "pyyaml>=6.0", "rich>=13.7"]
# ///
"""
Comprehensive validator for lauschi assets/catalog/series.yaml.

Validation layers:

  L1  SYNTAX      required fields, regex compiles, unique ids
  L2  SEARCH      keyword hit-rate against Spotify album search (top 100)
  L3  PATTERN     episode extraction rate within keyword-matched albums
  L4  DISCOVERY   probes common DACH naming patterns, suggests better patterns
  L5  ARTIST      full discography via artist ID — complete coverage, no 100-cap

L5 requires `spotify_artist_ids` in the YAML entry and is the most reliable
layer — it fetches every album by the series' artist(s), regardless of whether
the album title contains the series name.

Modes:
  default           L1-L4 for all series
  --artist-audit    also run L5 for series with spotify_artist_ids
  --discover        search Spotify for artist candidates (no IDs yet)
  --series X        filter to series whose title contains X

Caches:
  .cache/spotify_catalog/{id}.json          album search results
  .cache/spotify_artists/{artist_id}.json   artist full discography

Usage:
    uv run scripts/validate_catalog.py                        # L1-L4
    uv run scripts/validate_catalog.py --artist-audit         # + L5
    uv run scripts/validate_catalog.py --discover             # find artist IDs
    uv run scripts/validate_catalog.py --discover --series Fuchsbande
    uv run scripts/validate_catalog.py --no-cache             # fresh API calls
    uv run scripts/validate_catalog.py --json out.json
    uv run scripts/validate_catalog.py --ci                   # exit 1 on issues
"""

import argparse
import json
import os
import re
import sys
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import requests
import yaml
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich import box

console = Console()

REPO_ROOT = Path(__file__).parent.parent
CATALOG_PATH = REPO_ROOT / "assets" / "catalog" / "series.yaml"
CACHE_SEARCH  = REPO_ROOT / ".cache" / "spotify_catalog"
CACHE_ARTISTS = REPO_ROOT / ".cache" / "spotify_artists"

# ── Common DACH naming patterns for L4 discovery ─────────────────────────────

CANDIDATE_PATTERNS: list[tuple[str, str]] = [
    ("leading_NNN_slash",  r"^(\d{2,3})/"),
    ("leading_N_colon",    r"^(\d{1,2}):\s"),
    ("folge_N",            r"[Ff]olge\s+(\d+)"),
    ("band_N",             r"[Bb]and\s+(\d+)"),
    ("teil_N",             r"[Tt]eil\s+(\d+)"),
    ("episode_N",          r"[Ee]pisode\s+(\d+)"),
    ("fall_N",             r"[Ff]all\s+(\d+)"),
    ("klassiker_N",        r"[Kk]lassiker\s+(\d+)"),
    ("title_space_N_dot",  r"\s(\d+)\.\s"),
    ("trailing_paren_N",   r"\((?:\w+\s+)?(\d+)\)"),
    ("title_comma_N",      r",\s*(\d+)$"),
]

NOISE_RE = re.compile(r"^(19|20)\d{2}$")  # veto years


# ── Auth ─────────────────────────────────────────────────────────────────────

def load_dotenv(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            env[k.strip()] = v.strip()
    return env


def get_token(client_id: str, client_secret: str) -> str:
    r = requests.post(
        "https://accounts.spotify.com/api/token",
        data={"grant_type": "client_credentials"},
        auth=(client_id, client_secret),
        timeout=10,
    )
    r.raise_for_status()
    return r.json()["access_token"]


# ── Spotify helpers ───────────────────────────────────────────────────────────

def _get(token: str, url: str, params: dict) -> dict:
    """GET with automatic rate-limit retry."""
    headers = {"Authorization": f"Bearer {token}"}
    while True:
        r = requests.get(url, headers=headers, params=params, timeout=15)
        if r.status_code == 429:
            w = int(r.headers.get("Retry-After", 3))
            console.print(f"[yellow]rate-limited – waiting {w}s…[/]")
            time.sleep(w)
            continue
        r.raise_for_status()
        return r.json()


def search_albums(token: str, query: str, market: str = "DE") -> list[dict]:
    """Up to 100 album results for query."""
    out: list[dict] = []
    offset = 0
    while offset < 100:
        page = _get(token, "https://api.spotify.com/v1/search", {
            "q": query, "type": "album", "market": market,
            "limit": 50, "offset": offset,
        })["albums"]
        items = page["items"]
        if not items:
            break
        out.extend(items)
        offset += len(items)
        if offset >= page["total"]:
            break
        time.sleep(0.1)
    return out


def search_artists(token: str, query: str, limit: int = 8) -> list[dict]:
    """Search for artists matching query."""
    page = _get(token, "https://api.spotify.com/v1/search", {
        "q": query, "type": "artist", "limit": limit,
    })
    return page["artists"]["items"]


def artist_albums(token: str, artist_id: str, market: str = "DE") -> list[dict]:
    """Fetch ALL albums (album + single) from an artist, fully paginated."""
    out: list[dict] = []
    url = f"https://api.spotify.com/v1/artists/{artist_id}/albums"
    offset = 0
    while True:
        page = _get(token, url, {
            "include_groups": "album,single",
            "market": market,
            "limit": 50,
            "offset": offset,
        })
        items = page["items"]
        if not items:
            break
        out.extend(items)
        offset += len(items)
        if offset >= page["total"]:
            break
        time.sleep(0.1)
    return out


def cached_search(token: str, sid: str, query: str, use_cache: bool) -> list[dict]:
    CACHE_SEARCH.mkdir(parents=True, exist_ok=True)
    f = CACHE_SEARCH / f"{sid}.json"
    if use_cache and f.exists():
        return json.loads(f.read_text())
    albums = search_albums(token, query)
    f.write_text(json.dumps(albums, ensure_ascii=False, indent=2))
    return albums


def cached_artist_albums(token: str, artist_id: str, use_cache: bool) -> list[dict]:
    CACHE_ARTISTS.mkdir(parents=True, exist_ok=True)
    f = CACHE_ARTISTS / f"{artist_id}.json"
    if use_cache and f.exists():
        return json.loads(f.read_text())
    albums = artist_albums(token, artist_id)
    f.write_text(json.dumps(albums, ensure_ascii=False, indent=2))
    return albums


# ── Matching ──────────────────────────────────────────────────────────────────

def keyword_match(title: str, keywords: list[str]) -> bool:
    lower = title.lower()
    for kw in sorted(keywords, key=len, reverse=True):
        if kw.lower() in lower:
            return True
    return False


def extract_with(title: str, pattern: str) -> Optional[int]:
    m = re.search(pattern, title, re.IGNORECASE)
    if not m:
        return None
    for i in range(m.lastindex or 0, 0, -1):
        g = m.group(i)
        if g:
            digits = re.sub(r"\D", "", g)
            if digits and not NOISE_RE.match(digits):
                n = int(digits)
                if n > 0:
                    return n
    return None


# ── Pattern analysis helpers ──────────────────────────────────────────────────

def analyze_names(names: list[str]) -> dict:
    """
    Given a list of album titles, return:
      - hits per candidate pattern
      - episode number distribution (min, max, count, gaps sample)
      - format frequency (counter of prefix shapes)
    """
    hits: dict[str, int] = {}
    ep_nums: dict[str, list[int]] = {}

    for pname, ppat in CANDIDATE_PATTERNS:
        ns = []
        for name in names:
            ep = extract_with(name, ppat)
            if ep is not None:
                ns.append(ep)
        hits[pname] = len(ns)
        ep_nums[pname] = sorted(set(ns))

    # Leading shape detection (first token shape)
    shape_counter: Counter = Counter()
    for name in names:
        m = re.match(r"^(\d+)([/:\.]?)", name)
        if m:
            shape_counter[f"^{m.group(1)[:0]}N{m.group(2)}"] += 1
        elif re.match(r"^[Ff]olge\s+\d+", name):
            shape_counter["Folge N"] += 1
        elif re.match(r"^[Bb]and\s+\d+", name):
            shape_counter["Band N"] += 1
        elif re.match(r"^[Tt]eil\s+\d+", name):
            shape_counter["Teil N"] += 1
        elif re.match(r"^[Ee]pisode\s+\d+", name):
            shape_counter["Episode N"] += 1
        else:
            shape_counter["other"] += 1

    return {"hits": hits, "ep_nums": ep_nums, "shapes": dict(shape_counter.most_common(6))}


# ── L1 syntax ─────────────────────────────────────────────────────────────────

@dataclass
class SyntaxIssue:
    severity: str
    message: str


def validate_syntax(series_list: list[dict]) -> list[SyntaxIssue]:
    issues: list[SyntaxIssue] = []
    seen_ids: set[str] = set()
    seen_titles: set[str] = set()

    for s in series_list:
        sid = s.get("id", "?")
        title = s.get("title", "?")

        for req in ("id", "title", "keywords"):
            if req not in s:
                issues.append(SyntaxIssue("error", f"{sid}: missing '{req}'"))

        if sid in seen_ids:
            issues.append(SyntaxIssue("error", f"duplicate id: {sid!r}"))
        seen_ids.add(sid)
        if title in seen_titles:
            issues.append(SyntaxIssue("warning", f"duplicate title: {title!r}"))
        seen_titles.add(title)

        kws = s.get("keywords", [])
        if not kws:
            issues.append(SyntaxIssue("error", f"{sid}: 'keywords' is empty"))
        for kw in kws:
            if len(kw) <= 2:
                issues.append(SyntaxIssue("warning",
                    f"{sid}: keyword {kw!r} ≤ 2 chars – likely causes false positives"))

        pat = s.get("episode_pattern")
        if pat:
            try:
                re.compile(pat)
            except re.error as e:
                issues.append(SyntaxIssue("error", f"{sid}: bad episode_pattern: {e}"))

    return issues


# ── Per-series report ─────────────────────────────────────────────────────────

@dataclass
class AlbumResult:
    name: str
    album_type: str
    spotify_id: str
    keyword_matched: bool
    episode_extracted: Optional[int]
    discovery: dict[str, Optional[int]] = field(default_factory=dict)


@dataclass
class ArtistDiscography:
    artist_id: str
    artist_name: str
    total_albums: int
    pattern_hits: dict[str, int]
    best_pattern: Optional[str]   # pattern name with most hits
    best_hits: int
    ep_range: tuple[int, int]     # (min, max) episode numbers found
    sample_names: list[str]       # first 8 album names
    shapes: dict[str, int]


@dataclass
class SeriesReport:
    sid: str
    title: str
    keywords: list[str]
    pattern: Optional[str]
    artist_ids: list[str]

    albums: list[AlbumResult] = field(default_factory=list)
    total_results: int = 0
    keyword_matched: int = 0
    episode_extracted: int = 0
    no_episode: int = 0
    discovery_hits: dict[str, int] = field(default_factory=dict)

    discographies: list[ArtistDiscography] = field(default_factory=list)

    syntax_issues: list[SyntaxIssue] = field(default_factory=list)

    @property
    def keyword_hit_rate(self) -> float:
        return self.keyword_matched / self.total_results if self.total_results else 0.0

    @property
    def pattern_hit_rate(self) -> float:
        return self.episode_extracted / self.keyword_matched if self.keyword_matched else 0.0

    @property
    def l2_ok(self) -> bool:
        # Pass if artist IDs cover it (L5), or keyword fires enough
        if self.artist_ids and self.discographies:
            return True
        return self.keyword_matched >= 3 or self.keyword_hit_rate >= 0.2

    @property
    def l3_ok(self) -> bool:
        if not self.pattern:
            return True
        if self.keyword_matched == 0:
            return True
        # Also pass if L5 shows the pattern works on the full discography
        if self.discographies:
            best = max((d.best_hits for d in self.discographies), default=0)
            if best > 0:
                return True
        return self.pattern_hit_rate >= 0.30

    @property
    def has_issues(self) -> bool:
        return bool(self.syntax_issues) or not self.l2_ok or not self.l3_ok


def analyze_series(token: str, s: dict, use_cache: bool, do_artist: bool) -> SeriesReport:
    sid        = s["id"]
    title      = s["title"]
    keywords   = s["keywords"]
    pattern    = s.get("episode_pattern")
    artist_ids = s.get("spotify_artist_ids", [])

    report = SeriesReport(sid=sid, title=title, keywords=keywords,
                          pattern=pattern, artist_ids=artist_ids)

    # ── L2/L3/L4: album search ───────────────────────────────────────────────
    raw = cached_search(token, sid, title, use_cache)
    report.total_results = len(raw)

    for alb in raw:
        name  = alb["name"]
        atype = alb.get("album_type", "?")
        kw    = keyword_match(name, keywords)
        ep    = extract_with(name, pattern) if (kw and pattern) else None
        disc  = {pname: extract_with(name, ppat)
                 for pname, ppat in CANDIDATE_PATTERNS} if kw else {}

        report.albums.append(AlbumResult(
            name=name, album_type=atype, spotify_id=alb["id"],
            keyword_matched=kw, episode_extracted=ep, discovery=disc,
        ))
        if kw:
            report.keyword_matched += 1
            if ep is not None:
                report.episode_extracted += 1
            elif pattern:
                report.no_episode += 1

    for pname, _ in CANDIDATE_PATTERNS:
        report.discovery_hits[pname] = sum(
            1 for a in report.albums
            if a.keyword_matched and a.discovery.get(pname) is not None
        )

    # ── L5: artist discography ───────────────────────────────────────────────
    if do_artist and artist_ids:
        for aid in artist_ids:
            albs = cached_artist_albums(token, aid, use_cache)
            names = [a["name"] for a in albs]
            analysis = analyze_names(names)

            best_pname = max(analysis["hits"], key=analysis["hits"].get) if analysis["hits"] else None
            best_hits  = analysis["hits"].get(best_pname, 0) if best_pname else 0

            all_eps: list[int] = []
            for eplist in analysis["ep_nums"].values():
                all_eps.extend(eplist)
            ep_range = (min(all_eps), max(all_eps)) if all_eps else (0, 0)

            # artist name from first album
            artist_name = aid
            if albs and albs[0].get("artists"):
                artist_name = albs[0]["artists"][0]["name"]

            report.discographies.append(ArtistDiscography(
                artist_id=aid, artist_name=artist_name,
                total_albums=len(albs),
                pattern_hits=analysis["hits"],
                best_pattern=best_pname,
                best_hits=best_hits,
                ep_range=ep_range,
                sample_names=names[:8],
                shapes=analysis["shapes"],
            ))

    return report


# ── Artist discovery mode ─────────────────────────────────────────────────────

def run_discover(token: str, series_list: list[dict], use_cache: bool) -> None:
    """Search Spotify for artist candidates for series without artist IDs."""
    console.print(Panel("[bold]Artist Discovery Mode[/]\n"
                        "Searching for Spotify artist candidates…", title="🔍"))

    for s in series_list:
        if s.get("spotify_artist_ids"):
            continue  # already have IDs

        sid   = s["id"]
        title = s["title"]
        console.print(f"\n[bold]{title}[/]  [dim]{sid}[/]")

        artists = search_artists(token, title, limit=6)
        time.sleep(0.15)

        if not artists:
            console.print("  [dim]no artist results[/]")
            continue

        t = Table(show_header=False, box=box.SIMPLE, padding=(0, 1))
        t.add_column("name", min_width=30)
        t.add_column("followers", justify="right", width=10)
        t.add_column("id", width=24)
        t.add_column("genres", min_width=20)

        for a in artists[:5]:
            name = a["name"]
            foll = f"{a['followers']['total']:,}"
            aid  = a["id"]
            genres = ", ".join(a.get("genres", [])[:3]) or "–"
            name_col = f"[bold]{name}[/]" if name.lower() == title.lower() else name
            t.add_row(name_col, foll, aid, genres)

        console.print(t)


# ── Rendering ─────────────────────────────────────────────────────────────────

STATUS_FMT = {
    "episode":    "[green]✓ ep[/]",
    "no_ep":      "[yellow]⚠ no-ep#[/]",
    "standalone": "[blue]ℹ solo[/]",
    "skip":       "[dim]· skip[/]",
}


def print_report(report: SeriesReport, verbose: bool = False) -> None:
    l2 = "[green]✓[/]" if report.l2_ok else "[red]✗[/]"
    l3 = ("[green]✓[/]" if report.l3_ok else "[red]✗[/]") if report.pattern else "[dim]–[/]"
    l5 = f"[cyan]L5:{sum(d.total_albums for d in report.discographies)}alb[/]" if report.discographies else ""

    kw = f"kw={report.keyword_matched}/{report.total_results}"
    ep = (f"ep={report.episode_extracted}/{report.keyword_matched}"
          if report.pattern else "no-pattern")

    console.print(
        f"  {l2} L2  {l3} L3  "
        f"[bold]{report.title}[/]  "
        f"[dim]{kw}  {ep}  {l5}[/]"
    )

    if not report.has_issues and not verbose:
        return

    # Syntax
    for si in report.syntax_issues:
        col = "red" if si.severity == "error" else "yellow"
        console.print(f"    [{col}]{si.severity}:[/] {si.message}")

    # L2: keyword barely fires
    if not report.l2_ok:
        console.print(f"    [red]L2:[/] keyword fires {report.keyword_hit_rate:.0%} "
                      f"— sample unmatched Spotify results:")
        for a in [x for x in report.albums if not x.keyword_matched][:6]:
            console.print(f"      [dim]{a.album_type:12}[/] {a.name}")

    # L3: pattern not extracting
    if report.pattern and not report.l3_ok and report.keyword_matched > 0:
        console.print(f"    [red]L3:[/] pattern extracts {report.pattern_hit_rate:.0%} "
                      f"— unextracted sample:")
        for a in [x for x in report.albums
                  if x.keyword_matched and x.episode_extracted is None][:6]:
            console.print(f"      [dim]{a.album_type:12}[/] {a.name}")

        better = sorted(
            ((n, h) for n, h in report.discovery_hits.items()
             if h > report.episode_extracted),
            key=lambda x: x[1], reverse=True,
        )
        if better:
            console.print("    [yellow]L4 better patterns:[/]")
            for pname, hits in better[:3]:
                ppat = dict(CANDIDATE_PATTERNS)[pname]
                console.print(f"      {hits:3d} hits  {pname:22}  `{ppat}`")

    # L5: artist discography summary
    for disc in report.discographies:
        ep_lo, ep_hi = disc.ep_range
        ep_range_str = f"ep {ep_lo}–{ep_hi}" if ep_lo else "no eps found"
        console.print(
            f"    [cyan]L5[/] {disc.artist_name}  "
            f"[dim]{disc.total_albums} albums  {ep_range_str}[/]"
        )
        console.print(f"      best pattern: {disc.best_pattern} "
                      f"({disc.best_hits}/{disc.total_albums} = "
                      f"{disc.best_hits/disc.total_albums:.0%})")
        if disc.shapes:
            shapes_str = "  ".join(f"{k}:{v}" for k, v in disc.shapes.items())
            console.print(f"      shapes: {shapes_str}")
        if verbose:
            for name in disc.sample_names:
                console.print(f"        {name}")


def print_summary(reports: list[SeriesReport]) -> None:
    console.print()
    t = Table(show_header=True, header_style="bold dim", box=box.SIMPLE)
    t.add_column("Series", min_width=28)
    t.add_column("L2", width=3)
    t.add_column("L3", width=3)
    t.add_column("kw match", justify="right", width=9)
    t.add_column("ep extr.", justify="right", width=9)
    t.add_column("L5 albums", justify="right", width=10)

    for r in reports:
        l2 = "[green]✓[/]" if r.l2_ok else "[red]✗[/]"
        l3 = ("[green]✓[/]" if r.l3_ok else "[red]✗[/]") if r.pattern else "[dim]–[/]"
        kw = f"{r.keyword_matched}/{r.total_results}"
        ep = f"{r.episode_extracted}/{r.keyword_matched}" if r.pattern else "–"
        l5 = str(sum(d.total_albums for d in r.discographies)) if r.discographies else ""
        t.add_row(r.title, l2, l3, kw, ep, l5)

    console.print(t)
    issues   = sum(1 for r in reports if r.has_issues)
    l5_total = sum(sum(d.total_albums for d in r.discographies) for r in reports)
    console.print(
        f"\n[dim]{len(reports)} series · {issues} with issues · "
        f"L5 total albums: {l5_total}[/]"
    )


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--series",       help="Filter by title substring")
    ap.add_argument("--no-cache",     dest="no_cache", action="store_true")
    ap.add_argument("--verbose", "-v",action="store_true")
    ap.add_argument("--artist-audit", dest="artist_audit", action="store_true",
                    help="Fetch full discographies for series with spotify_artist_ids")
    ap.add_argument("--discover",     action="store_true",
                    help="Search for artist candidates for series without IDs")
    ap.add_argument("--json",         metavar="FILE")
    ap.add_argument("--ci",           action="store_true")
    args = ap.parse_args()

    env = load_dotenv(REPO_ROOT / ".env")
    client_id     = os.environ.get("SPOTIFY_CLIENT_ID")     or env.get("SPOTIFY_CLIENT_ID", "")
    client_secret = os.environ.get("SPOTIFY_CLIENT_SECRET") or env.get("SPOTIFY_CLIENT_SECRET", "")
    if not client_id or not client_secret:
        console.print("[red]✗[/] Missing SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET")
        sys.exit(1)

    catalog     = yaml.safe_load(CATALOG_PATH.read_text())
    series_list: list[dict] = catalog["series"]

    if args.series:
        series_list = [s for s in series_list
                       if args.series.lower() in s["title"].lower()]
        if not series_list:
            console.print(f"[red]No series matching '{args.series}'[/]")
            sys.exit(1)

    use_cache = not args.no_cache

    console.print(Panel(
        f"[bold]lauschi catalog validator[/]\n"
        f"{len(series_list)} series · "
        f"{'live' if args.no_cache else 'cached'} · "
        f"L5={'on' if args.artist_audit else 'off'} · "
        f"discover={'on' if args.discover else 'off'}",
        title="🎧",
    ))

    try:
        token = get_token(client_id, client_secret)
        console.print("[green]✓[/] Spotify OK\n")
    except Exception as e:
        console.print(f"[red]✗ auth:[/] {e}")
        sys.exit(1)

    # ── Syntax ───────────────────────────────────────────────────────────────
    syntax_issues = validate_syntax(series_list)
    if syntax_issues:
        for si in syntax_issues:
            col = "red" if si.severity == "error" else "yellow"
            console.print(f"[{col}]L1 {si.severity}:[/] {si.message}")
    else:
        console.print("[green]✓[/] L1 syntax OK")

    # ── Discover mode ─────────────────────────────────────────────────────────
    if args.discover:
        run_discover(token, series_list, use_cache)
        return

    # ── Full audit ───────────────────────────────────────────────────────────
    all_reports: list[SeriesReport] = []
    for s in series_list:
        report = analyze_series(token, s, use_cache, do_artist=args.artist_audit)
        report.syntax_issues = [si for si in syntax_issues if s["id"] in si.message]
        all_reports.append(report)
        print_report(report, verbose=args.verbose)

    print_summary(all_reports)

    if args.json:
        def _serial(r: SeriesReport) -> dict:
            return {
                "id": r.sid, "title": r.title,
                "l2_ok": r.l2_ok, "l3_ok": r.l3_ok,
                "keyword_hit_rate": round(r.keyword_hit_rate, 3),
                "pattern_hit_rate": round(r.pattern_hit_rate, 3),
                "keyword_matched": r.keyword_matched,
                "episode_extracted": r.episode_extracted,
                "discovery_hits": r.discovery_hits,
                "discographies": [
                    {"artist_id": d.artist_id, "artist_name": d.artist_name,
                     "total_albums": d.total_albums, "best_pattern": d.best_pattern,
                     "best_hits": d.best_hits, "ep_range": list(d.ep_range),
                     "shapes": d.shapes, "pattern_hits": d.pattern_hits}
                    for d in r.discographies
                ],
            }
        Path(args.json).write_text(
            json.dumps([_serial(r) for r in all_reports], indent=2, ensure_ascii=False))
        console.print(f"[green]✓[/] JSON → {args.json}")

    if args.ci:
        if any(r.has_issues for r in all_reports) or syntax_issues:
            sys.exit(1)


if __name__ == "__main__":
    main()
