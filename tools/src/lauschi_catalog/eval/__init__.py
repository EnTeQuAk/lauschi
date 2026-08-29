"""Curator evaluation: score a model's curation against ground truth.

The pipeline has run for ten months without a number for "how good is
the curation". This package produces one, deterministically, so a
model swap is decided by measurement rather than by reading output.

Ground truth comes from three sources the repo already owns:

- the committed, human-reviewed curations (include/exclude truth);
- the web-verified canon audit verdicts (which episodes exist);
- the provider discographies themselves (what can be included at all).

Nothing here calls a model. The scorer is unit-tested on synthetic
curations before it judges a real one.
"""
