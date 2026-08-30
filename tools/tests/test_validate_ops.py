"""Tests for catalog/validate_ops.py L5 album-existence checks.

Apple Music re-releases content under new album IDs and detaches albums
from artist pages. Discography membership alone reported live albums as
missing (Coco, Encanto, Eule findet den Beat), so the album check must
fall back to a direct album lookup before declaring an ID gone.
"""

from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.validate_ops import validate_l1, validate_l5
from lauschi_catalog.providers import Album
from lauschi_catalog.providers.base import AlbumBatch


def _album(aid: str, name: str = "Album") -> Album:
    return Album(id=aid, name=name, provider="apple_music")


class FakeProvider:
    """Minimal CatalogProvider stand-in for validate_l5."""

    name = "apple_music"

    def __init__(
        self,
        discography: list[Album],
        existing: dict[str, Album],
        batch: AlbumBatch | None = None,
    ):
        self._discography = discography
        self._existing = existing
        self._batch = batch
        self.album_lookups: list[str] = []
        self.batch_lookups: list[list[str]] = []

    def artist_albums(self, artist_id: str) -> list[Album]:
        return self._discography

    def album_details(self, album_id: str) -> Album | None:
        self.album_lookups.append(album_id)
        return self._existing.get(album_id)

    def albums_by_ids(self, album_ids: list[str]) -> AlbumBatch:
        self.batch_lookups.append(album_ids)
        if self._batch is not None:
            return self._batch
        found = [self._existing[aid] for aid in album_ids if aid in self._existing]
        return AlbumBatch(albums=found)


def _entry(artist_ids: list[str], album_ids: list[str]) -> CatalogEntry:
    return CatalogEntry(
        id="test_series",
        title="Test Series",
        providers={
            "apple_music": ProviderConfig(
                artist_ids=artist_ids,
                album_ids=album_ids,
                has_albums=bool(album_ids),
            ),
        },
    )


def test_album_in_discography_counts_as_found():
    provider = FakeProvider([_album("111")], {"111": _album("111")})
    result = validate_l5(_entry(["a1"], ["111"]), provider)
    assert result.album_check is True
    assert (result.matched, result.total) == (1, 1)
    assert result.unmatched == []


def test_album_missing_from_discography_but_live_counts_as_found():
    # The Eule/Coco/Encanto case: album exists, artist page doesn't list it.
    provider = FakeProvider(
        [_album("111")], {"111": _album("111"), "222": _album("222")}
    )
    result = validate_l5(_entry(["a1"], ["111", "222"]), provider)
    assert (result.matched, result.total) == (2, 2)
    assert result.unmatched == []


def test_album_gone_entirely_reported_missing():
    # The TiRiLi case: ID removed from the store, re-released under a new ID.
    provider = FakeProvider([_album("111")], {"111": _album("111")})
    result = validate_l5(_entry(["a1"], ["111", "999"]), provider)
    assert (result.matched, result.total) == (1, 2)
    assert result.unmatched == ["999"]


def test_album_check_runs_without_artist_ids():
    # The peter_pan_kinofilm case: configured albums, no artist page.
    provider = FakeProvider([], {"333": _album("333")})
    result = validate_l5(_entry([], ["333"]), provider)
    assert result.album_check is True
    assert (result.matched, result.total) == (1, 1)
    assert result.unmatched == []


def test_unverified_ids_are_not_reported_missing():
    """A provider error (e.g. 429) leaves ids in unverified, not unmatched."""
    provider = FakeProvider([], {}, batch=AlbumBatch(albums=[], unverified=["777"]))
    result = validate_l5(_entry([], ["777"]), provider)
    assert result.album_check is True
    assert (result.matched, result.total) == (0, 1)
    assert result.unmatched == []
    assert result.unverified == ["777"]


def test_pattern_and_album_check_together():
    """When both pattern and configured ids exist, run both checks."""
    provider = FakeProvider(
        [_album("111", "Folge 1: A"), _album("222", "Folge 2: B")],
        {},
        batch=AlbumBatch(albums=[_album("111"), _album("222")]),
    )
    entry = CatalogEntry(
        id="test_series",
        title="Test Series",
        episode_pattern=r"^Folge (\d+):",
        providers={
            "apple_music": ProviderConfig(
                artist_ids=["a1"],
                album_ids=["111", "222", "999"],
                has_albums=True,
            )
        },
    )
    result = validate_l5(entry, provider)
    assert result.album_check is True
    assert (result.matched, result.total) == (2, 3)
    assert result.unmatched == ["999"]
    assert result.has_pattern is True
    assert (result.pattern_matched, result.pattern_total) == (2, 2)


def test_no_pattern_no_albums_returns_empty():
    provider = FakeProvider([_album("111")], {})
    result = validate_l5(_entry(["a1"], []), provider)
    assert result.total == 0
    assert result.album_check is False


# ── L1: cross-series album uniqueness ─────────────────────────────────────


def _entry_with(
    sid: str, album_ids: list[str], provider: str = "apple_music"
) -> CatalogEntry:
    return CatalogEntry(
        id=sid,
        title=sid,
        providers={provider: ProviderConfig(album_ids=album_ids, has_albums=True)},
    )


