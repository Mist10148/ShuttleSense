"""One live session: decode frames, run perception and analysis, degrade, record, save.

The WebSocket route (api/live.py) feeds frames here one at a time from a worker thread.
When frames arrive faster than they can be processed the route hands over only the newest;
the older ones are still decoded and recorded (so the saved video and the frame timeline
stay complete) but get no perception, which the record shows as frames without a shuttle.
"""

from __future__ import annotations

import math
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.schema import (
    COURT_SIZE_M,
    ClipRecord,
    Court,
    GameService,
    Players,
    ScorePair,
    Shuttle,
)
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
    start_games: ScorePair | None = None  # games each side already won (joined mid-match)
    first_server: str | None = None
    first_server_id: str | None = None  # doubles: who serves and receives first
    first_receiver_id: str | None = None
    stroke_model: str | None = None  # cnn / lstm / rf (D28); None: the server's default


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
        resume_window_s: float = 60,
    ) -> None:
        self.id = session_id
        self.command_receipts: dict[tuple[str, int], tuple[str, list[dict]]] = {}
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
        from shuttlesense.config import with_court

        self.config = with_court(config, request.court)
        self.analyzer = StreamAnalyzer(
            clip_id=session_id, fps=self.fps, width=self.width, height=self.height, court=court,
            config=self.config, device=device, start_score=request.start_score,
            best_of=request.best_of, first_server=request.first_server,
            start_games=request.start_games, first_server_id=request.first_server_id,
            first_receiver_id=request.first_receiver_id,
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
        self._last_checked_drops = 0
        self._anchor_ts: float | None = None
        self._anchor_slot = 0
        self._max_padding = math.floor(resume_window_s * self.fps)
        self._last_image: np.ndarray | None = None
        self.last_capture_ts: float | None = None
        self.started_at = time.time()
        # Held while a worker thread processes frames or a decision; finish() takes it too,
        # so a shutdown never finalizes a record that a frame is still being added to.
        self.lock = threading.RLock()
        self._drop_lock = threading.Lock()  # drop() runs on the event loop as well as the worker

    # Frames -------------------------------------------------------------------

    def _decode(self, jpeg: bytes) -> np.ndarray | None:
        import cv2

        # A small file can declare a huge image; check the header before decoding it. Frames
        # are JPEG only, so anything without a JPEG frame header is refused undecoded.
        size = jpeg_size(jpeg)
        if size is None or size[0] * size[1] > MAX_PIXELS_FACTOR * self.width * self.height:
            return None
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

    def _prepare_frame(self, jpeg: bytes, ts: float) -> tuple[np.ndarray | None, list[Event]]:
        """Place a capture on the shared video and record timeline."""
        index = self.analyzer.record.num_frames
        elapsed_slots = 0.0 if self._anchor_ts is None else (ts - self._anchor_ts) * self.fps / 1000
        # Round to the nearest slot, keeping an exact halfway capture in the earlier slot.
        relative_limit = index - self._anchor_slot + self._max_padding
        oversized = elapsed_slots > relative_limit + 0.5 + 1e-9
        slot = (
            index + self._max_padding
            if oversized
            else self._anchor_slot + math.ceil(elapsed_slots - 0.5 - 1e-9)
        )
        if slot < index:
            self.last_capture_ts = ts
            self._count_drop()
            return None, []
        frame = self._decode(jpeg)
        if frame is None:
            return None, [{"type": "error", "code": "bad_frame", "detail": "could not decode JPEG"}]
        self.last_capture_ts = ts

        events: list[Event] = []
        if oversized:
            events.append({
                "type": "error", "code": "capture_gap",
                "detail": "A long camera gap was shortened in the recording.",
            })  # fmt: skip
        if self._anchor_ts is None or oversized:
            self._anchor_ts, self._anchor_slot = ts, slot
        if self._last_image is not None:
            for _ in range(index, slot):
                self._record_frame(self._last_image)
                self.analyzer.add_frame(Shuttle(), Players(), tick=False)
        return frame, events

    def _append_frame(self, frame: np.ndarray) -> None:
        self._record_frame(frame)
        self._last_image = frame

    def drop(self) -> None:
        """A frame the route had no room to queue."""
        self._count_drop()

    def _count_drop(self) -> None:
        with self._drop_lock:
            self.stats.dropped += 1

    def skip(self, jpeg: bytes, client_frame: int, ts: float) -> list[Event]:
        """A frame there is no time for: record it, keep the timeline, no perception."""
        frame, warnings = self._prepare_frame(jpeg, ts)
        if frame is None:
            return warnings
        self.stats.received += 1
        self.stats.skipped += 1
        self._skipped_since_check += 1
        self._append_frame(frame)
        # No windowed stages on skipped frames: they are the ones there is no time for.
        events = self.analyzer.add_frame(Shuttle(), Players(), tick=False)
        for e in events:
            if e["type"] == "frame":
                e.update(client_frame=client_frame, ts=ts, skipped=True)
        return warnings + events

    def process(self, jpeg: bytes, client_frame: int, ts: float, received: float) -> list[Event]:
        """Full perception on one frame. `received` is time.monotonic() at arrival."""
        frame, warnings = self._prepare_frame(jpeg, ts)
        if frame is None:
            return warnings
        self.stats.received += 1
        index = len(self.analyzer.record.frames)
        scale = float(self.live["scales"][self.level])
        shuttle, players = self._perceive(frame, index, scale)
        self._append_frame(frame)
        self._last_players = players
        perception = getattr(self.perception, "perception", self.perception)
        tracker = getattr(perception, "tracker", None)
        hold_safe = getattr(tracker, "view_valid", True)
        events = self.analyzer.add_frame(shuttle, players, player_hold_safe=hold_safe)
        latency = (time.monotonic() - received) * 1000
        self.stats.processed += 1
        self.stats.latencies_ms.append(latency)
        self._since_check.append(latency)
        for e in events:
            if e["type"] == "frame":
                e.update(client_frame=client_frame, ts=ts, latency_ms=round(latency, 1))
        return warnings + events + self._check_quality()

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
        with self._drop_lock:
            drops = self.stats.dropped - self._last_checked_drops
            self._last_checked_drops = self.stats.dropped
        missed = self._skipped_since_check + drops
        total = len(self._since_check) + missed
        drop = missed / total if total else 0.0
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
                else f"{drop:.0%} of frames skipped or dropped"
                if drop > self.live["max_drop_rate"]
                else "back within budget"
            )
            events.append({"type": "degraded", "level": self.level, "reason": reason,
                           "scale": self.live["scales"][self.level]})  # fmt: skip
        return events

    # Decisions ----------------------------------------------------------------

    def override(self, line_call_id: int, call: str) -> list[Event]:
        return self.analyzer.override(line_call_id, call)

    def correct(
        self, rally_index: int, winner: str | None, reason: str | None = None
    ) -> list[Event]:
        return self.analyzer.correct(rally_index, winner, reason)

    def award(self, winner: str, reason: str | None = None) -> list[Event]:
        return self.analyzer.award(winner, reason)

    def concede(self, winner: str) -> list[Event]:
        return self.analyzer.concede(winner)

    def undo(self) -> list[Event]:
        return self.analyzer.undo()

    def set_service(self, game: int, service: GameService | None) -> list[Event]:
        return self.analyzer.set_service(game, service)

    # End ------------------------------------------------------------------------

    def finish(self) -> ClipRecord:
        with self.lock:
            if self._writer is not None:
                self._writer.release()
                self._writer = None
            record = self.analyzer.finalize()
            from shuttlesense.courtside import sync_interval

            timer = sync_interval(record)
            if timer and timer.status == "running":
                timer.status, timer.deadline = "paused", None
            record.source_name = self.request.name or "live session"
            return record

    def close(self) -> None:
        """Drop the session without saving (nothing was received)."""
        with self.lock:
            if self._writer is not None:
                self._writer.release()
                self._writer = None


# A frame may be at most this many times the session's announced pixel count (2x per side).
MAX_PIXELS_FACTOR = 4


def jpeg_size(data: bytes) -> tuple[int, int] | None:
    """(width, height) from a JPEG's start-of-frame marker, or None when there is none."""
    if len(data) < 4 or data[0] != 0xFF or data[1] != 0xD8:
        return None
    i = 2
    while i + 4 <= len(data):
        if data[i] != 0xFF:
            return None
        marker = data[i + 1]
        if marker == 0xFF:  # fill byte
            i += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:  # markers without a length
            i += 2
            continue
        length = int.from_bytes(data[i + 2 : i + 4], "big")
        # SOF0..SOF15, except DHT (C4), JPG (C8) and DAC (CC)
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            if i + 9 > len(data):
                return None
            height = int.from_bytes(data[i + 5 : i + 7], "big")
            width = int.from_bytes(data[i + 7 : i + 9], "big")
            return width, height
        i += 2 + length
    return None
