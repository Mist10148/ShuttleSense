import numpy as np
import pytest

from shuttlesense.referee import run
from shuttlesense.referee.linecalls import DEFAULTS, make_line_call
from shuttlesense.schema import ClipRecord, Court, CourtPositions, Frame, Hit, Shuttle
from shuttlesense.stage import StageContext


def score_landing(x, y, side="near", court="singles", stroke="clear"):
    # Foreshortened camera: four pixels span 4 cm across and 36 cm lengthwise.
    h = np.diag([0.01, 0.09, 1])
    frames = []
    for i in range(80):
        fraction = min(i / 30, 1.0)
        start_y = 2 if side == "near" else 11
        frames.append(
            Frame(
                frame=i,
                shuttle=Shuttle(
                    x=100 * x + 180 * (1 - fraction),
                    y=(start_y + (y - start_y) * fraction) / 0.09,
                    visible=1,
                ),
                court_positions=CourtPositions(near=(3.5, 1), far=(3.5, 12)),
            )
        )
    record = ClipRecord(
        clip_id="court",
        fps=30,
        width=1280,
        height=720,
        num_frames=len(frames),
        court=Court(
            corners_px=((0, 0), (518, 0), (518, 13.4 / 0.09), (0, 13.4 / 0.09)),
            homography=h.tolist(),
        ),
        frames=frames,
        hits=[Hit(id=0, frame=0, time_s=0, player=side, stroke=stroke)],
    )
    return run(record, StageContext(video_path=None, out_dir=None, config={"court": court}))


@pytest.mark.parametrize("side", ["near", "far"])
@pytest.mark.parametrize(
    "x,depth,court,stroke,award",
    [
        (5.40, 10, "singles", "clear", "receiver"),
        (5.40, 10, "doubles", "clear", "hitter"),
        (1, 13.02, "doubles", "serve", "receiver"),
        (1, 13.02, "doubles", "clear", "hitter"),
        (1, 12.8, "doubles", "serve", None),
        (1, 11, "singles", "serve", "hitter"),
        (4, 11, "singles", "serve", "receiver"),
        (5.18, 10, "singles", "clear", None),
        (1, 7.0, "singles", "clear", None),
        (1, 13.1, "singles", "clear", None),
        (0.12, 10, "singles", "clear", "hitter"),
    ],
)
def test_landing_decides_at_most_one_point(side, x, depth, court, stroke, award):
    y = depth if side == "near" else 13.4 - depth
    record = score_landing(x, y, side, court, stroke)
    receiver = "far" if side == "near" else "near"
    winner = {"hitter": side, "receiver": receiver, None: None}[award]
    (rally,) = record.rallies
    (call,) = record.line_calls
    assert call.uncertain == (winner is None)
    assert rally.winner == winner
    assert (record.score.near, record.score.far) == (winner == "near", winner == "far")
    # Crossing the net in flight produced no intermediate rally or score.
    assert call.frame >= 29


def test_singular_projection_stays_pending():
    record = score_landing(1, 10)
    record.court.homography = np.zeros((3, 3)).tolist()
    call = make_line_call(record, record.rallies[0], 30, (1, 10), DEFAULTS)
    assert call.uncertain and call.confidence < 0.5


def test_tracking_disk_crossing_projective_horizon_stays_pending():
    record = score_landing(1, 10)
    # The landing projects to pixel (0, 0); its horizon is only two pixels away.
    h = np.array([[1, 0, 1], [0, 1, 10], [0.5, 0, 1]])
    record.court.homography = h.tolist()
    call = make_line_call(record, record.rallies[0], 30, (1, 10), DEFAULTS)
    assert call.uncertain and call.confidence < 0.5


def test_diagonal_tracking_error_can_cross_baseline():
    record = score_landing(1, 10)
    # Each image axis alone moves the landing 24 cm in depth. A diagonal
    # four-pixel displacement moves it 34 cm, enough to cross the baseline.
    record.court.homography = [[0.01, 0, 0], [0.06, 0.06, 0], [0, 0, 1]]
    call = make_line_call(record, record.rallies[0], 30, (2, 13.1), DEFAULTS)
    assert call.call == "in" and call.uncertain and call.confidence < 0.5
