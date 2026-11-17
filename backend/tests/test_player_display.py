"""Display holds must not turn missing player measurements into data."""

import numpy as np

from shuttlesense.court import compute_homography
from shuttlesense.render.player_boxes import display_players
from shuttlesense.schema import ClipRecord, Court, Frame, Player, Players, Shuttle
from shuttlesense.stream.analyzer import StreamAnalyzer


def test_hold_expires_and_stops_at_unsafe_view():
    player = Player(bbox=(10, 20, 30, 40), score=0.9)
    record = ClipRecord(
        clip_id="x",
        fps=10,
        width=100,
        height=100,
        num_frames=8,
        frames=[Frame(frame=i) for i in range(8)],
    )
    record.frames[0].players.near = player
    assert display_players(record, 0)["near"]["held"] is False
    assert display_players(record, 3)["near"] == {"bbox": [10, 20, 30, 40], "held": True}
    assert display_players(record, 6)["near"]["held"] is True
    assert display_players(record, 7) == {}
    record.frames[2].player_hold_safe = False
    assert display_players(record, 2) == {}
    assert display_players(record, 3) == {}
    assert record.frames[1].players.near is None


def test_live_event_exposes_hold_without_filling_analysis_players():
    analyzer = StreamAnalyzer(clip_id="x", fps=10, width=100, height=100, court=None, config={})
    player = Player(bbox=(10, 20, 30, 40), score=0.9)
    analyzer.add_frame(Shuttle(), Players(near=player))
    event = analyzer.add_frame(Shuttle(), Players())[0]
    assert event["players"]["near"] is None
    assert event["display_players"]["near"]["held"] is True
    assert analyzer.record.frames[-1].players.near is None
    event = analyzer.add_frame(Shuttle(), Players(), player_hold_safe=False)[0]
    assert event["display_players"] == {}


def test_rendered_hold_is_faded_and_expires():
    from shuttlesense.render.overlays import RenderState, draw_boxes

    player = Player(bbox=(30, 30, 20, 30), score=0.9)
    record = ClipRecord(
        clip_id="x",
        fps=10,
        width=100,
        height=100,
        num_frames=8,
        frames=[Frame(frame=i) for i in range(8)],
    )
    record.frames[0].players.near = player
    current = np.zeros((100, 100, 3), dtype=np.uint8)
    held = current.copy()
    expired = current.copy()
    state = RenderState()
    draw_boxes(current, record, 0, state)
    draw_boxes(held, record, 1, state)
    draw_boxes(expired, record, 7, state)
    assert 0 < int(held[40, 30].sum()) < int(current[40, 30].sum())
    assert not expired.any()


def test_jump_observation_is_not_projected_as_a_floor_position():
    from shuttlesense.analytics.positions import project_positions

    corners = [[0, 99], [99, 99], [99, 0], [0, 0]]
    h = compute_homography(corners)
    court = Court(corners_px=corners, homography=h.tolist())
    analyzer = StreamAnalyzer(clip_id="x", fps=10, width=100, height=100, court=court, config={})
    jump = Player(bbox=(10, 20, 30, 40), score=0.9, court_position_valid=False)
    analyzer.add_frame(Shuttle(), Players(near=jump))
    assert analyzer.record.frames[0].court_positions.near is None
    assert np.isnan(project_positions(analyzer.record)["near"][0]).all()
