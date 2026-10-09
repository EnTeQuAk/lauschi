"""Albums that hold a run of episodes ("Folgen 6-10", "Folge 1+2").

A run in the number position means one of two things. Either the
release re-sells episodes that also exist on their own (a compilation),
or it is the only way to get those episodes, as with Feuerwehrmann Sam
1 to 132 or the Lillifee Gute-Nacht double episodes. The curator sees a
page in batches and cannot tell the two apart, so `range_facts` works it
out from the whole page and the batch gets it as a fact.

An included run carries the number of its first episode, so code that
looks for gaps uses `covered_episodes` to count the rest of the run.
"""

import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from typing import Protocol

from lauschi_catalog.catalog.matcher import extract_episode

# "Folgen 6-10", "Folge 1+2", "Folgen 3 & 4", "Episode 6-10". The keyword
# keeps "Teil 1 & 2" (one story in two parts) out, and the digit after the
# joiner keeps "Folge 4: Die Elchjagd + zwei weitere Geschichten" out.
_RUN = re.compile(
    r"\b(?:folgen?|episoden?)\s*(\d{1,4})\s*(?:-|–|\+|&|und|bis)\s*(\d{1,4})",
    re.IGNORECASE,
)

# A dash followed by a year ("Folge 12 - 2019") is no run. The widest real
# run in the catalog is a ten-episode jubilee box.
_MAX_SPAN = 50


class Decided(Protocol):
    """What a prior decision tells about the page: an AlbumDecision."""

    provider: str
    title: str
    episode_num: int | None


@dataclass(frozen=True)
class EpisodeRange:
    first: int
    last: int

    @property
    def episodes(self) -> tuple[int, ...]:
        return tuple(range(self.first, self.last + 1))


@dataclass(frozen=True)
class RangeFact:
    """A run on one provider page, and which of its episodes that page
    also offers as releases of their own."""

    first: int
    last: int
    released_alone: tuple[int, ...]


def episode_range(title: str) -> EpisodeRange | None:
    """The run of episodes a title names in its number position, or None."""
    m = _RUN.search(title)
    if not m:
        return None
    first, last = int(m.group(1)), int(m.group(2))
    if not 0 < last - first <= _MAX_SPAN:
        return None
    return EpisodeRange(first, last)


def title_number(pattern: str | list[str] | None, title: str) -> int | None:
    """The episode number a title carries: what the series pattern reads,
    or else the first episode of a run the title names. A box that is the
    only release of its episodes is numbered that way, as the Lillifee
    double episodes ("Folge 1+2") are."""
    number = extract_episode(pattern, title)
    if number is not None:
        return number
    run = episode_range(title)
    return run.first if run is not None else None


def range_facts(
    albums: Iterable[Mapping[str, object]],
    pattern: str | list[str] | None,
    decided: Mapping[str, set[int]] | None = None,
) -> dict[tuple[str, str], RangeFact]:
    """For every album on the page that holds a run, the episodes of that
    run which the same provider page also offers on their own.

    ``albums`` are discovery rows (``provider``, ``id``, ``name``).
    Numbers come from the series pattern on the other titles, plus the
    numbers prior runs already decided (``decided``, per provider), so a
    single whose title the pattern misses still counts. Without either
    source there is nothing to compare against and no fact is given.
    """
    decided = decided or {}
    if not pattern and not decided:
        return {}
    runs: dict[tuple[str, str], EpisodeRange] = {}
    alone: dict[str, set[int]] = {
        provider: set(numbers) for provider, numbers in decided.items()
    }
    for album in albums:
        provider, album_id = str(album["provider"]), str(album["id"])
        title = str(album.get("name") or "")
        run = episode_range(title)
        if run is not None:
            runs[(provider, album_id)] = run
            continue
        number = extract_episode(pattern, title)
        if number is not None:
            alone.setdefault(provider, set()).add(number)
    return {
        (provider, album_id): RangeFact(
            run.first,
            run.last,
            released_alone=tuple(
                n for n in run.episodes if n in alone.get(provider, set())
            ),
        )
        for (provider, album_id), run in runs.items()
    }


def numbers_released_alone(decisions: Iterable[Decided]) -> dict[str, set[int]]:
    """Episode numbers prior decisions gave to single releases, per
    provider. A run carries the number of its first episode and must not
    count as that episode released alone."""
    numbers: dict[str, set[int]] = {}
    for d in decisions:
        if d.episode_num is not None and episode_range(d.title) is None:
            numbers.setdefault(d.provider, set()).add(d.episode_num)
    return numbers


def covered_episodes(albums: Iterable[Mapping[str, object]]) -> set[int]:
    """Episode numbers the albums cover, a run counting in full.

    ``albums`` are curation records (``episode_num``, ``title``). A run
    covers its episodes only when it carries its own first number, the
    way the curator numbers it. Numbered any other way it covers just
    that number, and the oddity is left for a human to see.
    """
    covered: set[int] = set()
    for album in albums:
        number = album.get("episode_num")
        if not isinstance(number, int):
            continue
        run = episode_range(str(album.get("title") or ""))
        if run is not None and run.first == number:
            covered.update(run.episodes)
        else:
            covered.add(number)
    return covered
