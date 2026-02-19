#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests>=2.31", "pyyaml>=6.0", "rich>=13.7"]
# ///
"""
Comprehensive validator for lauschi assets/catalog/series.yaml.

Checks four layers for each series:

  L1  SYNTAX      required fields, regex compiles, unique ids/titles
  L2  SEARCH      keyword hit-rate against real Spotify results
                  (flags series where keyword never fires → wrong/missing keyword)
  L3  PATTERN     episode_pattern coverage within keyword-matched albums
                  (flags pattern that extracts nothing, or wrongly extracts years/noise)
  L4  DISCOVERY   probes ~10 common DACH hörspiel naming patterns against the
                  keyword-matched set → suggests a better episode_pattern

Results are cached in .cache/spotify_catalog/.
Reruns are instant; use --no-cache to force fresh API calls.

Usage:
    uv run scripts/validate_catalog.py                       # full report
    uv run scripts/validate_catalog.py --series Fuchsbande   # one series
    uv run scripts/validate_catalog.py --no-cache            # fresh API data
    uv run scripts/validate_catalog.py --json out.json       # machine-readable
    uv run scripts/validate_catalog.py --ci                  # exit 1 on issues
"""

import argparse
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import requests
import yaml
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

console = Console()

REPO_ROOT = Path(__file__).parent.parent
CATALOG_PATH = REPO_ROOT / "assets" / "catalog" / "series.yaml"
CACHE_DIR = REPO_ROOT / ".cache" / "spotify_catalog"

# ── Common DACH naming patterns to probe during pattern discovery ─────────────

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

# Years and other numeric noise to veto
NOISE_RE = re.compile(r"^(19|20)\d{2}$")


# ── Auth & Spotify ─────────────────────────────────────────────────────────────

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


def spotify_search(token: str, query: str, market: str = "DE") -> list[dict]:
    """Return up to 100 album results, handling pagination + rate-limits."""
    out: list[dict] = []
    headers = {"Authorization": f"Bearer {token}"}
    offset = 0
    while offset < 100:
        params = {"q": query, "type": "album", "market": market,
                  "limit": 50, "offset": offset}
        while True:
            r = requests.get("https://api.spotify.com/v1/search",
                             headers=headers, params=params, timeout=15)
            if r.status_code == 429:
                w = int(r.headers.get("Retry-After", 3))
                console.print(f"[yellow]rate-limited – waiting {w}s…[/]")
                time.sleep(w)
                continue
            r.raise_for_status()
            break
        page = r.json()["albums"]
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
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    f = CACHE_DIR / f"{sid}.json"
    if use_cache and f.exists():
        return json.loads(f.read_text())
    albums = spotify_search(token, query)
    f.write_text(json.dumps(albums, ensure_ascii=False, indent=2))
    return albums


# ── Matching (mirrors CatalogService.dart) ────────────────────────────────────

def keyword_match(title: str, keywords: list[str]) -> bool:
    lower = title.lower()
    for kw in sorted(keywords, key=len, reverse=True):
        if kw.lower() in lower:
            return True
    return False


def extract_with(title: str, pattern: str) -> Optional[int]:
    """Try pattern; return first non-noise integer group, or None."""
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


# ── L1: Syntax validation (no API required) ──────────────────────────────────

@dataclass
class SyntaxIssue:
    severity: str  # "error" | "warning"
    message: str


def validate_syntax(series_list: list[dict]) -> list[SyntaxIssue]:
    issues: list[SyntaxIssue] = []
    seen_ids: set[str] = set()
    seen_titles: set[str] = set()

    for s in series_list:
        sid   = s.get("id", "?")
        title = s.get("title", "?")

        # Required fields
        for req in ("id", "title", "keywords"):
            if req not in s:
                issues.append(SyntaxIssue("error", f"{sid}: missing field '{req}'"))

        # Unique id / title
        if sid in seen_ids:
            issues.append(SyntaxIssue("error", f"Duplicate id: {sid!r}"))
        seen_ids.add(sid)
        if title in seen_titles:
            issues.append(SyntaxIssue("warning", f"Duplicate title: {title!r}"))
        seen_titles.add(title)

        # Keywords non-empty
        kws = s.get("keywords", [])
        if not kws:
            issues.append(SyntaxIssue("error", f"{sid}: 'keywords' is empty"))
        for kw in kws:
            if len(kw) <= 2:
                issues.append(SyntaxIssue("warning",
                    f"{sid}: keyword {kw!r} is very short – may cause false positives"))

        # episode_pattern compiles
        pat = s.get("episode_pattern")
        if pat:
            try:
                re.compile(pat)
            except re.error as e:
                issues.append(SyntaxIssue("error",
                    f"{sid}: episode_pattern does not compile: {e}"))

    return issues


# ── L2 / L3 / L4: per-series API validation ──────────────────────────────────

@dataclass
class AlbumResult:
    name: str
    album_type: str   # album / single / compilation
    spotify_id: str
    keyword_matched: bool
    episode_extracted: Optional[int]
    # discovery: {pattern_name: extracted_int_or_None}
    discovery: dict[str, Optional[int]] = field(default_factory=dict)


