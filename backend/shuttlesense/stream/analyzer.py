"""Live analysis over a sliding window, reusing the offline stage functions (D20).

Every frame gets its court positions and speed straight away. Every `tick_every` frames the
offline hits, strokes, feedback, analytics and referee stages run on the frames since the
last finished rally (the window), and whatever is settled is committed to the session
record and sent as events:

- a hit once `hit_lag` frames have passed (hit suppression, the stroke window, feedback and
  hit speed all look that far ahead),
- a rally, its line call and the score once the referee closes the rally (the shuttle lay
  still for stationary_frames_end frames or was lost for lost_frames_end).

So the provisional overlay is immediate while hits lag by about half a second and line calls
by the rest rule. Running the same functions on the whole clip gives the same hits, rallies
and calls (tests/test_stream.py checks this).
"""

from __future__ import annotations

import contextlib
from collections import deque
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any

import numpy as np

from shuttlesense.schema import (
    Call,
    ClipRecord,
    Court,
    CourtPositions,
    Frame,
    Players,
    PlayerSide,
    Rally,
    Score,
    ScoreCorrection,
    ScorePair,
    Shuttle,
)
from shuttlesense.stage import StageContext, StageSkipped

Event = dict[str, Any]
Classifier = Callable[[ClipRecord, int], None]  # (window record, window start frame)


def _dump(model: Any) -> Any:
    return model.model_dump(mode="json")


