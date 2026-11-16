"""Rally and court context on top of any stroke model (CNN, LSTM or Random Forest).

The three models read one second of pose and shuttle around a hit. They do not know where
the hit sits in the rally, where on the court it was played from, or how long the shuttle
took to reach the other player, and those three facts separate the strokes the models mix
up most: a smash reaches the opponent in about half a second where a drop takes three
quarters, a lift hangs longer than a net shot, a stroke played at the net is not a clear,
and only the first hit of a rally is a serve.

`refine` multiplies each hit's class probabilities by how likely its context is under each
class and renormalises. The likelihoods are counted from the ShuttleSet annotations of the
training matches (scripts/fit_stroke_context.py writes context_table.json); the weight on
them is fitted on the validation matches (docs/results/strokes.md has the measured effect).
A hit with no usable context keeps the model's answer unchanged.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.schema import ClipRecord, is_doubles
from shuttlesense.timing import frames_at

TABLE_PATH = Path(__file__).with_name("context_table.json")

# Depth from the net, in meters, of the two zones the table knows. ShuttleSet marks the
# player's court area per stroke; its front row ends at the short service line and its back
# row starts about two thirds of the way to the baseline. The rear limit here is set deeper
# than that on purpose: a player in the band in between counts as neither.
FRONT_MAX_M = 2.0
REAR_MIN_M = 4.8

DEFAULTS: dict[str, Any] = {
    "enabled": True,
    # Exponent on the context likelihoods (0 = model only, 1 = full weight) and the lowest
    # share of the best class a context factor may push a class to. None: the values fitted
    # on the validation matches, stored in the table.
    "weight": None,
    "floor": None,
    "max_flight_s": 2.5,  # a longer wait for the next hit means a hit was missed: not used
    "position_window_frames": 3,  # frames either side of a hit to find the hitter's position
    "doubles_tables": False,  # the tables are counted from singles matches
}


@dataclass(frozen=True)
class Evidence:
    """What is known around one hit; None = unknown, and then it says nothing."""

    first_in_rally: bool | None = None
    flight_s: float | None = None  # time until the opponent's next hit
    hitter_zone: str | None = None  # "front" | "rear"
    receiver_zone: str | None = None  # where the opponent played the reply from


@lru_cache(maxsize=4)
def load_table(path: Path = TABLE_PATH) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def zone(depth_m: float | None) -> str | None:
    """Court zone of a player `depth_m` from the net."""
    if depth_m is None or not np.isfinite(depth_m):
        return None
    if depth_m < FRONT_MAX_M:
        return "front"
    return "rear" if depth_m > REAR_MIN_M else None


def likelihood(evidence: Evidence, table: dict[str, Any], classes: list[str]) -> np.ndarray:
    """P(evidence | class) per class, up to a constant; ones when nothing is known."""
    out = np.ones(len(classes))
    if evidence.first_in_rally is not None:
        key = "first" if evidence.first_in_rally else "later"
        out *= [table["rally_position"][key].get(c, 1.0) for c in classes]
    if evidence.flight_s is not None:
        edges = table["flight_edges_s"]
        b = int(np.searchsorted(edges, evidence.flight_s, side="right"))
        out *= [table["flight"][c][b] if c in table["flight"] else 1.0 for c in classes]
    for name, value in (
        ("hitter_zone", evidence.hitter_zone),
        ("receiver_zone", evidence.receiver_zone),
    ):
        if value is not None:
            out *= [table[name][value].get(c, 1.0) for c in classes]
    return out


def apply(
    probs: np.ndarray,
    evidence: Evidence,
    table: dict[str, Any],
    classes: list[str],
    weight: float = 0.5,
    floor: float = 0.005,
) -> np.ndarray:
    """The model's probabilities reweighted by the context, summing to 1."""
    like = likelihood(evidence, table, classes)
    top = like.max()
    if not np.isfinite(top) or top <= 0:
        return probs
    factor = np.maximum(like / top, floor) ** weight
    out = np.asarray(probs, dtype=float) * factor
    total = out.sum()
    return out / total if total > 0 else np.asarray(probs, dtype=float)