@dataclass
class SeriesReport:
    sid: str
    title: str
    keywords: list[str]
    pattern: Optional[str]
    albums: list[AlbumResult] = field(default_factory=list)

    # L2
    total_results: int = 0
    keyword_matched: int = 0

    # L3
    episode_extracted: int = 0
    no_episode: int = 0         # keyword matched but no episode number

    # pattern discovery hits per candidate pattern
    discovery_hits: dict[str, int] = field(default_factory=dict)

    # issues
    syntax_issues: list[SyntaxIssue] = field(default_factory=list)

    @property
    def keyword_hit_rate(self) -> float:
        if self.total_results == 0:
            return 0.0
        return self.keyword_matched / self.total_results

    @property
    def pattern_hit_rate(self) -> float:
        if self.keyword_matched == 0:
            return 0.0
        return self.episode_extracted / self.keyword_matched

    @property
    def l2_ok(self) -> bool:
        # At least 20% of search results match keyword, or 3+ absolute matches
        return self.keyword_matched >= 3 or self.keyword_hit_rate >= 0.2

    @property
    def l3_ok(self) -> bool:
        # If no pattern, it's fine (standalone series)
        if not self.pattern:
            return True
        # If keyword matched nothing, can't judge
        if self.keyword_matched == 0:
            return True
        # At least 30% of keyword matches should extract an episode
        return self.pattern_hit_rate >= 0.30

    @property
    def has_issues(self) -> bool:
        return bool(self.syntax_issues) or not self.l2_ok or not self.l3_ok


def analyze_series(token: str, s: dict, use_cache: bool) -> SeriesReport:
    sid      = s["id"]
    title    = s["title"]
    keywords = s["keywords"]
    pattern  = s.get("episode_pattern")

    report = SeriesReport(sid=sid, title=title, keywords=keywords, pattern=pattern)

    raw = cached_search(token, sid, title, use_cache)
    report.total_results = len(raw)

    for alb in raw:
        name     = alb["name"]
        atype    = alb.get("album_type", "?")
        spot_id  = alb["id"]
        kw_hit   = keyword_match(name, keywords)
        ep       = extract_with(name, pattern) if (kw_hit and pattern) else None

        # Discovery: run all candidate patterns against keyword-matched albums
        disc: dict[str, Optional[int]] = {}
        if kw_hit:
            for pname, ppat in CANDIDATE_PATTERNS:
                disc[pname] = extract_with(name, ppat)

        ar = AlbumResult(name=name, album_type=atype, spotify_id=spot_id,
                         keyword_matched=kw_hit, episode_extracted=ep, discovery=disc)
        report.albums.append(ar)

        if kw_hit:
            report.keyword_matched += 1
            if ep is not None:
                report.episode_extracted += 1
            elif pattern:
                report.no_episode += 1

    # Tally discovery hits across all keyword-matched albums
    for pname, _ in CANDIDATE_PATTERNS:
        hits = sum(
            1 for a in report.albums
            if a.keyword_matched and a.discovery.get(pname) is not None
        )
        report.discovery_hits[pname] = hits

    return report


# ── Rendering ─────────────────────────────────────────────────────────────────

def severity_icon(ok: bool) -> str:
    return "[green]✓[/]" if ok else "[red]✗[/]"


def print_report(report: SeriesReport, verbose: bool = False) -> None:
    # One-line status bar
    l2_icon = severity_icon(report.l2_ok)
    l3_icon = severity_icon(report.l3_ok) if report.pattern else "[dim]–[/]"
    kw_rate  = f"{report.keyword_matched}/{report.total_results}"
    ep_rate  = (f"{report.episode_extracted}/{report.keyword_matched}"
                if report.pattern else "no pattern")

    console.print(
        f"  {l2_icon} L2  {l3_icon} L3  "
        f"[bold]{report.title}[/]  "
        f"[dim]kw={kw_rate}  ep={ep_rate}[/]"
    )

    if not report.has_issues and not verbose:
        return

    # Syntax issues
    for si in report.syntax_issues:
        col = "red" if si.severity == "error" else "yellow"
        console.print(f"      [{col}]L1 {si.severity}:[/] {si.message}")

    # L2 problem: keyword barely fires — show sample Spotify titles we're missing
    if not report.l2_ok:
        console.print(f"      [red]L2:[/] keyword hit-rate "
                      f"{report.keyword_hit_rate:.0%} — "
                      f"showing sample Spotify results that didn't match:")
        non_matched = [a for a in report.albums if not a.keyword_matched][:8]
        for a in non_matched:
            console.print(f"        [dim]{a.album_type:12}[/] {a.name}")

    # L3 problem: pattern not extracting — show what the no-ep albums look like
    if report.pattern and not report.l3_ok and report.keyword_matched > 0:
        console.print(f"      [red]L3:[/] episode_pattern extracts "
                      f"{report.pattern_hit_rate:.0%} of matched albums — "
                      f"unextracted examples:")
        no_ep = [a for a in report.albums
                 if a.keyword_matched and a.episode_extracted is None][:8]
        for a in no_ep:
            console.print(f"        [dim]{a.album_type:12}[/] {a.name}")

        # Pattern discovery — show which candidate patterns do better
        better = sorted(
            ((n, h) for n, h in report.discovery_hits.items()
             if h > report.episode_extracted),
            key=lambda x: x[1], reverse=True,
        )
        if better:
            console.print("      [yellow]L4 better patterns found:[/]")
            for pname, hits in better[:4]:
                ppat = dict(CANDIDATE_PATTERNS)[pname]
                console.print(f"        {hits:3d} hits  {pname:22}  `{ppat}`")


