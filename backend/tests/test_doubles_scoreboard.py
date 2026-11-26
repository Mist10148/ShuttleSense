from datetime import UTC, datetime, timedelta

import pytest
from test_doubles_server import serve_record

from shuttlesense.referee import run
from shuttlesense.referee.linecalls import LineCallOverrideIn, apply_overrides
from shuttlesense.referee.scoring import apply_corrections, undo_last_decision
from shuttlesense.schema import ClipRecord, Hit, ScoreCorrection, Shuttle
from shuttlesense.stage import StageContext
from shuttlesense.stream.synthetic import PlannedRally, synthetic_record


def test_doubles_review_replay_correction_and_undo():
    record = serve_record("far", None, 1.0, (1, 3))
    original = record.model_dump_json()
    at = datetime.now(UTC)
    override = LineCallOverrideIn(rally_index=0, call="in", at=at)
    correction = ScoreCorrection(
        rally_index=0, winner_before="far", winner_after="near", at=at + timedelta(seconds=1)
    )
    replay = ClipRecord.model_validate_json(original)
    for _ in range(2):
        apply_overrides(replay, [override])
        apply_corrections(replay, [])
        assert (replay.score.near, replay.score.far) == (0, 1)
    apply_corrections(replay, [correction])
    assert (replay.score.near, replay.score.far) == (1, 0)
    assert undo_last_decision(replay, overrides=[override]) == [override]
    assert (replay.score.near, replay.score.far) == (0, 1)
    assert undo_last_decision(replay, overrides=[override]) == []
    assert replay.rallies[0].winner is None
    assert (replay.score.near, replay.score.far) == (0, 0)


@pytest.mark.parametrize("lost", [True, False])
def test_net_tape_deflection_needs_a_landing(lost):
    record, truth = synthetic_record((PlannedRally("near", 1, (2, 10)),))
    frame, side, _ = truth["hits"][0]
    record.hits = [Hit(id=0, frame=frame, time_s=frame / record.fps, player=side, stroke="drop")]
    # Synthetic image of a shuttle glancing off the tape, then dropping on the far side.
    contact = truth["landings"][0] - 5
    for i, xy in enumerate([(638, 249), (640, 250), (641, 256)], contact - 1):
        record.frames[i].shuttle = Shuttle(x=xy[0], y=xy[1], visible=1)
    if lost:
        for f in record.frames[contact + 1 :]:
            f.shuttle = Shuttle()
    run(record, StageContext(video_path=None, out_dir=None, config={"court": "doubles"}))
    assert (record.score.near, record.score.far) == (0 if lost else 1, 0)
    assert record.rallies[0].winner == (None if lost else "near")
