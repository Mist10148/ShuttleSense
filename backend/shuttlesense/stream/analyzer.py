"""Live analysis over a sliding window, reusing the offline stage functions (D20).

Every frame gets its court positions and speed straight away. Every `tick_every` frames the
offline hits, strokes, feedback, analytics and referee stages run on the frames since the
last finished rally (the window), and whatever is settled is committed to the session
record and sent as events:

- a hit once `hit_lag` frames have passed (hit suppression, the stroke window, feedback and
  hit speed all look that far ahead),
- a rally, its line call and the score once the referee closes the rally (the shuttle lay
  still for stationary_frames_end frames or was lost for lost_frames_end) and no hit came
  within lost_frames_end of that (offline would treat such a rest as noise).

So the provisional overlay is immediate while hits lag by about half a second and line calls
by the rest rule. Running the same functions on the whole clip gives the same hits, rallies
and calls (tests/test_stream.py checks this).
"""

from __future__ import annotations

import contextlib
import logging
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
    DecisionReason,
    Frame,
    GameService,
    Player,
    PlayerId,
    Players,
    PlayerSide,
    Rally,
    ScoreCorrection,
    ScorePair,
    Shuttle,
)
from shuttlesense.stage import StageContext, StageSkipped

log = logging.getLogger(__name__)

Event = dict[str, Any]
Classifier = Callable[[ClipRecord, int], None]  # (window record, window start frame)


def _dump(model: Any) -> Any:
    return model.model_dump(mode="json")


class RallyInPlay(RuntimeError):
    """A score change that has to wait until the open rally is decided."""


