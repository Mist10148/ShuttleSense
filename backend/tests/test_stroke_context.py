"""Rally and court context on top of the stroke models (strokes/context.py)."""

from __future__ import annotations

import numpy as np
import pytest

from shuttlesense.config import load_config
from shuttlesense.hits import run as hits_run
from shuttlesense.schema import STROKE_CLASSES
from shuttlesense.stage import StageContext
from shuttlesense.stream.synthetic import SHOT_FRAMES, synthetic_record
from shuttlesense.strokes import context
from shuttlesense.strokes.context import Evidence

CLASSES = list(STROKE_CLASSES)
TABLE = context.load_table()


def probs(**share: float) -> np.ndarray:
    """Probabilities with the named classes set and the rest sharing what is left."""
    rest = (1 - sum(share.values())) / (len(CLASSES) - len(share))
    return np.array([share.get(c, rest) for c in CLASSES])


def best(p: np.ndarray) -> str:
    return CLASSES[int(np.argmax(p))]


def test_the_shipped_table_covers_every_class() -> None:
    assert TABLE["classes"] == CLASSES
    assert 0 < TABLE["weight"] <= 1 and 0 < TABLE["floor"] < 0.1
    for c in CLASSES:
        assert len(TABLE["flight"][c]) == len(TABLE["flight_edges_s"]) + 1
        assert sum(TABLE["flight"][c]) == pytest.approx(1, abs=1e-3)
    # Only a serve opens a rally, and a serve never comes later.
    first = TABLE["rally_position"]["first"]
    assert first["serve"] > 0.99 and max(first[c] for c in CLASSES if c != "serve") < 0.01


def test_no_evidence_leaves_the_model_alone() -> None:
    p = probs(drop=0.5, smash=0.3)
    assert np.allclose(context.apply(p, Evidence(), TABLE, CLASSES), p)


def test_only_the_first_hit_of_a_rally_is_a_serve() -> None:
    p = probs(serve=0.6, net_shot=0.3)
    later = context.apply(p, Evidence(first_in_rally=False), TABLE, CLASSES)
    assert best(later) == "net_shot" and later[CLASSES.index("serve")] < 0.2
    opening = context.apply(
        probs(lift=0.5, serve=0.3), Evidence(first_in_rally=True), TABLE, CLASSES
    )
    assert best(opening) == "serve"
    assert opening.sum() == pytest.approx(1)


def test_flight_time_separates_a_smash_from_a_drop() -> None:
    unsure = probs(drop=0.45, smash=0.4)
    fast = context.apply(unsure, Evidence(first_in_rally=False, flight_s=0.42), TABLE, CLASSES)
    slow = context.apply(unsure, Evidence(first_in_rally=False, flight_s=0.85), TABLE, CLASSES)
    assert best(fast) == "smash" and best(slow) == "drop"
    # A confident model is not overturned by one piece of context.
    sure = probs(drop=0.9, smash=0.05)
    assert best(context.apply(sure, Evidence(flight_s=0.5), TABLE, CLASSES)) == "drop"


def test_court_zones_rule_out_strokes_played_from_the_wrong_place() -> None:
    assert context.zone(1.2) == "front" and context.zone(6.0) == "rear"
    assert context.zone(3.5) is None and context.zone(None) is None
    at_net = context.apply(
        probs(clear=0.5, lift=0.3), Evidence(hitter_zone="front"), TABLE, CLASSES
    )
    assert best(at_net) == "lift"
    at_back = context.apply(
        probs(net_shot=0.5, drop=0.3), Evidence(hitter_zone="rear"), TABLE, CLASSES
    )
    assert best(at_back) == "drop"


def _record_with_hits(**kwargs):
    record, truth = synthetic_record(**kwargs)
    hits_run(record, StageContext(video_path=None, out_dir=None, config=load_config()))
    assert [h.frame for h in record.hits] == [f for f, _, _ in truth["hits"]]
    return record, truth


def test_evidence_is_read_from_the_rally() -> None:
    record, truth = _record_with_hits()
    config = load_config()
    evidence = context.evidence_for(record, config, dict(context.DEFAULTS))
    starts = {min(f for f, _, _ in truth["hits"] if f >= s) for s in truth["starts"]}
    lasts = {max(f for f, _, _ in truth["hits"] if f < land) for land in truth["landings"]}
    for hit, e in zip(record.hits, evidence, strict=True):
        if hit.frame == min(starts):
            assert e.first_in_rally is None  # the clip opens on it: could be mid-rally
        else:
            assert e.first_in_rally is (hit.frame in starts)
        if hit.frame in lasts:
            assert e.flight_s is None  # nobody replied
        else:
            assert e.flight_s == pytest.approx(SHOT_FRAMES / record.fps)
        # The synthetic players stand 4.7 m from the net, at the edge of the rear zone.
        assert e.hitter_zone in (None, "rear")


def test_refine_rewrites_stroke_confidence_and_probabilities() -> None:
    record, truth = _record_with_hits()
    config = load_config()
    serves = {min(f for f, _, _ in truth["hits"] if f >= s) for s in truth["starts"]}
    for hit in record.hits:
        hit.class_probs = dict(zip(CLASSES, probs(serve=0.5, lift=0.3).round(4), strict=True))
        hit.stroke, hit.confidence = "serve", 0.5
    context.refine(record, config)
    for hit in record.hits[1:]:
        assert (hit.stroke == "serve") is (hit.frame in serves)
        assert hit.confidence == max(hit.class_probs.values())
        assert sum(hit.class_probs.values()) == pytest.approx(1, abs=1e-3)

    off = {**config, "stages": {**config["stages"]}}
    off["stages"]["strokes"] = {**off["stages"]["strokes"], "context": {"enabled": False}}
    before = [dict(h.class_probs) for h in record.hits]
    context.refine(record, off)
    assert [h.class_probs for h in record.hits] == before


def test_doubles_only_uses_the_rally_position() -> None:
    record, _ = _record_with_hits(doubles=True)
    evidence = context.evidence_for(record, load_config(), dict(context.DEFAULTS))
    assert all(e.flight_s is None and e.hitter_zone is None for e in evidence)
    assert any(e.first_in_rally is False for e in evidence)
