"""One live session: decode frames, run perception and analysis, degrade, record, save.

The WebSocket route (api/live.py) feeds frames here one at a time from a worker thread.
When frames arrive faster than they can be processed the route hands over only the newest;
the older ones are still decoded and recorded (so the saved video and the frame timeline
stay complete) but get no perception, which the record shows as frames without a shuttle.
"""

from __future__ import annotations

import threading
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.schema import COURT_SIZE_M, ClipRecord, Court, Players, ScorePair, Shuttle
from shuttlesense.stream.analyzer import Event, StreamAnalyzer
from shuttlesense.stream.perception import Perception

# Defaults for the `live` section of configs/pipeline.yaml.
LIVE_DEFAULTS: dict[str, Any] = {
    "budget_ms": 300,  # p95 frame -> event target on the team GPU
    "tick_every": 5,  # frames between runs of the windowed stages
    "max_window_frames": 900,
    "background_frames": 30,  # TrackNet background median from the first frames
    "check_every": 30,  # processed frames between quality checks
    "max_drop_rate": 0.2,  # above this share of skipped frames, degrade
    "scales": [1.0, 0.75, 0.5],  # perception input scale per quality level
    "max_fps": 30,
    "target_height": 720,
    "max_queue_frames": 60,  # frames waiting beyond this are dropped unrecorded
}


@dataclass
class StartRequest:
    fps: float
    width: int
    height: int
    corners: list[tuple[float, float]] | None = None
    start_score: ScorePair | None = None
    court: str = "singles"
    name: str | None = None
    best_of: int = 1
    first_server: str | None = None


def normalized_size(width: int, height: int, target_height: int) -> tuple[int, int]:
    """Same rule as the io stage: at most target_height tall, even sizes."""
    scale = min(1.0, target_height / height) if height else 1.0
    w, h = round(width * scale), round(height * scale)
    return w - w % 2, h - h % 2


def _percentile(values: list[float], q: float) -> float:
    return float(np.percentile(values, q)) if values else 0.0


@dataclass
class LiveStats:
    received: int = 0
    processed: int = 0
    skipped: int = 0
    dropped: int = 0  # thinned to max_fps or over max_queue_frames: not recorded
    latencies_ms: deque[float] = field(default_factory=lambda: deque(maxlen=300))

    def summary(self) -> dict[str, float]:
        lat = list(self.latencies_ms)
        return {
            "received": self.received,
            "processed": self.processed,
            "skipped": self.skipped,
            "dropped": self.dropped,
            "p50_ms": round(_percentile(lat, 50), 1),
            "p95_ms": round(_percentile(lat, 95), 1),
        }