def test_l1_flags_album_shipping_under_two_series():
    """CatalogService._buildAlbumIndex keys by provider:albumId and lets
    the last series win, so a duplicated album is attributed arbitrarily
    and shows up under two tiles. This regressed 80 -> 269 albums during
    the July 2026 splits before it was caught."""
    issues = validate_l1(
        [
            _entry_with("lego_city_klassik", ["111", "222"]),
            _entry_with("lego_city_tv_serie", ["222"]),
        ]
    )
    assert len(issues) == 1
    assert "222" in issues[0]
    assert "lego_city_klassik" in issues[0]
    assert "lego_city_tv_serie" in issues[0]


def test_l1_allows_same_album_id_across_providers():
    """Album IDs are provider-scoped; an identical string under two
    different providers is not a collision."""
    entry = CatalogEntry(
        id="s1",
        title="S1",
        providers={
            "spotify": ProviderConfig(album_ids=["dup"], has_albums=True),
            "apple_music": ProviderConfig(album_ids=["dup"], has_albums=True),
        },
    )
    assert validate_l1([entry]) == []


def test_l1_clean_catalog_has_no_duplicate_issues():
    issues = validate_l1(
        [
            _entry_with("a", ["1", "2"]),
            _entry_with("b", ["3"]),
        ]
    )
    assert issues == []


# ── L1: double-escaped regex shortcuts ────────────────────────────────────
#
# lieselotte_filmhoerspiele carried '^Folge (\\d+):' in single-quoted YAML
# for months. Single quotes do not process escapes, so the pattern loaded
# as a literal backslash followed by 'd' and matched nothing. Python hid
# it by silently repairing the pattern before use; the app could not match
# it at all.
#
# The check must look at the LOADED value, not the file text: the
# double-quoted "^Senta's Welt - Folge (\\d+):" looks identical in the
# file but YAML collapses it to a single backslash, and that one is fine.


def test_l1_flags_double_escaped_shortcut():
    entry = CatalogEntry(
        id="lieselotte_filmhoerspiele",
        title="Lieselotte",
        episode_pattern="^Folge (\\\\d+):",
    )
    issues = validate_l1([entry])
    assert len(issues) == 1
    assert "lieselotte_filmhoerspiele" in issues[0]
    assert "escap" in issues[0].lower()


def test_l1_accepts_a_correctly_escaped_shortcut():
    entry = CatalogEntry(
        id="sentas_welt",
        title="Senta's Welt",
        episode_pattern="^Senta's Welt - Folge (\\d+):",
    )
    assert validate_l1([entry]) == []


def test_l1_flags_double_escaped_shortcut_inside_a_pattern_list():
    entry = CatalogEntry(
        id="s1",
        title="S1",
        episode_pattern=["^Folge (\\d+):", "^Teil (\\\\d+):"],
    )
    issues = validate_l1([entry])
    assert len(issues) == 1
    assert "Teil" in issues[0]


def test_l1_flags_other_double_escaped_classes():
    for shortcut in ("w", "s", "b"):
        entry = CatalogEntry(
            id="s1",
            title="S1",
            episode_pattern=f"^Folge (\\\\{shortcut}+):",
        )
        assert len(validate_l1([entry])) == 1, shortcut


# ── CLI exit codes ───────────────────────────────────────────────────────


def test_validate_cli_exits_1_on_l1_issue(monkeypatch):
    """A duplicate album across series must fail validation even with --series."""
    from click.testing import CliRunner

    from lauschi_catalog.catalog import validate_ops
    from lauschi_catalog.commands import validate as validate_cmd

    def _bad_catalog():
        return [
            _entry_with("a", ["dup"]),
            _entry_with("b", ["dup"]),
        ]

    monkeypatch.setattr(validate_ops, "load_catalog", _bad_catalog)
    monkeypatch.setattr(
        validate_cmd, "init_providers", lambda *_a, **_kw: _ProvidersResult()
    )

    runner = CliRunner()
    result = runner.invoke(validate_cmd.validate, ["--series", "a"])
    assert result.exit_code == 1
    assert "dup" in result.output


def test_validate_cli_exits_1_on_missing_album(monkeypatch):
    from click.testing import CliRunner

    from lauschi_catalog.catalog import validate_ops
    from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
    from lauschi_catalog.commands import validate as validate_cmd

    class _P:
        name = "apple_music"

        def albums_by_ids(self, album_ids: list[str]):
            return AlbumBatch(albums=[])

    class _R:
        providers = [_P()]
        warnings = []

    monkeypatch.setattr(
        validate_cmd,
        "init_providers",
        lambda *_a, **_kw: _R(),
    )
    monkeypatch.setattr(
        validate_ops,
        "load_catalog",
        lambda: [
            CatalogEntry(
                id="s1",
                title="S1",
                providers={
                    "apple_music": ProviderConfig(
                        album_ids=["missing"], has_albums=True
                    )
                },
            )
        ],
    )

    runner = CliRunner()
    result = runner.invoke(validate_cmd.validate, [])
    assert result.exit_code == 1, result.output
    assert "ids:0/1" in result.output


class _ProvidersResult:
    providers: list = []
    warnings: list = []
