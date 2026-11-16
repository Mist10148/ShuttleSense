
from shuttlesense.court import compute_homography
from shuttlesense.pose.player_tracker import CourtPlayerTracker
from shuttlesense.pose.watch_candidates import WatchCandidates
from shuttlesense.schema import COURT_SIZE_M, Player, Players


def _selector(mode="shadow"):
    h = compute_homography([[212, 650], [1068, 650], [880, 210], [400, 210]])
    tracker = CourtPlayerTracker({}, "doubles", COURT_SIZE_M)
    return WatchCandidates(tracker, h, (1280, 720), mode)


def test_court_near_candidates_kept_and_spectators_marked():
    selector = _selector()
    boxes = [[0, 0, 100, 100], [600, 400, 680, 650], [1000, 40, 1100, 100]]
    assert selector.select(boxes, (720, 1280, 3)) == [False, True, False]
    selector.record(3, [False, True, False], .1, .2)
    assert selector.stats["excluded"] == 2 and selector.stats["eligible"] == 1


def test_confirmed_track_keeps_nearby_outside_candidate():
    selector = _selector()
    t = selector.tracker.slots["near"]
    t.locked, t.bbox = True, (40, 50, 60, 150)
    assert selector.select([[0, 0, 100, 100]], (720, 1280, 3)) == [True]


def test_missing_calibration_and_offscreen_court_keep_everyone():
    selector = _selector()
    selector.homography = None
    assert selector.select([[0, 0, 100, 100]], (720, 1280, 3)) == [True]
    selector.homography = compute_homography([[-10, 650], [1068, 650], [880, 210], [400, 210]])
    assert selector.select([[0, 0, 100, 100]], (720, 1280, 3)) == [True]


def test_shadow_reports_excluded_tracked_player_without_changing_result():
    selector = _selector()
    player = Player(bbox=(1, 2, 20, 40), score=.9)
    selector.excluded_players = [player]
    selector.audit(Players(near=player))
    assert selector.stats["tracked_excluded"] == 1


def test_tighter_margin_is_shadow_only_and_audits_tracked_players():
    base = _selector("filter")
    proposed = WatchCandidates(base.tracker, base.homography, (1280, 720),
                               "filter", 2.0, 0.0)
    boxes = [[x, 300, x + 20, 350] for x in range(0, 1280, 20)]
    assert proposed.select(boxes, (720, 1280, 3)) == base.select(boxes, (720, 1280, 3))
    assert proposed.proposal_stats["additional_excluded"] > 0
    player = Player(bbox=(1, 2, 20, 40), score=.9)
    proposed.proposal_players = [player]
    proposed.audit(Players(near=player))
    assert proposed.proposal_stats["tracked_excluded"] == 1


def test_footpoint_proposal_does_not_change_selected_boxes():
    base = _selector("filter")
    proposed = WatchCandidates(base.tracker, base.homography, (1280, 720),
                               "filter", 2.0, proposal_footpoint=True)
    boxes = [[x, 100, x + 80, 350] for x in range(0, 1200, 40)]
    assert proposed.select(boxes, (720, 1280, 3)) == base.select(boxes, (720, 1280, 3))
    assert proposed.proposal_stats["additional_excluded"] > 0