class LiveSession:
    def __init__(
        self,
        *,
        session_id: str,
        request: StartRequest,
        config: dict[str, Any],
        perception: Perception,
        court_corners: list[tuple[float, float]] | None,
        recording: Path | None,
        device: str = "cpu",
        classify=None,
    ) -> None:
        self.id = session_id
        self.request = request
        live = {**LIVE_DEFAULTS, **(config.get("live") or {})}
        self.live = live
        self.fps = min(float(request.fps), float(live["max_fps"]))
        self.width, self.height = normalized_size(
            request.width, request.height, int(live["target_height"])
        )
        self.perception = perception
        self.corners = court_corners
        court = None
        if court_corners:
            from shuttlesense.court import compute_homography

            # Same court size as the offline court stage, so live and upload agree.
            size = tuple(
                (config.get("stages", {}).get("court") or {}).get("court_size_m", COURT_SIZE_M)
            )
            court = Court(corners_px=tuple(court_corners), court_size_m=size,
                          homography=compute_homography(court_corners, size).tolist())  # fmt: skip
        stages = dict(config.get("stages", {}))
        referee_cfg = dict(stages.get("referee", {}))
        referee_cfg["line_call"] = {**(referee_cfg.get("line_call") or {}), "court": request.court}
        stages["referee"] = referee_cfg
        self.config = {**config, "stages": stages}
        self.analyzer = StreamAnalyzer(
            clip_id=session_id, fps=self.fps, width=self.width, height=self.height, court=court,
            config=self.config, device=device, start_score=request.start_score,
            best_of=request.best_of, first_server=request.first_server,
            classify=classify, tick_every=int(live["tick_every"]),
            max_window_frames=int(live["max_window_frames"]),
        )  # fmt: skip
        self.recording = recording
        self._writer = None
        self.level = 0
        self.stats = LiveStats()
        self._last_players = Players()
        self._since_check: list[float] = []
        self._skipped_since_check = 0
        self._next_ts: float | None = None
        self.last_capture_ts: float | None = None
        self.started_at = time.time()
        # Held while a worker thread processes frames or a decision; finish() takes it too,
        # so a shutdown never finalizes a record that a frame is still being added to.
        self.lock = threading.RLock()
        self._drop_lock = threading.Lock()  # drop() runs on the event loop, admit() on a worker

    # Frames -------------------------------------------------------------------

    def _decode(self, jpeg: bytes) -> np.ndarray | None:
        import cv2

        frame = cv2.imdecode(np.frombuffer(jpeg, dtype=np.uint8), cv2.IMREAD_COLOR)
        if frame is None:
            return None
        if frame.shape[1] != self.width or frame.shape[0] != self.height:
            frame = cv2.resize(frame, (self.width, self.height), interpolation=cv2.INTER_AREA)
        return frame

    def _record_frame(self, frame: np.ndarray) -> None:
        if self.recording is None:
            return
        if self._writer is None:
            import cv2

            self.recording.parent.mkdir(parents=True, exist_ok=True)
            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            self._writer = cv2.VideoWriter(
                str(self.recording), fourcc, self.fps, (self.width, self.height)
            )
            if not self._writer.isOpened():
                self._writer = None
                raise RuntimeError(f"cannot write the live recording to {self.recording}")
        self._writer.write(frame)

    def admit(self, ts: float) -> bool:
        """Thin a camera faster than max_fps down to it, by capture time (ms).

        The recording and every time in the record assume `self.fps`, so frames beyond that
        rate are dropped before they reach the timeline.
        """
        if self.request.fps <= self.fps:
            return True
        period = 1000.0 / self.fps
        if self._next_ts is not None and ts < self._next_ts - period / 4:
            self._count_drop()
            return False
        nxt = (self._next_ts if self._next_ts is not None else ts) + period
        self._next_ts = nxt if nxt > ts - period else ts + period  # resync after a gap
        return True

    def drop(self) -> None:
        """A frame the route had no room to queue."""
        self._count_drop()

    def _count_drop(self) -> None:
        with self._drop_lock:
            self.stats.dropped += 1

    def skip(self, jpeg: bytes, client_frame: int, ts: float) -> list[Event]:
        """A frame there is no time for: record it, keep the timeline, no perception."""
        if not self.admit(ts):
            return []
        self.stats.received += 1
        self.stats.skipped += 1
        self._skipped_since_check += 1
        frame = self._decode(jpeg)
        if frame is None:
            return []
        self._record_frame(frame)
        # No windowed stages on skipped frames: they are the ones there is no time for.
        events = self.analyzer.add_frame(Shuttle(), self._last_players, tick=False)
        for e in events:
            if e["type"] == "frame":
                e.update(client_frame=client_frame, ts=ts, skipped=True)
        return events

    def process(self, jpeg: bytes, client_frame: int, ts: float, received: float) -> list[Event]:
        """Full perception on one frame. `received` is time.monotonic() at arrival."""
        if not self.admit(ts):
            return []
        self.stats.received += 1
        frame = self._decode(jpeg)
        if frame is None:
            return [{"type": "error", "code": "bad_frame", "detail": "could not decode JPEG"}]
        self._record_frame(frame)
        index = len(self.analyzer.record.frames)
        scale = float(self.live["scales"][self.level])
        shuttle, players = self._perceive(frame, index, scale)
        self._last_players = players
        events = self.analyzer.add_frame(shuttle, players)
        latency = (time.monotonic() - received) * 1000
        self.stats.processed += 1
        self.stats.latencies_ms.append(latency)
        self._since_check.append(latency)
        for e in events:
            if e["type"] == "frame":
                e.update(client_frame=client_frame, ts=ts, latency_ms=round(latency, 1))
        return events + self._check_quality()

    def _perceive(self, frame: np.ndarray, index: int, scale: float) -> tuple[Shuttle, Players]:
        """Perception on a frame downscaled by `scale`; results come back in full-size pixels."""
        if scale >= 1.0:
            return self.perception(frame, index)
        import cv2

        small = cv2.resize(frame, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        return self.perception(small, index)

    def _check_quality(self) -> list[Event]:
        """Every check_every processed frames, step quality down or up and say so."""
        if len(self._since_check) < int(self.live["check_every"]):
            return []
        p95 = _percentile(self._since_check, 95)
        total = len(self._since_check) + self._skipped_since_check
        drop = self._skipped_since_check / total if total else 0.0
        self._since_check, self._skipped_since_check = [], 0
        budget = float(self.live["budget_ms"])
        old = self.level
        lowest = len(self.live["scales"]) - 1
        if (p95 > budget or drop > self.live["max_drop_rate"]) and self.level < lowest:
            self.level += 1
        elif p95 < budget / 2 and drop < 0.05 and self.level > 0:
            self.level -= 1
        events: list[Event] = [{"type": "stats", "level": self.level, "drop_rate": round(drop, 3),
                                **self.stats.summary()}]  # fmt: skip
        if self.level != old or drop > self.live["max_drop_rate"]:
            reason = (
                f"processing p95 {p95:.0f} ms over the {budget:.0f} ms budget"
                if p95 > budget
                else f"{drop:.0%} of frames skipped"
                if drop > self.live["max_drop_rate"]
                else "back within budget"
            )
            events.append({"type": "degraded", "level": self.level, "reason": reason,
                           "scale": self.live["scales"][self.level]})  # fmt: skip
        return events

    # Decisions ----------------------------------------------------------------

    def override(self, line_call_id: int, call: str) -> list[Event]:
        return self.analyzer.override(line_call_id, call)

    def correct(self, rally_index: int, winner: str | None) -> list[Event]:
        return self.analyzer.correct(rally_index, winner)

    def award(self, winner: str) -> list[Event]:
        return self.analyzer.award(winner)

    def undo(self) -> list[Event]:
        return self.analyzer.undo()

    # End ------------------------------------------------------------------------

    def finish(self) -> ClipRecord:
        with self.lock:
            if self._writer is not None:
                self._writer.release()
                self._writer = None
            record = self.analyzer.finalize()
            record.source_name = self.request.name or "live session"
            return record

    def close(self) -> None:
        """Drop the session without saving (nothing was received)."""
        with self.lock:
            if self._writer is not None:
                self._writer.release()
                self._writer = None
