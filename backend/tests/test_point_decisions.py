"""Known court decisions using synthetic flights through the recorded referee stage."""

from pathlib import Path

import pytest

from shuttlesense.config import load_config
from shuttlesense.referee import run
from shuttlesense.schema import CourtPositions, Hit, Shuttle
from shuttlesense.stage import StageContext
from shuttlesense.stream.synthetic import PlannedRally, synthetic_record
from shuttlesense.tracking import track_arrays
from shuttlesense.tracking.postprocess import write_tracking_csv
from shuttlesense.tracking.tracknet import run as track

# (court, stroke, server x, landing, evidence, expected near/far point or review)
CASES = [
    ("singles", "clear", None, (5.40, 10), "observed", "far"),
    ("doubles", "clear", None, (5.40, 10), "observed", "near"),
    ("doubles", "serve", 3.5, (1, 13), "observed", "far"),
    ("doubles", "clear", None, (1, 13), "observed", "near"),
    ("singles", "serve", 3.5, (1, 11), "observed", "near"),
    ("singles", "serve", None, (1, 11), "observed", None),
    ("singles", "serve", None, (1, 7.5), "observed", "far"),
    ("singles", "clear", None, (5.18, 10), "observed", None),
    ("singles", "clear", None, (-0.5, 6.72), "observed", None),
    ("singles", "clear", None, (1, 10), "sparse", None),
    ("singles", "clear", None, (1, 10), "inpaint", None),
    # A shot that never crosses the net lands in on the hitter's own half: the hitter loses.
    ("singles", "clear", None, (2.5, 4.0), "observed", "far"),
    ("doubles", "clear", None, (2.5, 4.0), "observed", "far"),
    # The side alleys are in for doubles rallies and out for singles.
    ("singles", "clear", None, (-0.25, 10), "observed", "far"),
    ("doubles", "clear", None, (-0.25, 10), "observed", "near"),
    ("doubles", "clear", None, (-0.9, 10), "observed", "far"),
    # Serves: doubles is short (long service line 0.76 m in) and wide; singles long and narrow.
    ("singles", "serve", 1.5, (4.0, 13.0), "observed", "near"),
    ("doubles", "serve", 1.5, (4.0, 13.0), "observed", "far"),
    ("doubles", "serve", 1.5, (4.0, 12.0), "observed", "near"),
    ("doubles", "serve", 1.5, (5.5, 10.0), "observed", "near"),
    ("singles", "serve", 1.5, (5.5, 10.0), "observed", "far"),
    # A doubles server nobody located could have served to either box: no point.
    ("doubles", "serve", None, (4.0, 12.0), "observed", None),
    # Wrong diagonal: a serve into the box straight ahead is a fault.
    ("singles", "serve", 1.5, (1.0, 10.0), "observed", "far"),
]


def decide(court, stroke, server_x, landing, evidence, tmp_path):
    record, truth = synthetic_record((PlannedRally("near", 1, landing),))
    ctx = StageContext(video_path=None, out_dir=tmp_path, config={**load_config(), "court": court})
    frame, side, _ = truth["hits"][0]
    record.hits = [Hit(id=0, frame=frame, time_s=frame / record.fps, player=side, stroke=stroke)]
    if server_x is not None:
        # In doubles the partner stands behind the server, on the same side of the centre.
        partner = (server_x, 1) if court == "doubles" else None
        record.frames[frame].court_positions = CourtPositions(near=(server_x, 2), near_2=partner)
    rest = truth["landings"][0]
    if evidence == "sparse":
        for i in range(rest, len(record.frames)):
            if (i - rest) % 3:
                record.frames[i].shuttle = Shuttle()
    if evidence == "inpaint":
        xy, visible = track_arrays(record)
        sources = [
            "net" if i < rest or not (i - rest) % 3 else "inpaint" for i in range(len(visible))
        ]
        path = tmp_path / "estimated.csv"
        write_tracking_csv(path, xy, visible, sources)
        ctx.config["stages"]["tracking"]["precomputed_csv"] = str(path)
        track(record, ctx)
    run(record, ctx)
    assert len(record.rallies) == 1
    return record.rallies[0].winner


@pytest.mark.parametrize("court,stroke,server_x,landing,evidence,expected", CASES)
def test_point_decision(court, stroke, server_x, landing, evidence, expected, tmp_path: Path):
    assert decide(court, stroke, server_x, landing, evidence, tmp_path) == expected
