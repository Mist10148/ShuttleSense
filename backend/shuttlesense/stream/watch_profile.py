"""Opt-in per-frame wall-clock timings; model durations may overlap on CUDA."""

from __future__ import annotations

import threading
import time


class WatchFrameProfiler:
    """Wrap session-local operations only, without synchronizing GPU execution."""

    def __init__(self, session):
        self.values = {}
        self.lock = threading.Lock()
        model = getattr(session.perception, "perception", session.perception)
        self.candidates = getattr(model, "watch_candidates", None)
        for obj, name, label in (
            (model, "_shuttle", "shuttle_wall"),
            (model, "_players", "players_wall"),
            (getattr(model, "tracker", None), "update", "tracker_wall"),
            (getattr(model, "far_refiner", None), "refine", "far_refinement_wall"),
            (session, "_decode", "jpeg_decode_wall"),
            (session, "_record_frame", "record_wall"),
            (session.analyzer, "_tick", "analysis_tick_wall"),
        ):
            if obj is not None and callable(getattr(obj, name, None)):
                self._wrap(obj, name, label)
        self.previous = {}

    def attach_reader(self, reader):
        if callable(getattr(reader, "_normalize", None)):
            self._wrap(reader, "_normalize", "normalize_wall")

    def _wrap(self, obj, name, label):
        original = getattr(obj, name)

        def wrapped(*args, **kwargs):
            start = time.perf_counter()
            try:
                return original(*args, **kwargs)
            finally:
                with self.lock:
                    self.values[label] = (
                        self.values.get(label, 0.0) + (time.perf_counter() - start) * 1000
                    )

        setattr(obj, name, wrapped)

    def begin(self):
        with self.lock:
            self.values.clear()
        self.previous = dict(self.candidates.stats) if self.candidates is not None else {}

    def finish(self):
        with self.lock:
            result = {name: round(value, 3) for name, value in self.values.items()}
        if self.candidates is not None:
            stats = self.candidates.stats
            for key in ("detection_s", "selection_s", "pose_s"):
                result[key.removesuffix("_s") + "_wall"] = round(
                    (stats.get(key, 0) - self.previous.get(key, 0)) * 1000, 3
                )
            for key in ("people", "eligible", "excluded"):
                result[key] = stats.get(key, 0) - self.previous.get(key, 0)
        return result
