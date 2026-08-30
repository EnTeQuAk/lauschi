"""The fixed evaluation sample.

Twelve series chosen to span every stratum the catalog audit found
matters, including the two largest series (which route to the chunked
audit), three split sub-series, and two music artists. Three of them
were corrected by hand in August 2026, so their ground truth is fresh.
The list is fixed so every model is scored on the same input.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class SampleSeries:
    id: str
    stratum: str


SAMPLE: tuple[SampleSeries, ...] = (
    SampleSeries("benjamin_bluemchen", "big_numbered"),
    SampleSeries("fuenf_freunde", "big_numbered"),
    SampleSeries("kira_kolumna", "mid_numbered"),
    SampleSeries("die_playmos", "mid_numbered"),
    SampleSeries("hexe_lilli", "mid_numbered"),
    SampleSeries("hanni_und_nanni_neue_abenteuer", "split_subseries"),
    SampleSeries("die_drei_fragezeichen_kids_adventskalender", "split_subseries"),
    SampleSeries("bibi_und_tina_kinofilm", "split_subseries"),
    SampleSeries("deine_freunde", "music"),
    SampleSeries("rolf_zuckowski", "music"),
    SampleSeries("bibi_blocksberg", "chunked"),
    SampleSeries("paw_patrol", "chunked"),
)

SAMPLE_IDS: tuple[str, ...] = tuple(s.id for s in SAMPLE)