class StreamAnalyzer:
    def __init__(
        self,
        *,
        clip_id: str,
        fps: float,
        width: int,
        height: int,
        court: Court | None,
        config: dict[str, Any],
        device: str = "cpu",
        start_score: ScorePair | None = None,
        classify: Classifier | None = None,
        tick_every: int = 5,
        max_window_frames: int = 900,
    ) -> None:
        self.config = config
        self.device = device
        self.classify = classify
        self.tick_every = max(1, tick_every)
        self.max_window = max_window_frames
        self.start = start_score or ScorePair()
        self.record = ClipRecord(
            clip_id=clip_id, mode="live", fps=fps, width=width, height=height, num_frames=0,
            court=court, score=Score(near=self.start.near, far=self.start.far),
        )  # fmt: skip
        stages = config.get("stages", {})
        hits_cfg, analytics_cfg = stages.get("hits", {}), stages.get("analytics", {})
        self.min_gap = int(hits_cfg.get("min_frames_between_hits", 8))
        ahead = int(stages.get("strokes", {}).get("window_frames", 32)) // 2
        self.hit_lag = max(self.min_gap, ahead, 6, int(analytics_cfg.get("hit_speed_frames", 5)))
        self.hit_lag += 1
        self.speed_smoothing = int(analytics_cfg.get("speed_smoothing", 3))
        self._recent_shuttle: deque[tuple[float, float]] = deque(maxlen=self.speed_smoothing + 2)
        self.anchor = 0  # first frame of the window
        self._since_tick = 0
        self.state = "between_rallies"
        self.open_rally_start: int | None = None
        self.overrides: list[Any] = []  # LineCallOverrideIn
        self.corrections: list[ScoreCorrection] = []

    # Per frame ----------------------------------------------------------------

    def add_frame(self, shuttle: Shuttle, players: Players, *, tick: bool = True) -> list[Event]:
        """Add the next frame; with tick=False the windowed stages wait for a later frame."""
        i = len(self.record.frames)
        frame = Frame(frame=i, shuttle=shuttle, players=players)
        frame.court_positions, frame.shuttle_speed_kmh = self._project(frame)
        frame.rally_state = self.state
        self.record.frames.append(frame)
        self.record.num_frames = i + 1
        events = [self._frame_event(frame)]
        self._since_tick += 1
        if tick and self._since_tick >= self.tick_every:
            self._since_tick = 0
            events += self._tick(i, final=False)
        return events

    def _project(self, frame: Frame) -> tuple[CourtPositions | None, float | None]:
        """Court positions and speed for one frame, from the same helpers as analytics."""
        from shuttlesense.analytics.positions import player_point
        from shuttlesense.analytics.speed import speeds_kmh
        from shuttlesense.court import image_to_court

        if self.record.court is None:
            return None, None
        h = np.asarray(self.record.court.homography)

        def to_court(px: tuple[float, float]) -> tuple[float, float] | None:
            point = image_to_court(h, np.array([px]))[0]
            return (
                (round(float(point[0]), 3), round(float(point[1]), 3))
                if np.isfinite(point).all()
                else None
            )

        near = frame.players.near and to_court(player_point(frame.players.near))
        far = frame.players.far and to_court(player_point(frame.players.far))
        s = frame.shuttle
        shuttle = to_court((s.x, s.y)) if s is not None and s.visible else None
        self._recent_shuttle.append(shuttle if shuttle is not None else (np.nan, np.nan))
        kmh = speeds_kmh(np.array(self._recent_shuttle, dtype=float), self.record.fps or 30.0,
                         self.speed_smoothing)  # fmt: skip
        speed = None if not len(kmh) or np.isnan(kmh[-1]) else round(float(kmh[-1]), 1)
        return CourtPositions(near=near or None, far=far or None, shuttle=shuttle), speed

    def _frame_event(self, frame: Frame) -> Event:
        start = self.open_rally_start
        strokes = sum(1 for h in self.record.hits if start is not None and h.frame >= start)
        return {
            "type": "frame",
            "frame": frame.frame,
            "time_s": round(frame.frame / (self.record.fps or 30.0), 3),
            "shuttle": _dump(frame.shuttle) if frame.shuttle else None,
            "players": _dump(frame.players),
            "court": _dump(frame.court_positions) if frame.court_positions else None,
            "speed_kmh": frame.shuttle_speed_kmh,
            "rally_state": self.state,
            "rally_start_frame": start,
            "strokes_in_rally": strokes,
        }

    # Window -------------------------------------------------------------------

    def _window(self, start: int, now: int) -> ClipRecord:
        frames = [
            f.model_copy(update={"frame": f.frame - start})
            for f in self.record.frames[start : now + 1]
        ]
        return self.record.model_copy(
            update={"frames": frames, "num_frames": len(frames), "hits": [], "rallies": [],
                    "line_calls": [], "rally_events": [], "score": None, "summary": None}
        )  # fmt: skip

    def _run_stages(self, window: ClipRecord) -> None:
        from shuttlesense import analytics, feedback, hits, referee, strokes

        ctx = StageContext(video_path=None, out_dir=None, config=self.config, device=self.device)
        hits.run(window, ctx)
        if window.hits:
            if self.classify is not None:
                self.classify(window, self.anchor)
            else:
                # No classifier installed: hits stay unlabelled, as offline.
                with contextlib.suppress(StageSkipped, FileNotFoundError, ImportError, OSError):
                    strokes.run(window, ctx)
            feedback.run(window, ctx)
        analytics.run(window, ctx)
        try:
            referee.run(window, ctx)
        except StageSkipped:
            window.rallies, window.line_calls = [], []

    def _tick(self, now: int, *, final: bool) -> list[Event]:
        self.anchor = max(self.anchor, now + 1 - self.max_window)
        anchor = self.anchor
        if now < anchor:
            return []
        window = self._window(anchor, now)
        self._run_stages(window)
        events = self._commit_hits(window, anchor, now if final else now - self.hit_lag)
        last = len(window.frames) - 1
        open_start = None
        for r in window.rallies:
            closed = r.end_frame < last
            if closed:
                events += self._commit_rally(window, r, anchor)
            elif final:
                events += self._commit_rally(window, r, anchor, open_rally=True)
            else:
                open_start = r.start_frame + anchor
        events += self._set_state(open_start)
        return events

    def _commit_hits(self, window: ClipRecord, anchor: int, limit: int) -> list[Event]:
        events = []
        fps = self.record.fps or 30.0
        for h in window.hits:
            g = h.frame + anchor
            if g > limit or any(abs(g - c.frame) < self.min_gap for c in self.record.hits):
                continue
            hit = h.model_copy(update={
                "id": len(self.record.hits), "frame": g, "time_s": round(g / fps, 3),
                "rally_index": None,
            })  # fmt: skip
            self.record.hits.append(hit)
            events.append({"type": "hit", "hit": _dump(hit)})
        self.record.hits.sort(key=lambda h: h.frame)
        return events

    def _commit_rally(
        self, window: ClipRecord, r: Rally, anchor: int, *, open_rally: bool = False
    ) -> list[Event]:
        start, end = r.start_frame + anchor, r.end_frame + anchor
        index = len(self.record.rallies)
        rally = Rally(index=index, start_frame=start, end_frame=end, landing=r.landing,
                      winner=None if open_rally else r.winner)  # fmt: skip
        hits_in = [h for h in self.record.hits if start <= h.frame <= end]
        for h in hits_in:
            h.rally_index = index
        rally.stroke_count = len(hits_in)
        self.record.rallies.append(rally)
        events: list[Event] = []
        call = next((c for c in window.line_calls if c.rally_index == r.index), None)
        if call is not None and not open_rally:
            frame = call.frame + anchor
            call = call.model_copy(update={
                "id": len(self.record.line_calls), "rally_index": index, "frame": frame,
                "time_s": round(frame / (self.record.fps or 30.0), 3),
            })  # fmt: skip
            self.record.line_calls.append(call)
            events.append({"type": "line_call", "line_call": _dump(call)})
        self._rescore()
        self.anchor = end + 1
        self.open_rally_start = None
        events.append({"type": "rally", "state": "between_rallies", "rally": _dump(rally)})
        events.append(self._score_event())
        self.state = "between_rallies"
        return events

    def _set_state(self, open_start: int | None) -> list[Event]:
        if open_start is None or open_start == self.open_rally_start:
            return []
        self.open_rally_start = open_start
        self.state = "in_play"
        return [{"type": "rally", "state": "in_play", "start_frame": open_start,
                 "index": len(self.record.rallies)}]  # fmt: skip

    # User decisions ------------------------------------------------------------

    def _rescore(self) -> None:
        from shuttlesense.referee import apply_corrections, apply_overrides

        apply_overrides(self.record, self.overrides)
        apply_corrections(self.record, self.corrections, self.start)

    def _score_event(self) -> Event:
        return {
            "type": "score",
            "score": _dump(self.record.score),
            "rallies": [_dump(r) for r in self.record.rallies],
        }

    def override(self, line_call_id: int, call: Call) -> list[Event]:
        from shuttlesense.referee import LineCallOverrideIn

        target = next((c for c in self.record.line_calls if c.id == line_call_id), None)
        if target is None:
            raise KeyError(line_call_id)
        self.overrides = [o for o in self.overrides if o.rally_index != target.rally_index]
        self.overrides.append(
            LineCallOverrideIn(rally_index=target.rally_index, call=call, at=datetime.now(UTC))
        )
        self._rescore()
        return [{"type": "line_call", "line_call": _dump(target)}, self._score_event()]

    def correct(self, rally_index: int, winner: PlayerSide) -> list[Event]:
        rally = next((r for r in self.record.rallies if r.index == rally_index), None)
        if rally is None:
            raise KeyError(rally_index)
        self.corrections.append(ScoreCorrection(
            rally_index=rally_index, winner_before=rally.winner, winner_after=winner,
            at=datetime.now(UTC),
        ))  # fmt: skip
        self._rescore()
        return [self._score_event()]

    # End of session --------------------------------------------------------------

    def finalize(self) -> ClipRecord:
        """Commit everything still pending and fill the session-level fields."""
        from shuttlesense.analytics import build_summary
        from shuttlesense.feedback import build_coaching
        from shuttlesense.referee import build_events

        if self.record.frames:
            self._tick(len(self.record.frames) - 1, final=True)
        record = self.record
        for f in record.frames:
            inside = any(r.start_frame <= f.frame <= r.end_frame for r in record.rallies)
            f.rally_state = "in_play" if inside else "between_rallies"
        record.summary = build_summary(record)
        record.coaching = build_coaching(record, self.config.get("stages", {}).get("feedback"))
        record.rally_events = build_events(record)
        return record


def planned_classifier(planned: dict[int, str | None], period: int | None = None) -> Classifier:
    """Fake-mode stroke classifier: the stroke the synthetic plan put at that frame.

    `period` is the length of the replayed clip when it loops.
    """
    from shuttlesense.schema import STROKE_CLASSES

    def classify(window: ClipRecord, anchor: int) -> None:
        for h in window.hits:
            g = h.frame + anchor
            g = g % period if period else g
            near = [f for f in planned if abs(f - g) <= 3]
            stroke = planned[near[0]] if near else None
            if stroke is None:
                continue
            h.stroke, h.confidence = stroke, 0.9
            h.class_probs = {c: (0.9 if c == stroke else 0.02) for c in STROKE_CLASSES}

    return classify
