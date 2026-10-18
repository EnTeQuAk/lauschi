"""The catalog file's JSON layout: indented, with each album on one line.

The tools and the web UI write the catalog, a person reads its diffs. A
dict or list that holds only plain values (an album, an era boundary,
a list of aliases) stays on one line, so a changed album is a one-line
diff. Everything else is indented by two spaces.
"""

import json

from lauschi_catalog.catalog.io import dump_catalog

CATALOG = {
    "series": [
        {
            "id": "dragons_die_9_welten",
            "title": "Dragons - Die 9 Welten",
            "aliases": ["Dragons", "Die neun Welten"],
            "episode_pattern": r"^[Ff]olge\s+(\d+)",
            "series_facts": {
                "era_boundaries": [{"year": 2023, "note": "Neue Sprecher"}],
                "known_gaps": [],
            },
            "providers": {
                "spotify": {
                    "artist_ids": ["29cfLkZSDejeI0vowGYWvg"],
                    "albums": [
                        {
                            "id": "s1",
                            "episode": 1,
                            "title": "Folge 1: Projekt Ikaris",
                            "barcode": "4029759184355",
                        },
                        {"id": "s2", "episode": None, "title": "Spezial: Drachenflöte"},
                    ],
                },
                "apple_music": {},
            },
        }
    ]
}

EXPECTED = """\
{
  "series": [
    {
      "id": "dragons_die_9_welten",
      "title": "Dragons - Die 9 Welten",
      "aliases": ["Dragons", "Die neun Welten"],
      "episode_pattern": "^[Ff]olge\\\\s+(\\\\d+)",
      "series_facts": {
        "era_boundaries": [
          {"year": 2023, "note": "Neue Sprecher"}
        ],
        "known_gaps": []
      },
      "providers": {
        "spotify": {
          "artist_ids": ["29cfLkZSDejeI0vowGYWvg"],
          "albums": [
            {"id": "s1", "episode": 1, "title": "Folge 1: Projekt Ikaris", "barcode": "4029759184355"},
            {"id": "s2", "episode": null, "title": "Spezial: Drachenflöte"}
          ]
        },
        "apple_music": {}
      }
    }
  ]
}
"""


def test_each_album_is_one_line_and_the_rest_is_indented() -> None:
    assert dump_catalog(CATALOG) == EXPECTED


def test_the_layout_reads_back_as_the_same_data() -> None:
    assert json.loads(dump_catalog(CATALOG)) == CATALOG
