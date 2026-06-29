"""Eval cases for catalog curation.

Each case presents a small batch of albums from a real series and
checks that the model makes the correct include/exclude decisions.
Albums are taken from actual curation runs with known-good outcomes.

Ground truth was established from production curations as of 2026-06.
When curation rules change, update expected decisions here.

Run:
    uv run python -m tests.evals.run_evals
    uv run python -m tests.evals.run_evals --cases benjamin_sub_series
"""

from __future__ import annotations

from pydantic_evals import Case, Dataset
from pydantic_evals.evaluators import LLMJudge

from lauschi_catalog.catalog.curate_ops import BatchResult

from .evaluators import ConfidenceMinimum, DecisionsCorrect, ExcludeReasonsCorrect, NotesPresent
from .task import BatchInput


def _judge(rubric: str) -> LLMJudge:
    return LLMJudge(rubric=rubric, include_input=True)


# -- Benjamin Blümchen: sub-series bleed + compilation + regular episodes ----

_BENJAMIN_SUB_SERIES = Case[BatchInput, BatchResult](
    name="benjamin_sub_series",
    inputs=BatchInput(
        series_title="Benjamin Blümchen",
        content_type="hoerspiel",
        episode_pattern="^Folge (\\d+):",
        discography_span_years=49,
        albums=[
            {
                "provider": "apple_music",
                "id": "1139339828",
                "title": "Folge 1: als Wetterelefant",
                "release_date": "1977-01-01",
                "total_tracks": 3,
                "album_type": "",
                "tracks": [
                    {"name": "Folge 1: als Wetterelefant, Teil 1", "duration_ms": 1500000, "track_number": 1},
                    {"name": "Folge 1: als Wetterelefant, Teil 2", "duration_ms": 1400000, "track_number": 2},
                    {"name": "Folge 1: als Wetterelefant, Teil 3", "duration_ms": 600000, "track_number": 3},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1069063539",
                "title": "Benjamin Blümchen Gute-Nacht-Geschichten - Folge 13: Die Traumfeekönigin Karolila",
                "release_date": "2010-09-10",
                "total_tracks": 9,
                "album_type": "",
                "tracks": [
                    {"name": "Schlafliedchen", "duration_ms": 90000, "track_number": 1},
                    {"name": "Kapitel 1", "duration_ms": 180000, "track_number": 2},
                    {"name": "Kapitel 2", "duration_ms": 200000, "track_number": 3},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1038224754",
                "title": "Benjamin Blümchen Liederzoo: 1x1 und ABC",
                "release_date": "2004",
                "total_tracks": 16,
                "album_type": "",
                "tracks": [
                    {"name": "1+1=2, das kann ich schon", "duration_ms": 180000, "track_number": 1},
                    {"name": "ABC, das Alphabet", "duration_ms": 195000, "track_number": 2},
                ],
            },
            {
                "provider": "apple_music",
                "id": "550922630",
                "title": "30 Jahre - Feier mit Törööö!",
                "release_date": "2007",
                "total_tracks": 78,
                "album_type": "",
                "tracks": [
                    {"name": "Folge 75: Der geheimnisvolle Brief, Teil 1", "duration_ms": 900000, "track_number": 1},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1139324907",
                "title": "Folge 2: rettet den Zoo",
                "release_date": "1977-01-01",
                "total_tracks": 3,
                "album_type": "",
                "tracks": [
                    {"name": "Folge 2: rettet den Zoo, Teil 1", "duration_ms": 1400000, "track_number": 1},
                ],
            },
        ],
    ),
    metadata={
        ("apple_music", "1139339828"): {
            "include": True,
            "min_confidence": "high",
        },
        ("apple_music", "1069063539"): {
            "include": False,
            "exclude_reason": "sub_series_bleed",
            "min_confidence": "high",
        },
        ("apple_music", "1038224754"): {
            "include": False,
            "exclude_reason": ["wrong_content_type", "kinderlieder_compilation"],
            "min_confidence": "high",
        },
        ("apple_music", "550922630"): {
            "include": False,
            "exclude_reason": "compilation",
            "min_confidence": "high",
        },
        ("apple_music", "1139324907"): {
            "include": True,
            "min_confidence": "high",
        },
    },
    evaluators=(
        DecisionsCorrect(),
        ExcludeReasonsCorrect(),
        ConfidenceMinimum(),
        NotesPresent(),
    ),
)


# -- Benjamin Blümchen: Sonderedition + movie tie-in + music single ----------

_BENJAMIN_EDGE_CASES = Case[BatchInput, BatchResult](
    name="benjamin_edge_cases",
    inputs=BatchInput(
        series_title="Benjamin Blümchen",
        content_type="hoerspiel",
        episode_pattern="^Folge (\\d+):",
        discography_span_years=49,
        albums=[
            {
                "provider": "apple_music",
                "id": "1069138151",
                "title": "Benjamin Blümchen als Apotheker (Sonderedition)",
                "release_date": "2005",
                "total_tracks": 4,
                "album_type": "",
                "tracks": [
                    {"name": "als Apotheker, Teil 1", "duration_ms": 900000, "track_number": 1},
                    {"name": "als Apotheker, Teil 2", "duration_ms": 850000, "track_number": 2},
                    {"name": "als Apotheker, Teil 3", "duration_ms": 800000, "track_number": 3},
                    {"name": "Lied: Benjamin, der Elefant", "duration_ms": 120000, "track_number": 4},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1840617912",
                "title": "Die Jahresuhr (Benjamins Version) - Single",
                "release_date": "2025-09-26",
                "total_tracks": 1,
                "album_type": "single",
                "tracks": [
                    {"name": "Die Jahresuhr (Benjamins Version)", "duration_ms": 195000, "track_number": 1},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1069156880",
                "title": "Einsteiger-Collection (Benjamin Blümchen als Wetterelefant & Benjamin Blümchen rettet den Zoo)",
                "release_date": "1977",
                "total_tracks": 6,
                "album_type": "",
                "tracks": [
                    {"name": "als Wetterelefant, Teil 1 (gekürzt)", "duration_ms": 600000, "track_number": 1},
                    {"name": "als Wetterelefant, Teil 2 (gekürzt)", "duration_ms": 550000, "track_number": 2},
                    {"name": "als Wetterelefant, Teil 3 (gekürzt)", "duration_ms": 300000, "track_number": 3},
                    {"name": "rettet den Zoo, Teil 1 (gekürzt)", "duration_ms": 600000, "track_number": 4},
                    {"name": "rettet den Zoo, Teil 2 (gekürzt)", "duration_ms": 550000, "track_number": 5},
                    {"name": "rettet den Zoo, Teil 3 (gekürzt)", "duration_ms": 300000, "track_number": 6},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1139284022",
                "title": "Folge 100: Ottos neue Freundin - Teil 1",
                "release_date": "2007-03-30",
                "total_tracks": 52,
                "album_type": "",
                "tracks": [
                    {"name": "Folge 100: Ottos neue Freundin, Kapitel 1", "duration_ms": 120000, "track_number": 1},
                ],
            },
        ],
    ),
    metadata={
        ("apple_music", "1069138151"): {
            "include": True,
        },
        ("apple_music", "1840617912"): {
            "include": False,
            "exclude_reason": "music_single",
            "min_confidence": "high",
        },
        ("apple_music", "1069156880"): {
            "include": False,
            "exclude_reason": "compilation",
            "min_confidence": "high",
        },
        ("apple_music", "1139284022"): {
            "include": True,
            "min_confidence": "medium",
        },
    },
    evaluators=(
        DecisionsCorrect(),
        ExcludeReasonsCorrect(),
        ConfidenceMinimum(),
        NotesPresent(),
    ),
)


# -- Pumuckl: cross-era + audiobook vs hörspiel + kinderlieder ---------------

_PUMUCKL_MIXED = Case[BatchInput, BatchResult](
    name="pumuckl_mixed_content",
    inputs=BatchInput(
        series_title="Pumuckl",
        content_type="hoerspiel",
        episode_pattern=["^(\\d+):", "^Folge (\\d+):"],
        discography_span_years=44,
        albums=[
            {
                "provider": "apple_music",
                "id": "1720424550",
                "title": "01: Koboldsgesetz (Neue Geschichten vom Pumuckl)",
                "release_date": "2023-12-15",
                "total_tracks": 17,
                "album_type": "",
                "tracks": [
                    {"name": "01: Koboldsgesetz, Teil 1", "duration_ms": 900000, "track_number": 1},
                    {"name": "01: Koboldsgesetz, Teil 2", "duration_ms": 850000, "track_number": 2},
                ],
            },
            {
                "provider": "spotify",
                "id": "1cOFQWQW6BHrLbSiuQfsdO",
                "title": "01: Spuk in der Werkstatt (Das Original aus dem Fernsehen)",
                "release_date": "1982-01-08",
                "total_tracks": 17,
                "album_type": "album",
                "tracks": [
                    {"name": "Spuk in der Werkstatt, Teil 1", "duration_ms": 900000, "track_number": 1},
                ],
            },
            {
                "provider": "spotify",
                "id": "6GPEsKop8ENzW3pJUduDGN",
                "title": "Pumuckl (Abenteuergeschichten)",
                "release_date": "2019-11-25",
                "total_tracks": 40,
                "album_type": "album",
                "tracks": [
                    {"name": "Teil 01", "duration_ms": 200000, "track_number": 1},
                    {"name": "Teil 02", "duration_ms": 210000, "track_number": 2},
                    {"name": "Teil 03", "duration_ms": 195000, "track_number": 3},
                    {"name": "Teil 40", "duration_ms": 180000, "track_number": 40},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1736038177",
                "title": "Pumuckl tanzt!",
                "release_date": "1996",
                "total_tracks": 16,
                "album_type": "",
                "tracks": [
                    {"name": "Pumuckl-Polonaise", "duration_ms": 180000, "track_number": 1},
                    {"name": "Pumuckl Rock'n'Roll", "duration_ms": 195000, "track_number": 2},
                    {"name": "Tanz den Pumuckl", "duration_ms": 170000, "track_number": 3},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1880740586",
                "title": "Frühling & Ostern mit Pumuckl",
                "release_date": "2026-02-27",
                "total_tracks": 128,
                "album_type": "",
                "tracks": [
                    {"name": "01: Spuk in der Werkstatt, Teil 1", "duration_ms": 900000, "track_number": 1},
                ],
            },
        ],
    ),
    metadata={
        ("apple_music", "1720424550"): {
            "include": True,
            "min_confidence": "high",
        },
        ("spotify", "1cOFQWQW6BHrLbSiuQfsdO"): {
            "include": True,
            "min_confidence": "high",
        },
        ("spotify", "6GPEsKop8ENzW3pJUduDGN"): {
            "include": False,
            "exclude_reason": "wrong_content_type",
            "min_confidence": "high",
        },
        ("apple_music", "1736038177"): {
            "include": False,
            "exclude_reason": "kinderlieder_compilation",
            "min_confidence": "high",
        },
        ("apple_music", "1880740586"): {
            "include": False,
            "exclude_reason": "compilation",
            "min_confidence": "high",
        },
    },
    evaluators=(
        DecisionsCorrect(),
        ExcludeReasonsCorrect(),
        ConfidenceMinimum(),
        NotesPresent(),
        _judge(
            "The agent should correctly identify that both episode 1 albums "
            "(Neue Geschichten 2023 + Original 1982) are valid Hörspiel "
            "episodes from different production eras, and include both. "
            "The audiobook (40 'Teil' tracks, 125 min, single story) should "
            "be excluded as wrong_content_type. The Kinderlieder album "
            "(song-length tracks, dance titles) should be excluded."
        ),
    ),
)


# -- Bibi Blocksberg: Kinofilm hörspiel vs soundtrack + duplicates -----------

_BIBI_KINOFILM = Case[BatchInput, BatchResult](
    name="bibi_kinofilm_vs_soundtrack",
    inputs=BatchInput(
        series_title="Bibi Blocksberg",
        content_type="hoerspiel",
        episode_pattern=["^Folge (\\d+)(?![-\\d])"],
        discography_span_years=46,
        albums=[
            {
                "provider": "apple_music",
                "id": "1144142594",
                "title": "Folge 100: Die große Hexenparty",
                "release_date": "2010-01-01",
                "total_tracks": 50,
                "album_type": "",
                "tracks": [
                    {"name": "Folge 100: Die große Hexenparty, Kapitel 1", "duration_ms": 90000, "track_number": 1},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1851429423",
                "title": "Bibi Blocksberg: Das große Hexentreffen (Das Original-Hörspiel zum Kinofilm)",
                "release_date": "2025-12-12",
                "total_tracks": 42,
                "album_type": "",
                "tracks": [
                    {"name": "Kapitel 1: Der Traum", "duration_ms": 120000, "track_number": 1},
                    {"name": "Kapitel 2: Auf nach Blockula", "duration_ms": 150000, "track_number": 2},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1827953733",
                "title": "Bibi Blocksberg: Das große Hexentreffen (Der Original-Soundtrack zum Kinofilm)",
                "release_date": "2025-12-12",
                "total_tracks": 18,
                "album_type": "",
                "tracks": [
                    {"name": "Die Hexen kommen", "duration_ms": 210000, "track_number": 1},
                    {"name": "Bibi's Lied", "duration_ms": 195000, "track_number": 2},
                    {"name": "Die Hexen kommen (Karaoke)", "duration_ms": 210000, "track_number": 3},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1801200242",
                "title": "Bibi Blocksberg Titellied aus den 80ern - Single",
                "release_date": "1980",
                "total_tracks": 1,
                "album_type": "single",
                "tracks": [
                    {"name": "Bibi Blocksberg Titellied", "duration_ms": 216000, "track_number": 1},
                ],
            },
        ],
    ),
    metadata={
        ("apple_music", "1144142594"): {
            "include": True,
            "min_confidence": "medium",
        },
        ("apple_music", "1851429423"): {
            "include": True,
        },
        ("apple_music", "1827953733"): {
            "include": False,
            "exclude_reason": "wrong_content_type",
            "min_confidence": "high",
        },
        ("apple_music", "1801200242"): {
            "include": False,
            "exclude_reason": "music_single",
            "min_confidence": "high",
        },
    },
    evaluators=(
        DecisionsCorrect(),
        ExcludeReasonsCorrect(),
        ConfidenceMinimum(),
        NotesPresent(),
        _judge(
            "The critical test: the Kinofilm Hörspiel (Original-Hörspiel "
            "zum Kinofilm, 42 tracks, chapter structure) should be included "
            "as a valid Hörspiel. The Kinofilm Soundtrack (Original-Soundtrack "
            "zum Kinofilm, 18 tracks with songs and karaoke) should be "
            "excluded as wrong_content_type. Both have very similar titles "
            "and the same release date. The model must distinguish Hörspiel "
            "from Soundtrack based on production signals."
        ),
    ),
)


# -- Die drei ??? Kids: Mini-Fall sub-series bleed with Folge N: prefix ------

_DDF_KIDS_MINI_FALL = Case[BatchInput, BatchResult](
    name="ddf_kids_mini_fall",
    inputs=BatchInput(
        series_title="Die drei ??? Kids",
        content_type="hoerspiel",
        episode_pattern=["^(\\d{3})/", "^Folge (\\d+):"],
        discography_span_years=17,
        albums=[
            {
                "provider": "apple_music",
                "id": "1092525638",
                "title": "Folge 1: Panik im Paradies",
                "release_date": "2009-03-13",
                "total_tracks": 8,
                "album_type": "",
                "tracks": [
                    {"name": "Folge 1: Panik im Paradies, Kapitel 1", "duration_ms": 300000, "track_number": 1},
                ],
            },
            {
                "provider": "spotify",
                "id": "5mQg8r5ivI0IX5bTV57KyN",
                "title": "001/Panik im Paradies",
                "release_date": "2009-03-13",
                "total_tracks": 25,
                "album_type": "album",
                "tracks": [
                    {"name": "001/Panik im Paradies - Teil 01", "duration_ms": 120000, "track_number": 1},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1752881332",
                "title": "Folge 2: Mini-Fall/Die Räuberjagd",
                "release_date": "2023-06-23",
                "total_tracks": 6,
                "album_type": "",
                "tracks": [
                    {"name": "Mini-Fall: Die Räuberjagd, Teil 1", "duration_ms": 600000, "track_number": 1},
                    {"name": "Mini-Fall: Die Räuberjagd, Teil 2", "duration_ms": 550000, "track_number": 2},
                ],
            },
            {
                "provider": "spotify",
                "id": "5VGU97jdV50FJ8GgGI9qcf",
                "title": "Grusel-Fälle",
                "release_date": "2025-10-03",
                "total_tracks": 369,
                "album_type": "album",
                "tracks": [
                    {"name": "94 - Falsche Vampire - Inhaltsangabe", "duration_ms": 40320, "track_number": 1},
                    {"name": "Die drei ??? Kids Titelsong", "duration_ms": 66792, "track_number": 2},
                    {"name": "94 - Falsche Vampire - Teil 01", "duration_ms": 183253, "track_number": 3},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1849207129",
                "title": "Folge 101: Geistermusik",
                "release_date": "2025-12-05",
                "total_tracks": 8,
                "album_type": "",
                "tracks": [
                    {"name": "Folge 101: Geistermusik, Kapitel 1", "duration_ms": 280000, "track_number": 1},
                ],
            },
        ],
    ),
    metadata={
        ("apple_music", "1092525638"): {
            "include": True,
            "min_confidence": "high",
        },
        ("spotify", "5mQg8r5ivI0IX5bTV57KyN"): {
            "include": True,
            "min_confidence": "high",
        },
        ("apple_music", "1752881332"): {
            "include": False,
            "exclude_reason": "sub_series_bleed",
            "min_confidence": "high",
        },
        ("spotify", "5VGU97jdV50FJ8GgGI9qcf"): {
            "include": False,
            "exclude_reason": "compilation",
            "min_confidence": "high",
        },
        ("apple_music", "1849207129"): {
            "include": True,
            "min_confidence": "high",
        },
    },
    evaluators=(
        DecisionsCorrect(),
        ExcludeReasonsCorrect(),
        ConfidenceMinimum(),
        NotesPresent(),
        _judge(
            "The 'Folge 2: Mini-Fall/Die Räuberjagd' is the hardest case. "
            "The title starts with 'Folge 2:' which matches the episode "
            "pattern, but 'Mini-Fall' in the title indicates this is a "
            "sub-series with its own numbering that collides with the main "
            "series. It should be excluded as sub_series_bleed. The model "
            "needs to recognize the Mini-Fall branding as a sub-series "
            "indicator despite the Folge N: prefix."
        ),
    ),
)


# -- Hui Buh: format variant (Kopfhörer-Hörspiel binaural remix) --------------

_HUI_BUH_FORMAT_VARIANT = Case[BatchInput, BatchResult](
    name="hui_buh_format_variant",
    inputs=BatchInput(
        series_title="Hui Buh (neue Welt)",
        content_type="hoerspiel",
        episode_pattern=["^(\\d+)/", "^Folge (\\d+):"],
        discography_span_years=18,
        albums=[
            {
                "provider": "spotify",
                "id": "6HdhtheEVHFC955BpUEEri",
                "title": "01/Der verfluchte Geheimgang",
                "release_date": "2008-01-18",
                "total_tracks": 40,
                "album_type": "album",
                "tracks": [
                    {"name": "01 - Der verfluchte Geheimgang - Teil 01", "duration_ms": 110533, "track_number": 1},
                    {"name": "01 - Der verfluchte Geheimgang - Teil 02", "duration_ms": 112426, "track_number": 2},
                    {"name": "01 - Der verfluchte Geheimgang - Teil 03", "duration_ms": 111480, "track_number": 3},
                ],
            },
            {
                "provider": "spotify",
                "id": "6xK1T3x0PgZrvpKiENf48W",
                "title": "Folge 37: Die magische Karte",
                "release_date": "2023-02-24",
                "total_tracks": 29,
                "album_type": "album",
                "tracks": [
                    {"name": "37 - Die magische Karte - Inhaltsangabe", "duration_ms": 50813, "track_number": 1},
                    {"name": "37 - Die magische Karte - Titelmelodie", "duration_ms": 60760, "track_number": 2},
                    {"name": "37 - Die magische Karte - Teil 01", "duration_ms": 182106, "track_number": 3},
                ],
            },
            {
                "provider": "spotify",
                "id": "0RleVfMyttZoqg7A0f6anm",
                "title": "Folge 37: Die magische Karte (Kopfhörer-Hörspiel)",
                "release_date": "2023-06-16",
                "total_tracks": 31,
                "album_type": "album",
                "tracks": [
                    {"name": "37 - Die magische Karte - Inhaltsangabe", "duration_ms": 51866, "track_number": 1},
                    {"name": "37 - Die magische Karte - Kopfhörer auf! (Intro)", "duration_ms": 192333, "track_number": 2},
                    {"name": "37 - Die magische Karte - Titelmelodie", "duration_ms": 60613, "track_number": 3},
                    {"name": "37 - Die magische Karte - Teil 01", "duration_ms": 181320, "track_number": 4},
                ],
            },
        ],
    ),
    metadata={
        ("spotify", "6HdhtheEVHFC955BpUEEri"): {
            "include": True,
            "min_confidence": "high",
        },
        ("spotify", "6xK1T3x0PgZrvpKiENf48W"): {
            "include": True,
            "min_confidence": "high",
        },
        ("spotify", "0RleVfMyttZoqg7A0f6anm"): {
            "include": False,
            "exclude_reason": "format_variant",
            "min_confidence": "high",
        },
    },
    evaluators=(
        DecisionsCorrect(),
        ExcludeReasonsCorrect(),
        ConfidenceMinimum(),
        NotesPresent(),
        _judge(
            "The critical test: 'Folge 37: Die magische Karte (Kopfhörer-Hörspiel)' "
            "is a binaural remix of the standard stereo episode. Same script, same "
            "voice cast, different audio mix for headphone listening. It should be "
            "excluded as format_variant because the standard version is already "
            "included. The '(Kopfhörer-Hörspiel)' suffix, the extra 'Kopfhörer "
            "auf! (Intro)' track, and the slightly different track count (31 vs 29) "
            "are the distinguishing signals."
        ),
    ),
)


# -- Liliane Susewind: different_series + audiobook content type ---------------

_LILIANE_DIFFERENT_SERIES = Case[BatchInput, BatchResult](
    name="liliane_different_series",
    inputs=BatchInput(
        series_title="Liliane Susewind",
        content_type="audiobook",
        episode_pattern=None,
        discography_span_years=16,
        albums=[
            {
                "provider": "spotify",
                "id": "3a4aDBaZ12ldy2dQT8sM2a",
                "title": "Drei Waschbären sind keiner zu viel [Liliane Susewind (Ungekürzte Lesung mit Musik)]",
                "release_date": "2018-12-12",
                "total_tracks": 20,
                "album_type": "album",
                "tracks": [
                    {"name": "Kapitel 1 - Liliane Susewind - Drei Waschbären sind keiner zu viel", "duration_ms": 186185, "track_number": 1},
                    {"name": "Kapitel 2 - Liliane Susewind - Drei Waschbären sind keiner zu viel", "duration_ms": 188504, "track_number": 2},
                    {"name": "Kapitel 3 - Liliane Susewind - Drei Waschbären sind keiner zu viel", "duration_ms": 185223, "track_number": 3},
                ],
            },
            {
                "provider": "spotify",
                "id": "53Eow0zxQ5WrkaXlQMd7Rt",
                "title": "24 Tiere suchen ein Zuhause. Das Adventskalender-Hörbuch [Liliane Susewind, Band 16 (Ungekürzte Lesung)]",
                "release_date": "2022-09-01",
                "total_tracks": 24,
                "album_type": "album",
                "tracks": [
                    {"name": "1.Dezember", "duration_ms": 461386, "track_number": 1},
                    {"name": "2. Dezember", "duration_ms": 255010, "track_number": 2},
                    {"name": "3. Dezember", "duration_ms": 276180, "track_number": 3},
                ],
            },
            {
                "provider": "spotify",
                "id": "5dK1plArQ3SNapHRe3aPA7",
                "title": "Alea Aquarius 1. Der Ruf des Wassers",
                "release_date": "2015-07-17",
                "total_tracks": 91,
                "album_type": "album",
                "tracks": [
                    {"name": "Kapitel 1 & Kapitel 2.1 - Alea Aquarius 1. Der Ruf des Wassers", "duration_ms": 188593, "track_number": 1},
                    {"name": "Kapitel 2.2 - Alea Aquarius 1. Der Ruf des Wassers", "duration_ms": 205800, "track_number": 2},
                    {"name": "Kapitel 2.3 & Kapitel 3.1 - Alea Aquarius 1. Der Ruf des Wassers", "duration_ms": 189440, "track_number": 3},
                ],
            },
            {
                "provider": "spotify",
                "id": "6k6f03BlGSbvlWmWVa8I4k",
                "title": "Hummelbi [Eine Fee ist keine Elfe (Gekürzte Lesung)]",
                "release_date": "2010",
                "total_tracks": 51,
                "album_type": "album",
                "tracks": [
                    {"name": "Kapitel 1 - Hummelbi - Eine Fee ist keine Elfe", "duration_ms": 206934, "track_number": 1},
                    {"name": "Kapitel 2 - Hummelbi - Eine Fee ist keine Elfe", "duration_ms": 181349, "track_number": 2},
                    {"name": "Kapitel 3 - Hummelbi - Eine Fee ist keine Elfe", "duration_ms": 185956, "track_number": 3},
                ],
            },
        ],
    ),
    metadata={
        ("spotify", "3a4aDBaZ12ldy2dQT8sM2a"): {
            "include": True,
            "min_confidence": "high",
        },
        ("spotify", "53Eow0zxQ5WrkaXlQMd7Rt"): {
            "include": True,
            "min_confidence": "high",
        },
        ("spotify", "5dK1plArQ3SNapHRe3aPA7"): {
            "include": False,
            "exclude_reason": "different_series",
            "min_confidence": "high",
        },
        ("spotify", "6k6f03BlGSbvlWmWVa8I4k"): {
            "include": False,
            "exclude_reason": "different_series",
            "min_confidence": "high",
        },
    },
    evaluators=(
        DecisionsCorrect(),
        ExcludeReasonsCorrect(),
        ConfidenceMinimum(),
        NotesPresent(),
        _judge(
            "The agent is curating the audiobook series 'Liliane Susewind'. "
            "The two included albums have 'Liliane Susewind' in their titles. "
            "The two excluded albums are different book series by the same "
            "author (Tanya Stewner) that share the Spotify artist page: "
            "'Alea Aquarius' (mermaid fantasy) and 'Hummelbi' (fairy story). "
            "Both should be excluded as different_series. Note that "
            "'Alea Aquarius' has no 'Liliane Susewind' anywhere in its title "
            "or track names, and 'Hummelbi' similarly has no connection to "
            "Liliane Susewind beyond sharing the author."
        ),
    ),
)


# -- Was Ist Was: Doppelfolge format (two topics per episode, NOT compilations) -

_WAS_IST_WAS_DOPPELFOLGE = Case[BatchInput, BatchResult](
    name="was_ist_was_doppelfolge",
    inputs=BatchInput(
        series_title="Was Ist Was",
        content_type="hoerspiel",
        episode_pattern=None,
        discography_span_years=14,
        albums=[
            {
                "provider": "spotify",
                "id": "5Kn4ViQaubj4PcmovgN1BN",
                "title": "07: Roboter & Androiden / Supercomputer",
                "release_date": "2015-10-09",
                "total_tracks": 18,
                "album_type": "album",
                "tracks": [
                    {"name": "Roboter & Androiden - Teil 01", "duration_ms": 172106, "track_number": 1},
                    {"name": "Roboter & Androiden - Teil 02", "duration_ms": 208120, "track_number": 2},
                    {"name": "Roboter & Androiden - Teil 03", "duration_ms": 198786, "track_number": 3},
                    {"name": "Supercomputer - Teil 01", "duration_ms": 154066, "track_number": 10},
                    {"name": "Supercomputer - Teil 02", "duration_ms": 202186, "track_number": 11},
                ],
            },
            {
                "provider": "apple_music",
                "id": "1687665295",
                "title": "07: Roboter & Androiden / Supercomputer",
                "release_date": "2014-10-10",
                "total_tracks": 34,
                "album_type": "",
                "tracks": [
                    {"name": "Roboter & Androiden - Teil 01", "duration_ms": 172107, "track_number": 1},
                    {"name": "Roboter & Androiden - Teil 02", "duration_ms": 77547, "track_number": 2},
                    {"name": "Roboter & Androiden - Teil 03", "duration_ms": 130573, "track_number": 3},
                ],
            },
            {
                "provider": "spotify",
                "id": "0meVjgdE176PTwtQ015z1v",
                "title": "04: Leben der Ritter / Mächtige Burgen",
                "release_date": "2012",
                "total_tracks": 16,
                "album_type": "album",
                "tracks": [
                    {"name": "Leben der Ritter - Teil 01", "duration_ms": 168906, "track_number": 1},
                    {"name": "Leben der Ritter - Teil 02", "duration_ms": 214093, "track_number": 2},
                    {"name": "Mächtige Burgen - Teil 01", "duration_ms": 167360, "track_number": 9},
                    {"name": "Mächtige Burgen - Teil 02", "duration_ms": 194133, "track_number": 10},
                ],
            },
        ],
    ),
    metadata={
        ("spotify", "5Kn4ViQaubj4PcmovgN1BN"): {
            "include": True,
            "min_confidence": "high",
        },
        ("apple_music", "1687665295"): {
            "include": True,
            "min_confidence": "high",
        },
        ("spotify", "0meVjgdE176PTwtQ015z1v"): {
            "include": True,
            "min_confidence": "high",
        },
    },
    evaluators=(
        DecisionsCorrect(),
        ExcludeReasonsCorrect(),
        ConfidenceMinimum(),
        NotesPresent(),
        _judge(
            "All three albums are standard Was Ist Was Doppelfolge episodes. "
            "Each episode covers two topics, titled 'Topic A / Topic B'. "
            "The '/' separates topics within ONE episode, not multiple "
            "episodes bundled together. Track names confirm this: each "
            "topic has its own sequential 'Teil' tracks within the album. "
            "This is the standard format for the entire series. "
            "All three MUST be included. Excluding any as 'compilation' "
            "is a false positive."
        ),
    ),
)


# ── Dataset ──────────────────────────────────────────────────────────────────

EVAL_CASES = [
    _BENJAMIN_SUB_SERIES,
    _BENJAMIN_EDGE_CASES,
    _PUMUCKL_MIXED,
    _BIBI_KINOFILM,
    _DDF_KIDS_MINI_FALL,
    _HUI_BUH_FORMAT_VARIANT,
    _LILIANE_DIFFERENT_SERIES,
    _WAS_IST_WAS_DOPPELFOLGE,
]


def build_dataset(names: list[str] | None = None) -> Dataset[BatchInput, BatchResult]:
    """Build the eval dataset, optionally filtering by case name."""
    cases = EVAL_CASES
    if names:
        cases = [c for c in EVAL_CASES if c.name in names]
    return Dataset[BatchInput, BatchResult](
        name="catalog_curation_batch",
        cases=cases,
    )