def print_summary(reports: list[SeriesReport]) -> None:
    console.print()
    t = Table(show_header=True, header_style="bold dim", box=None)
    t.add_column("Series", min_width=28)
    t.add_column("L2 kw", justify="right", width=8)
    t.add_column("L3 ep", justify="right", width=8)
    t.add_column("L2", width=3)
    t.add_column("L3", width=3)

    for r in reports:
        kw = f"{r.keyword_matched}/{r.total_results}"
        ep = (f"{r.episode_extracted}/{r.keyword_matched}"
              if r.pattern else "–")
        l2 = severity_icon(r.l2_ok)
        l3 = severity_icon(r.l3_ok) if r.pattern else "[dim]–[/]"
        t.add_row(r.title, kw, ep, l2, l3)

    console.print(t)

    errors   = sum(1 for r in reports if not r.l2_ok or not r.l3_ok)
    syn_errs = sum(len(r.syntax_issues) for r in reports)
    console.print(
        f"\n[dim]{len(reports)} series · "
        f"{errors} with L2/L3 issues · "
        f"{syn_errs} syntax issues[/]"
    )


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="Validate series.yaml vs Spotify")
    ap.add_argument("--series",    help="Filter to series whose title contains this")
    ap.add_argument("--no-cache",  dest="no_cache", action="store_true")
    ap.add_argument("--verbose",   action="store_true", help="Show details for clean series too")
    ap.add_argument("--json",      metavar="FILE")
    ap.add_argument("--ci",        action="store_true", help="Exit 1 if any issues found")
    args = ap.parse_args()

    # ── credentials ──────────────────────────────────────────────────────────
    env = load_dotenv(REPO_ROOT / ".env")
    client_id     = os.environ.get("SPOTIFY_CLIENT_ID")     or env.get("SPOTIFY_CLIENT_ID", "")
    client_secret = os.environ.get("SPOTIFY_CLIENT_SECRET") or env.get("SPOTIFY_CLIENT_SECRET", "")
    if not client_id or not client_secret:
        console.print("[red]✗[/] Missing SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET")
        sys.exit(1)

    # ── load catalog ─────────────────────────────────────────────────────────
    catalog      = yaml.safe_load(CATALOG_PATH.read_text())
    series_list: list[dict] = catalog["series"]

    if args.series:
        series_list = [s for s in series_list
                       if args.series.lower() in s["title"].lower()]
        if not series_list:
            console.print(f"[red]No series matching '{args.series}'[/]")
            sys.exit(1)

    # ── L1: syntax (no API) ──────────────────────────────────────────────────
    console.print(Panel(
        f"[bold]lauschi catalog validator[/]\n"
        f"{len(series_list)} series  ·  "
        f"{'live' if args.no_cache else 'cached'} Spotify data  ·  "
        f"market=DE",
        title="🎧",
    ))
    syntax_issues = validate_syntax(series_list)
    if syntax_issues:
        console.print("[bold]L1 Syntax issues:[/]")
        for si in syntax_issues:
            col = "red" if si.severity == "error" else "yellow"
            console.print(f"  [{col}]{si.severity}:[/] {si.message}")
    else:
        console.print("[green]✓[/] L1 syntax OK")

    # ── L2/L3/L4: API validation ─────────────────────────────────────────────
    try:
        token = get_token(client_id, client_secret)
        console.print(f"[green]✓[/] Spotify auth OK\n")
    except Exception as e:
        console.print(f"[red]✗ auth failed:[/] {e}")
        sys.exit(1)

    use_cache = not args.no_cache
    all_reports: list[SeriesReport] = []

    for s in series_list:
        report = analyze_series(token, s, use_cache)
        # attach any syntax issues that belong to this series
        report.syntax_issues = [
            si for si in syntax_issues if s["id"] in si.message
        ]
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
                "total_results": r.total_results,
                "keyword_matched": r.keyword_matched,
                "episode_extracted": r.episode_extracted,
                "discovery_hits": r.discovery_hits,
                "syntax_issues": [vars(si) for si in r.syntax_issues],
                "albums": [
                    {"name": a.name, "type": a.album_type,
                     "kw": a.keyword_matched, "ep": a.episode_extracted}
                    for a in r.albums
                ],
            }
        Path(args.json).write_text(
            json.dumps([_serial(r) for r in all_reports],
                       indent=2, ensure_ascii=False)
        )
        console.print(f"[green]✓[/] JSON → {args.json}")

    if args.ci:
        issues = [r for r in all_reports if r.has_issues]
        if issues or syntax_issues:
            sys.exit(1)


if __name__ == "__main__":
    main()