def _position(track: np.ndarray | None, frame: int, window: int) -> np.ndarray | None:
    """The court position nearest in time to `frame` within +-window frames."""
    if track is None:
        return None
    for d in sorted(range(-window, window + 1), key=abs):
        i = frame + d
        if 0 <= i < len(track) and np.isfinite(track[i]).all():
            return track[i]
    return None


def evidence_for(record: ClipRecord, config: dict[str, Any], cfg: dict[str, Any]) -> list[Evidence]:
    """One Evidence per hit of the record, in order."""
    from shuttlesense.hits.detector import same_rally
    from shuttlesense.tracking import track_arrays

    hits = record.hits
    if not hits:
        return []
    fps = record.fps or 30.0
    stages = config.get("stages", {})
    break_len = frames_at(stages.get("hits", {}).get("rally_break_frames", 30), fps)
    unobserved = set(config.get("_unobserved_frames", ()))
    _, visible = track_arrays(record)
    hidden = np.asarray(visible) <= 0

    positions: dict[str, np.ndarray] = {}
    net_y = None
    use_tables = cfg["doubles_tables"] or not is_doubles(record)
    use_zones = use_tables and record.court is not None
    if use_zones:
        from shuttlesense.analytics.positions import project_positions

        positions = project_positions(record, smooth=1)
        net_y = record.court.court_size_m[1] / 2
    window = frames_at(cfg["position_window_frames"], fps)

    def depth(hit) -> float | None:
        if net_y is None:
            return None
        p = _position(positions.get(hit.player_attr), hit.frame, window)
        return None if p is None else abs(float(p[1]) - net_y)

    out: list[Evidence] = []
    for k, hit in enumerate(hits):
        if k == 0:
            # A clip (or a live window) may open mid-rally: its first hit opens a rally only
            # if the shuttle was out of sight for a rally break before it. Otherwise unknown.
            first = True if not same_rally(hidden, 0, hit.frame, break_len, unobserved) else None
        else:
            first = not same_rally(hidden, hits[k - 1].frame, hit.frame, break_len, unobserved)
        flight = receiver = None
        nxt = hits[k + 1] if k + 1 < len(hits) else None
        if (
            nxt is not None
            and nxt.player != hit.player
            and same_rally(hidden, hit.frame, nxt.frame, break_len, unobserved)
        ):
            seconds = (nxt.frame - hit.frame) / fps
            if 0 < seconds <= cfg["max_flight_s"] and use_tables:
                flight = seconds
                receiver = zone(depth(nxt))
        out.append(
            Evidence(
                first_in_rally=first,
                flight_s=flight,
                hitter_zone=zone(depth(hit)) if use_zones else None,
                receiver_zone=receiver,
            )
        )
    return out


def refine(record: ClipRecord, config: dict[str, Any]) -> None:
    """Reweight every classified hit's probabilities by its context (in place)."""
    cfg = {**DEFAULTS, **(config.get("stages", {}).get("strokes", {}).get("context") or {})}
    if not cfg["enabled"] or not TABLE_PATH.exists():
        return
    table = load_table()
    weight = cfg["weight"] if cfg["weight"] is not None else table.get("weight", 0.5)
    floor = cfg["floor"] if cfg["floor"] is not None else table.get("floor", 0.005)
    for hit, evidence in zip(record.hits, evidence_for(record, config, cfg), strict=True):
        if not hit.class_probs:
            continue
        classes = list(hit.class_probs)
        probs = np.array([hit.class_probs[c] for c in classes], dtype=float)
        refined = apply(probs, evidence, table, classes, weight, floor)
        best = int(refined.argmax())
        hit.stroke = classes[best]
        hit.confidence = round(float(refined[best]), 4)
        hit.class_probs = {c: round(float(v), 4) for c, v in zip(classes, refined, strict=True)}
