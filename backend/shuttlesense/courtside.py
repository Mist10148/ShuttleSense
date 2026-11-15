"""User-owned courtside state. Derived scoring and coaching never overwrite it."""

from datetime import UTC, datetime, timedelta

from shuttlesense.schema import ClipRecord, DecisionEntry, IntervalState, PracticeGoal, ScorePair


def sync_interval(record: ClipRecord, now: datetime | None = None) -> IntervalState | None:
    now = now or datetime.now(UTC)
    score = record.score
    if score is None or not score.interval or score.match_winner:
        record.interval_state = None
        return None
    key = f"{score.game}:{score.near}:{score.far}:{score.interval_s}"
    timer = record.interval_state
    if timer is None or timer.key != key:
        duration = score.interval_s or 60
        timer = IntervalState(key=key, duration_s=duration, remaining_s=duration)
        record.interval_state = timer
    if timer.status == "running" and timer.deadline:
        timer.remaining_s = max(0, (timer.deadline - now).total_seconds())
        if timer.remaining_s == 0:
            timer.status, timer.deadline = "complete", None
    return timer


def control_interval(record: ClipRecord, action: str, now: datetime | None = None) -> None:
    now = now or datetime.now(UTC)
    timer = sync_interval(record, now)
    if timer is None:
        raise ValueError("no interval is available")
    if (
        action == "start"
        and timer.status == "ready"
        or action == "resume"
        and timer.status == "paused"
    ):
        timer.status = "running"
        timer.deadline = now + timedelta(seconds=timer.remaining_s)
    elif action == "pause" and timer.status == "running":
        timer.status, timer.deadline = "paused", None
    elif action == "reset":
        timer.status, timer.deadline, timer.remaining_s = "ready", None, timer.duration_s
    elif action == "end":
        timer.status, timer.deadline = "ended", None
    else:
        raise ValueError("invalid interval action for the current state")


def set_goal(record: ClipRecord, goal: PracticeGoal, *, doubles: bool = False) -> None:
    goal = goal.model_copy(deep=True)
    goal.text = goal.text.strip()
    if not goal.text:
        raise ValueError("a practice goal needs text")
    if goal.player and "_" in goal.player and not doubles:
        raise ValueError("partner goals require a doubles session")
    if goal.rally_index is not None and not any(
        r.index == goal.rally_index for r in record.rallies
    ):
        raise ValueError("no such rally")
    if goal.moment is not None:
        if not 0 <= goal.moment.frame < record.num_frames:
            raise ValueError("goal moment is outside the recording")
        goal.moment.time_s = goal.moment.frame / record.fps
    record.practice_goals = [g for g in record.practice_goals if g.player != goal.player] + [goal]


def log_decision(record: ClipRecord, command: dict) -> None:
    score = record.score
    kind = command.get("type")
    if score is None or kind not in {"award", "correct", "override", "concede", "undo"}:
        return
    target = None
    if kind == "undo":
        target = next(
            (e for e in reversed(record.decision_log) if not e.undone and e.kind != "undo"), None
        )
        if target:
            target.undone = True
    rally_index = command.get("rally_index")
    if kind == "override":
        call = next((c for c in record.line_calls if c.id == command.get("line_call_id")), None)
        rally_index = call.rally_index if call else None
    rally = next((r for r in record.rallies if r.index == rally_index), None)
    frame = command.get("frame", rally.end_frame if rally else record.num_frames - 1)
    if frame is not None and not 0 <= frame < record.num_frames:
        frame = None
    detail = " ".join(
        str(v)
        for v in [kind, command.get("winner"), command.get("call"), command.get("reason")]
        if v is not None
    )
    game = rally.game if rally else (target.game if target else command.get("_game", score.game))
    result = ScorePair(near=score.near, far=score.far)
    offset = score.start_games.near + score.start_games.far if score.start_games else 0
    finished_index = game - 1 - offset
    if game < score.game and 0 <= finished_index < len(score.games):
        result = score.games[finished_index].model_copy()
    record.decision_log.append(
        DecisionEntry(
            id=len(record.decision_log) + 1,
            kind=kind,
            at=datetime.now(UTC),
            game=game,
            rally_index=rally_index,
            frame=frame,
            reason=command.get("reason"),
            detail=detail,
            score=result,
            undoes=target.id if target else None,
        )
    )
    sync_interval(record)


def courtside_snapshot(record: ClipRecord) -> dict:
    timer = sync_interval(record)
    return {
        "decision_log": [e.model_dump(mode="json") for e in record.decision_log],
        "interval_state": timer.model_dump(mode="json") if timer else None,
        "practice_goals": [g.model_dump(mode="json") for g in record.practice_goals],
    }


def coaching_recap(record: ClipRecord) -> dict:
    """Only measured counts and cited findings; completing a goal is self-reported."""
    return {
        "winner": record.score.match_winner if record.score else None,
        "games": [g.model_dump() for g in record.score.games] if record.score else [],
        "stroke_counts": record.summary.stroke_counts if record.summary else {},
        "top_fixes": [
            n.model_dump(mode="json")
            for n in record.coaching.session_notes
            if n.id in record.coaching.top_fixes
        ]
        if record.coaching
        else [],
        "practice_goals": [g.model_dump(mode="json") for g in record.practice_goals],
        "goal_evidence": (
            "Not enough evidence to measure practice-goal improvement. Completion is self-reported."
        ),
    }