class MatchOver(RuntimeError):
    """A score change after the deciding rally: it would not change the result."""


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
        best_of: int = 1,
        first_server: PlayerSide | None = None,
        start_games: ScorePair | None = None,
        first_server_id: PlayerId | None = None,
        first_receiver_id: PlayerId | None = None,
        auto_change_ends: bool = False,
        classify: Classifier | None = None,
        tick_every: int = 5,
        max_window_frames: int = 900,
    ) -> None:
        self.config = config
        self.device = device
        self.classify = classify
        self.watch_stroke_guard = False
        self.watch_checkpoint = None
        self.tick_every = max(1, tick_every)
        self.max_window = max_window_frames
        from shuttlesense.referee import apply_rallies

        self.start = start_score or ScorePair()
        self.record = ClipRecord(
            clip_id=clip_id, mode="live", fps=fps, width=width, height=height, num_frames=0,
            court=court,
            score=apply_rallies([], self.start, best_of=best_of, first_server=first_server,
                                first_server_id=first_server_id,
                                first_receiver_id=first_receiver_id,
                                start_games=start_games,
                                auto_change_ends=auto_change_ends),
        )  # fmt: skip
        stages = config.get("stages", {})
        hits_cfg, analytics_cfg = stages.get("hits", {}), stages.get("analytics", {})
        self.min_gap = int(hits_cfg.get("min_frames_between_hits", 8))
        ahead = int(stages.get("strokes", {}).get("window_frames", 32)) // 2
        self.hit_lag = max(self.min_gap, ahead, 6, int(analytics_cfg.get("hit_speed_frames", 5)))
        self.hit_lag += 1
        # Offline ignores a rest followed by a hit within lost_frames_end (detector noise), so
        # a rally is final only once that long has passed and any such hit would be detected.
        lost = int(stages.get("referee", {}).get("lost_frames_end", 30))
        self.rally_settle = lost + self.hit_lag
        self.speed_smoothing = int(analytics_cfg.get("speed_smoothing", 3))
        self.min_keypoint_score = float(stages.get("pose", {}).get("min_keypoint_score", 0.3))
        self._recent_shuttle: deque[tuple[float, float]] = deque(maxlen=self.speed_smoothing + 2)
        self.anchor = 0  # first frame of the window
        self._since_tick = 0
        self._unobserved: set[int] = set()
        self.state = "between_rallies"
        self.open_rally_start: int | None = None
        self.overrides: list[Any] = []  # LineCallOverrideIn
        self.corrections: list[ScoreCorrection] = []
        self._strokes_key: tuple[int | None, int] = (None, 0)  # (rally start, hits) counted
        self._strokes = 0

    # Per frame ----------------------------------------------------------------

    def add_frame(self, shuttle: Shuttle, players: Players, *, tick: bool = True,
                  player_hold_safe: bool = True) -> list[Event]:
        """Add the next frame; with tick=False the windowed stages wait for a later frame."""
        i = len(self.record.frames)
        if not tick:
            self._unobserved.add(i)
        frame = Frame(frame=i, shuttle=shuttle, players=players, player_hold_safe=player_hold_safe)
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
        from shuttlesense.analytics.positions import (
            PLAYER_MARGIN_M,
            SHUTTLE_MARGIN_M,
            clamp_to_court,
            player_point,
        )
        from shuttlesense.analytics.speed import speeds_kmh
        from shuttlesense.court import image_to_court

        if self.record.court is None:
            return None, None
        h = np.asarray(self.record.court.homography)
        size = self.record.court.court_size_m

        def to_court(px: tuple[float, float], margin: float) -> tuple[float, float] | None:
            point = image_to_court(h, np.array([px]))[0]
            if not np.isfinite(point).all():
                return None
            point = clamp_to_court(point, size, margin)  # as offline (analytics/positions.py)
            return round(float(point[0]), 3), round(float(point[1]), 3)

        min_score = self.min_keypoint_score

        def player(p: Player | None) -> tuple[float, float] | None:
            return (to_court(player_point(p, min_score), PLAYER_MARGIN_M)
                    if p and p.court_position_valid else None)

        near, far = player(frame.players.near), player(frame.players.far)
        partners = {"near_2": player(frame.players.near_2), "far_2": player(frame.players.far_2)}
        s = frame.shuttle
        shuttle = to_court((s.x, s.y), SHUTTLE_MARGIN_M) if s is not None and s.visible else None
        self._recent_shuttle.append(shuttle if shuttle is not None else (np.nan, np.nan))
        kmh = speeds_kmh(np.array(self._recent_shuttle, dtype=float), self.record.fps or 30.0,
                         self.speed_smoothing)  # fmt: skip
        speed = None if not len(kmh) or np.isnan(kmh[-1]) else round(float(kmh[-1]), 1)
        return CourtPositions(near=near, far=far, shuttle=shuttle, **partners), speed

    def _frame_event(self, frame: Frame) -> Event:
        from shuttlesense.render.player_boxes import display_players

        render = self.config.get("stages", {}).get("render", {})
        seconds = float(render.get("player_box_hold_s", 0.6))
        return {
            "type": "frame",
            "frame": frame.frame,
            "time_s": round(frame.frame / (self.record.fps or 30.0), 3),
            "shuttle": _dump(frame.shuttle) if frame.shuttle else None,
            "players": _dump(frame.players),
            "display_players": display_players(self.record, frame.frame, seconds),
            "court": _dump(frame.court_positions) if frame.court_positions else None,
            "speed_kmh": frame.shuttle_speed_kmh,
            **self.rally_status(),
        }

    def rally_status(self) -> Event:
        start = self.open_rally_start
        return {
            "rally_state": self.state,
            "rally_start_frame": start,
            "strokes_in_rally": self._strokes_in_rally(start),
        }

    def _strokes_in_rally(self, start: int | None) -> int:
        """Committed hits since the open rally's start, recounted only when either changes."""
        key = (start, len(self.record.hits))
        if key != self._strokes_key:
            self._strokes_key = key
            self._strokes = (
                0 if start is None else sum(1 for h in self.record.hits if h.frame >= start)
            )
        return self._strokes

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

        config = {
            **self.config,
            "_unobserved_frames": {i - self.anchor for i in self._unobserved if i >= self.anchor},
        }
        ctx = StageContext(video_path=None, out_dir=None, config=config, device=self.device)
        hits.run(window, ctx)
        if window.hits:
            if self.classify is not None:
                self.classify(window, self.anchor)
            else:
                # No classifier installed: hits stay unlabelled, as offline.
                with contextlib.suppress(StageSkipped, FileNotFoundError, ImportError, OSError):
                    strokes.run(window, ctx)
                    self.record.stroke_model = window.stroke_model
            if self.watch_stroke_guard:
                from shuttlesense.stream.watch_strokes import guard_hits

                threshold = float(self.config.get("watch", {}).get("stroke_min_confidence", 0.5))
                guard_hits(
                    window,
                    self.watch_checkpoint,
                    threshold,
                    doubles=self.config.get("court") == "doubles",
                    unobserved=config["_unobserved_frames"],
                )
            feedback.run(window, ctx)
        analytics.run(window, ctx)
        try:
            referee.run(window, ctx)
        except StageSkipped:
            window.rallies, window.line_calls = [], []

    def _tick(self, now: int, *, final: bool) -> list[Event]:
        self.anchor = max(self.anchor, now + 1 - self.max_window)
        self._unobserved = {i for i in self._unobserved if i >= self.anchor}
        anchor = self.anchor
        if now < anchor:
            return []
        window = self._window(anchor, now)
        self._run_stages(window)
        events = self._commit_hits(window, anchor, now if final else now - self.hit_lag)
        last = len(window.frames) - 1
        open_start = None
        for r in window.rallies:
            start = self._rally_start(window, r, anchor)
            closed = r.end_frame < last and (final or last - r.end_frame >= self.rally_settle)
            if closed:
                events += self._commit_rally(window, r, anchor, start)
            elif final:
                events += self._commit_rally(window, r, anchor, start, open_rally=True)
            else:
                open_start = start
                break  # a later "rally" in the window is still part of this one
        events += self._set_state(open_start)
        return events

    def _rally_start(self, window: ClipRecord, r: Rally, anchor: int) -> int:
        """Global start frame of a window rally.

        A long rally the window slid into keeps the start already announced. Otherwise the
        referee starts a rally at window frame 0 when the shuttle is visible before its first
        hit (a clip that starts mid-rally); in a later window that is the shuttle still
        resting from the previous rally, so the rally starts at its serve.
        """
        if self.open_rally_start is not None and self.open_rally_start < anchor:
            return self.open_rally_start
        if r.start_frame != 0 or anchor == 0:
            return r.start_frame + anchor
        first = [h.frame for h in window.hits if r.start_frame <= h.frame <= r.end_frame]
        return (min(first) if first else 0) + anchor

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
        self, window: ClipRecord, r: Rally, anchor: int, start: int, *, open_rally: bool = False
    ) -> list[Event]:
        end = r.end_frame + anchor
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
        if not open_rally:
            events.append(self.coaching_event(rally.index))
        self.state = "between_rallies"
        return events

    def coaching_event(self, rally_index: int | None = None) -> Event:
        """Session notes so far and, after a rally, what happened in it (F21 between rallies).

        The same deterministic notes as the saved session (feedback/patterns.py), so the
        coach panel during play and the summary afterwards agree.
        """
        from shuttlesense.feedback import build_coaching

        coaching = build_coaching(self.record, self.config.get("stages", {}).get("feedback"))
        event: Event = {"type": "coaching", "coaching": _dump(coaching), "rally_summary": None}
        rally = next((r for r in self.record.rallies if r.index == rally_index), None)
        if rally is not None:
            event["rally_summary"] = self._rally_summary(rally)
        return event

    def _rally_summary(self, rally: Rally) -> Event:
        fps = self.record.fps or 30.0
        hits = [h for h in self.record.hits if h.rally_index == rally.index]
        speeds = [
            f.shuttle_speed_kmh
            for f in self.record.frames[rally.start_frame : rally.end_frame + 1]
            if f.shuttle_speed_kmh is not None
        ]
        call = next((c for c in self.record.line_calls if c.rally_index == rally.index), None)
        return {
            "index": rally.index,
            "game": rally.game,
            "duration_s": round((rally.end_frame - rally.start_frame) / fps, 1),
            "strokes": len(hits),
            "peak_speed_kmh": round(max(speeds), 1) if speeds else None,
            "winner": rally.winner,
            "call": call.effective_call if call else None,
            "margin_cm": call.margin_cm if call else None,
            "faults": [
                {
                    "hit_id": h.id,
                    "time_s": h.time_s,
                    "player": h.player,
                    "hitter": h.hitter,
                    "stroke": h.stroke,
                    "rule": f.rule,
                    "tip": f.tip,
                }  # fmt: skip
                for h in hits
                for f in h.feedback
                if not f.passed
            ],
        }

    def _set_state(self, open_start: int | None) -> list[Event]:
        if open_start is None:
            # The open rally vanished from the window (its hits were not confirmed).
            self.open_rally_start = None
            self.state = "between_rallies"
            return []
        if open_start == self.open_rally_start:
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

    def _latest_coaching_event(self) -> Event:
        """Refresh the visible summary after a referee changes a decision."""
        index = self.record.rallies[-1].index if self.record.rallies else None
        return self.coaching_event(index)

    def override(self, line_call_id: int, call: Call) -> list[Event]:
        from shuttlesense.referee import LineCallOverrideIn, after_the_match

        target = next((c for c in self.record.line_calls if c.id == line_call_id), None)
        if target is None:
            raise KeyError(line_call_id)
        if after_the_match(self.record, target.rally_index):
            raise MatchOver("the match is already won")
        # Kept as a log (the newest per rally applies) so Undo can restore an earlier call.
        self.overrides.append(
            LineCallOverrideIn(rally_index=target.rally_index, call=call, at=datetime.now(UTC))
        )
        self._rescore()
        return [
            {"type": "line_call", "line_call": _dump(target)},
            self._score_event(),
            self._latest_coaching_event(),
        ]

    def correct(
        self, rally_index: int, winner: PlayerSide | None, reason: DecisionReason | None = None
    ) -> list[Event]:
        """Set a rally's winner, or clear it (None) so the rally does not count; a cleared
        rally with reason "let" is replayed."""
        rally = next((r for r in self.record.rallies if r.index == rally_index), None)
        if rally is None:
            raise KeyError(rally_index)
        self._decide(ScoreCorrection(
            rally_index=rally_index, winner_before=rally.winner, winner_after=winner,
            at=datetime.now(UTC), reason=reason,
        ))  # fmt: skip
        return [self._score_event(), self._latest_coaching_event()]

    def _decide(self, correction: ScoreCorrection) -> None:
        """Log a correction and re-score; MatchOver (and nothing kept) when the match was
        already won and the decision would change nothing."""
        from shuttlesense.referee import changes_finished_match

        before = self.record.score.model_copy(deep=True) if self.record.score else None
        winners = {r.index: r.winner for r in self.record.rallies}
        self.corrections.append(correction)
        self._rescore()
        if changes_finished_match(before, self.record.score):
            self.corrections.pop()
            for r in self.record.rallies:
                r.winner = winners.get(r.index, r.winner)
            self._rescore()
            raise MatchOver("the match is already won")

    def award(self, winner: PlayerSide, reason: DecisionReason | None = None) -> list[Event]:
        """A point for a rally the referee layer missed, counted after the rallies so far.

        Raises RallyInPlay while a rally is open or still settling: that rally would be
        committed after the award with its own winner and count twice.
        """
        if self.state == "in_play":
            raise RallyInPlay("wait until the rally has ended")
        self._decide(ScoreCorrection(
            rally_index=len(self.record.rallies), winner_before=None, winner_after=winner,
            at=datetime.now(UTC), kind="award", frame=max(0, len(self.record.frames) - 1),
            reason=reason,
        ))  # fmt: skip
        return [self._score_event(), self._latest_coaching_event()]

    def concede(self, winner: PlayerSide) -> list[Event]:
        """The other side retired: `winner` wins the match after the rallies so far. A rally
        still open is committed after it and does not count."""
        if self.record.score is not None and self.record.score.match_winner is not None:
            raise MatchOver("the match is already won")
        self._decide(ScoreCorrection(
            rally_index=len(self.record.rallies), winner_before=None, winner_after=winner,
            at=datetime.now(UTC), kind="concede", frame=max(0, len(self.record.frames) - 1),
        ))  # fmt: skip
        return [self._score_event(), self._latest_coaching_event()]

    def change_ends(self) -> list[Event]:
        """The players changed ends now, after the rallies so far: the score goes with them.

        Raises RallyInPlay while a rally is open: its winner would be read at the wrong end.
        """
        if self.state == "in_play":
            raise RallyInPlay("wait until the rally has ended")
        self._decide(ScoreCorrection(
            rally_index=len(self.record.rallies), winner_before=None, winner_after=None,
            at=datetime.now(UTC), kind="ends", frame=max(0, len(self.record.frames) - 1),
        ))  # fmt: skip
        return [self._score_event(), self._latest_coaching_event()]

    def set_service(self, game: int, service: GameService | None) -> list[Event]:
        """Doubles: name who serves and receives first in `game` (D23), or forget it (None)."""
        kept = [g for g in self.record.score.game_service if g.game != game]
        self.record.score.game_service = sorted(
            [*kept, service] if service is not None else kept, key=lambda g: g.game
        )
        self._rescore()
        return [self._score_event()]

    def undo(self) -> list[Event]:
        """Take back the newest decision: a correction, an award or a line-call override."""
        from shuttlesense.referee import undo_last_decision

        before = {c.id: c.override for c in self.record.line_calls}
        remaining = undo_last_decision(self.record, self.start, self.overrides)
        if remaining is None:
            raise KeyError("nothing to undo")
        self.overrides = remaining
        self.corrections = list(self.record.score.corrections)
        self._rescore()
        # An undone override puts the automated call back; the app needs the call again.
        changed: list[Event] = [
            {"type": "line_call", "line_call": _dump(c)}
            for c in self.record.line_calls
            if before.get(c.id) != c.override
        ]
        return [*changed, self._score_event(), self._latest_coaching_event()]

    # End of session --------------------------------------------------------------

    def finalize(self) -> ClipRecord:
        """Commit everything still pending and fill the session-level fields."""
        from shuttlesense.analytics import build_summary
        from shuttlesense.feedback import build_coaching
        from shuttlesense.referee import build_events

        if self.record.frames:
            try:
                self._tick(len(self.record.frames) - 1, final=True)
            except Exception:  # noqa: BLE001 - a stage error must not lose the whole session
                log.exception("final live tick failed; saving the rallies committed so far")
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
