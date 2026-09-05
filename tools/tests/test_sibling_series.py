"""The batch prompt names the sibling series the catalog already knows.

On Spotify and Apple Music one artist page often hosts several catalog
entries: 122 artist ids are shared by more than one series (Die drei ???
Kids with its Adventskalender and Mini-Fälle, Lego Ninjago with its
Hörbuch line). The batch model used to guess whether an album belonged
to a sibling; now code tells it which siblings exist, so the decision
rests on a fact the catalog holds, not on inference (D5, 2026-09-05).
"""

from lauschi_catalog.catalog.curate_ops import build_batch_prompt
from lauschi_catalog.catalog.loader import sibling_series
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig


def _entry(sid: str, title: str, *, spotify=(), apple=(), split_from=None):
    providers = {}
    if spotify:
        providers["spotify"] = ProviderConfig(artist_ids=list(spotify))
    if apple:
        providers["apple_music"] = ProviderConfig(artist_ids=list(apple))
    return CatalogEntry(id=sid, title=title, split_from=split_from, providers=providers)


CATALOG = [
    _entry("lego_ninjago", "Lego Ninjago", spotify=["art1"], apple=["a1"]),
    _entry("lego_ninjago_hoerbuch", "Lego Ninjago Hörbuch", spotify=["art1"]),
    _entry("ddf_kids", "Die drei ??? Kids", spotify=["k1"]),
    _entry(
        "ddf_kids_advent", "Die drei ??? Kids Adventskalender", split_from="ddf_kids"
    ),
    _entry("unrelated", "Bibi Blocksberg", spotify=["b1"]),
]


class TestSiblingSeries:
    def test_entries_sharing_an_artist_id_are_siblings(self):
        titles = sibling_series("lego_ninjago", {"spotify": ["art1"]}, CATALOG)
        assert titles == ["Lego Ninjago Hörbuch"]

    def test_the_series_itself_is_never_a_sibling(self):
        titles = sibling_series("lego_ninjago_hoerbuch", {"spotify": ["art1"]}, CATALOG)
        assert titles == ["Lego Ninjago"]

    def test_split_children_are_siblings_even_without_a_shared_artist_id(self):
        titles = sibling_series("ddf_kids", {"spotify": ["k1"]}, CATALOG)
        assert titles == ["Die drei ??? Kids Adventskalender"]

    def test_no_shared_artist_and_no_children_means_no_siblings(self):
        assert sibling_series("unrelated", {"spotify": ["b1"]}, CATALOG) == []

    def test_a_fresh_series_without_an_id_still_finds_siblings_by_artist(self):
        titles = sibling_series(None, {"spotify": ["art1"]}, CATALOG)
        assert titles == ["Lego Ninjago", "Lego Ninjago Hörbuch"]

    def test_titles_are_sorted_and_unique(self):
        catalog = CATALOG + [_entry("dup", "Lego Ninjago Hörbuch", apple=["a1"])]
        titles = sibling_series(
            "lego_ninjago", {"spotify": ["art1"], "apple_music": ["a1"]}, catalog
        )
        assert titles == ["Lego Ninjago Hörbuch"]


class TestBatchPromptSiblingBlock:
    def _prompt(self, sibling_titles):
        return build_batch_prompt(
            series_title="Lego Ninjago",
            pattern=None,
            progress_text="Progress: 0 included, 0 excluded.",
            rolling="",
            structural_hints=[],
            sibling_titles=sibling_titles,
            batch_num=1,
            n_batches=1,
            n_albums=1,
            albums_xml="<album/>",
        )

    def test_siblings_are_listed_before_the_batch(self):
        prompt = self._prompt(["Lego Ninjago Hörbuch"])
        assert "own catalog entries" in prompt
        assert "  - Lego Ninjago Hörbuch" in prompt
        assert "sub_series_bleed" in prompt
        assert prompt.index("Lego Ninjago Hörbuch") < prompt.index("Batch 1/1")

    def test_no_siblings_no_block(self):
        prompt = self._prompt([])
        assert "own catalog entries" not in prompt
