import pytest

from shuttlesense.referee import run
from shuttlesense.schema import CourtPositions, Hit
from shuttlesense.stage import StageContext
from shuttlesense.stream.synthetic import PlannedRally, synthetic_record


def serve_record(side, hitter, partner_x, landing):
    record, truth = synthetic_record((PlannedRally(side, 1, landing),), doubles=True)
    frame, _, _ = truth["hits"][0]
    record.hits = [
        Hit(
            id=0, frame=frame, time_s=frame / record.fps, player=side, hitter=hitter, stroke="serve"
        )
    ]
    y = 2 if side == "near" else 11
    pos = CourtPositions()
    setattr(pos, side, (3.6, y))
    setattr(pos, f"{side}_2", (partner_x, y) if partner_x is not None else None)
    record.frames[frame].court_positions = pos
    return run(record, StageContext(video_path=None, out_dir=None, config={"court": "doubles"}))


@pytest.mark.parametrize("side", ["near", "far"])
@pytest.mark.parametrize(
    ("slot", "partner_x", "outcome"),
    [
        (None, 1.0, "review"),
        (None, None, "review"),
        (None, 3.8, "server"),
        (1, 1.0, "server"),
        (2, 1.0, "receiver"),
    ],
)
def test_diagonal_depends_on_plausible_servers(side, slot, partner_x, outcome):
    receiver = "far" if side == "near" else "near"
    record = serve_record(
        side, f"{side}_{slot}" if slot else None, partner_x, (1, 10 if side == "near" else 3)
    )
    winner = {"server": side, "receiver": receiver, "review": None}[outcome]
    assert record.line_calls[0].uncertain == (winner is None)
    assert record.rallies[0].winner == winner
    assert (record.score.near, record.score.far) == (winner == "near", winner == "far")
