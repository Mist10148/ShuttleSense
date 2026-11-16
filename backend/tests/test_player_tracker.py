"""Regression tests for conservative court-aware player selection."""

import numpy as np

from shuttlesense.court import compute_homography, court_to_image
from shuttlesense.pose.player_tracker import CourtPlayerTracker
from shuttlesense.schema import COURT_SIZE_M, Player

H = compute_homography([[212, 650], [1068, 650], [880, 210], [400, 210]])


def person(x, y, ankle=True):
    px, py = court_to_image(H, np.array([[x, y]]))[0]
    kps = [(0.0, 0.0, 0.0)] * 15 + [(float(px), float(py), 0.9)] * 2 if ankle else []
    return Player(bbox=(float(px) - 30, float(py) - 150, 60, 150), keypoints=kps, score=0.9)


def update(tracker, people):
    return tracker.update(
        people, frame_height=720, homography=H, frame=np.zeros((720, 1280, 3), dtype=np.uint8)
    )


def test_confirmation_filter_and_identity_lock():
    t = CourtPlayerTracker({}, "singles", COURT_SIZE_M)
    near, far, official = person(2, 3), person(2, 10), person(-1.0, 3)
    for _ in range(2):
        assert update(t, [official, near, far]).near is None
    result = update(t, [official, near, far])
    assert result.near == near and result.far == far
    for _ in range(8):
        result = update(t, [official, far])
        assert result.near is None and result.far == far
    assert update(t, [near, far]).near is None
    assert update(t, [near, far]).near == near


def test_doubles_alleys_and_strict_boundary():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "doubles", COURT_SIZE_M)
    alley = person(-0.35, 3, False)
    assert update(t, [alley]).near == alley
    outside = person(-0.7, 3, False)
    matched = update(t, [outside]).near
    assert matched is not None and not matched.court_position_valid
    assert update(t, [person(-1.3, 3, False)]).near is None
    singles = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    assert update(singles, [alley]).near is None


def test_distant_and_ambiguous_match_stays_missing():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    update(t, [person(2, 3)])
    assert update(t, [person(4, 3)]).near is None
    assert update(t, [person(1.9, 3), person(2.1, 3)]).near is None
    assert update(t, [person(2.1, 3)]).near is not None


def test_duplicate_pose_does_not_hide_the_tracked_player():
    base = person(2, 3)
    keypoints = list(base.keypoints)
    x, y, w, h = base.bbox
    for joint, px, py in [
        (0, 0.5, 0.1),
        (5, 0.3, 0.25),
        (6, 0.7, 0.25),
        (11, 0.35, 0.5),
        (12, 0.65, 0.5),
    ]:
        keypoints[joint] = (x + w * px, y + h * py, 0.9)
    base = base.model_copy(update={"keypoints": keypoints})
    duplicate = base.model_copy(update={"score": 0.55})
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    assert update(t, [base]).near == base
    # Two copies of the same person previously looked like an ambiguous identity match.
    assert update(t, [duplicate, base]).near == base


def test_deduplication_preserves_distinct_overlapping_players():
    from shuttlesense.pose.player_tracker import _same_person_pose

    def posed(offset: float) -> Player:
        kps = [(0.0, 0.0, 0.0)] * 17
        for joint in (0, 5, 6, 11, 12):
            kps[joint] = (100.0 + offset, 100.0 + joint, 0.9)
        return Player(bbox=(80, 60, 80, 150), keypoints=kps, score=0.9)

    assert _same_person_pose(posed(0), posed(2), iou_min=0.65, pose_max=0.1)
    assert not _same_person_pose(posed(0), posed(25), iou_min=0.65, pose_max=0.1)
    # Missing pose evidence is never enough to merge players.
    assert not _same_person_pose(posed(0), person(2, 3), iou_min=0.65, pose_max=0.1)


def test_doubles_partner_gap():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "doubles", COURT_SIZE_M)
    a, b = person(1, 3), person(4, 3)
    result = update(t, [b, a])
    assert result.near == a and result.near_2 == b
    assert update(t, [b]).near is None
    assert update(t, [a, b]).near == a


def test_appearance_prevents_replacement_and_returns_original():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    p = person(2, 3, False)
    red = np.zeros((720, 1280, 3), dtype=np.uint8)
    blue = red.copy()
    x, y, w, h = map(int, p.bbox)
    red[y : y + h, x : x + w] = (0, 0, 255)
    blue[y : y + h, x : x + w] = (255, 0, 0)
    assert t.update([p], frame_height=720, homography=H, frame=red).near == p
    assert t.update([p], frame_height=720, homography=H, frame=blue).near is None
    assert t.update([p], frame_height=720, homography=H, frame=red).near == p


def test_uncalibrated_clip_still_gets_players_by_image_position():
    # No corners: no court polygon to enforce, but hits and strokes still need the players.
    t = CourtPlayerTracker({}, "singles", COURT_SIZE_M)
    near = Player(bbox=(200, 400, 60, 150), score=0.9)
    far = Player(bbox=(600, 100, 30, 80), score=0.9)
    result = t.update([near, far], frame_height=720, homography=None)
    assert result.near == near and result.far == far
    assert not t.view_valid  # their positions are not court positions


RUN_OFF = {"confirmation_frames": 1, "candidate_margin_m": 2.0}  # as in pipeline.yaml


def test_locked_player_is_followed_into_the_run_off_behind_the_baseline():
    t = CourtPlayerTracker(RUN_OFF, "singles", COURT_SIZE_M)
    assert update(t, [person(2.6, 0.4)]).near is not None
    # Steps back behind the baseline to play a clear and stays there for a while.
    for y in (0.1, -0.2, -0.5, -0.8, -1.0, *[-1.0] * 20):
        seen = update(t, [person(2.6, y)]).near
        assert seen is not None and (y >= 0 or not seen.court_position_valid)
    for y in (-0.7, -0.3, 0.1):
        assert update(t, [person(2.6, y)]).near is not None


def test_locked_player_is_followed_wide_of_the_sideline():
    t = CourtPlayerTracker(RUN_OFF, "singles", COURT_SIZE_M)
    assert update(t, [person(0.2, 3)]).near is not None
    for x in (-0.1, -0.4, -0.8, -1.1, -1.1, -1.1, -0.8, -0.4, 0.1):
        assert update(t, [person(x, 3)]).near is not None


def test_run_off_never_seeds_a_bystander_or_jumps_to_one():
    t = CourtPlayerTracker(RUN_OFF, "singles", COURT_SIZE_M)
    official = person(2.6, -1.2)
    for _ in range(5):
        assert update(t, [official]).near is None  # never seen inside the court
    assert update(t, [person(2.6, 3), official]).near is not None
    # The player is hidden: the official, metres away, does not take the slot.
    for _ in range(10):
        assert update(t, [official]).near is None
    # Beyond the run-off nobody is a candidate at all.
    assert update(t, [person(2.6, -2.6)]).near is None


def test_locked_player_can_briefly_cross_boundary_but_strangers_cannot_enter():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    assert update(t, [person(0.01, 3)]).near is not None
    jumped = update(t, [person(-0.01, 3)]).near
    assert jumped is not None and not jumped.court_position_valid
    stranger = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    assert update(stranger, [person(-0.01, 3)]).near is None
    assert update(t, [person(-0.4, 3)]).near is None
    assert update(t, [person(2, -0.01)]).near is None
    assert update(t, [person(2, 13.41)]).far is None


def test_outside_exception_expires_and_rejects_other_appearance():
    t = CourtPlayerTracker(
        {"confirmation_frames": 1, "locked_jump_max_frames": 2}, "singles", COURT_SIZE_M
    )
    inside, outside = person(0.01, 3, False), person(-0.05, 3, False)
    red = np.zeros((720, 1280, 3), np.uint8)
    red[:] = (0, 0, 255)
    blue = np.zeros_like(red)
    blue[:] = (255, 0, 0)
    assert t.update([inside], frame_height=720, homography=H, frame=red).near is not None
    assert t.update([outside], frame_height=720, homography=H, frame=blue).near is None
    assert t.update([outside], frame_height=720, homography=H, frame=red).near is not None
    assert t.update([outside], frame_height=720, homography=H, frame=red).near is not None
    assert t.update([outside], frame_height=720, homography=H, frame=red).near is None


def test_far_jump_uses_locked_box_continuity_without_a_floor_position():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    start, jump = person(2, 13.3, False), person(2, 14.3, False)
    assert update(t, [jump]).far is None  # An outside person cannot start a slot.
    assert update(t, [start]).far == start
    ground_position = t.slots["far"].pos.copy()
    observed = update(t, [jump]).far
    assert observed is not None and not observed.court_position_valid
    assert np.allclose(t.slots["far"].pos, ground_position)
    assert update(t, [start]).far == start


def test_far_jump_exception_requires_overlap_and_expires():
    t = CourtPlayerTracker(
        {"confirmation_frames": 1, "far_locked_jump_max_frames": 2}, "singles", COURT_SIZE_M
    )
    start, jump = person(2, 13.3, False), person(2, 14.3, False)
    assert update(t, [start]).far == start
    intruder = jump.model_copy(update={"bbox": (jump.bbox[0] + 100, *jump.bbox[1:])})
    assert update(t, [intruder]).far is None
    assert update(t, [jump]).far is not None
    assert update(t, [jump]).far is not None
    assert update(t, [jump]).far is None


def test_far_jump_exception_rejects_wrong_appearance_and_wide_sideliners():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    start = person(2, 13.3, False)
    jump = person(2, 14.3, False)
    red = np.zeros((720, 1280, 3), np.uint8)
    red[:] = (0, 0, 255)
    blue = np.zeros_like(red)
    blue[:] = (255, 0, 0)
    assert t.update([start], frame_height=720, homography=H, frame=red).far is not None
    assert t.update([jump], frame_height=720, homography=H, frame=blue).far is None
    assert update(t, [person(-0.8, 10, False)]).far is None


def test_far_jump_does_not_attach_to_a_distant_in_court_pose():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    start = person(2, 13.3)
    jump = person(2, 14.3)
    assert update(t, [start]).far == start
    assert update(t, [jump]).far is not None
    impostor = person(2, 9).model_copy(update={"bbox": jump.bbox})
    assert update(t, [impostor]).far is None


def test_far_jump_does_not_accept_a_pose_combining_both_players_feet():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    start = person(2, 13.3)
    jump = person(2, 14.3)
    assert update(t, [start]).far == start
    assert update(t, [jump]).far is not None
    kps = list(start.keypoints)
    kps[15] = person(2, 10).keypoints[15]
    mixed = start.model_copy(update={"bbox": jump.bbox, "keypoints": kps})
    assert update(t, [mixed]).far is None


def test_teleport_and_long_absence_do_not_reassign_locked_slot():
    t = CourtPlayerTracker(
        {"confirmation_frames": 1, "max_reacquire_gap_frames": 2}, "singles", COURT_SIZE_M
    )
    original = person(2, 3)
    assert update(t, [original]).near == original
    assert update(t, [person(2.7, 3)]).near is None
    assert update(t, []).near is None
    assert update(t, []).near is None
    assert update(t, [original]).near is None


def test_missing_player_can_recover_after_a_plausible_move():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    original = person(2, 3)
    moved = person(2.75, 3)
    assert update(t, [original]).near == original
    # The initial jump is rejected, then the gate grows while the player is absent.
    assert update(t, [moved]).near is None
    assert update(t, [moved]).near is None
    assert update(t, [moved]).near == moved


def test_missing_player_can_recover_after_previous_cutoff():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "doubles", COURT_SIZE_M)
    a, b = person(1, 3), person(4, 3)
    assert update(t, [a, b]).near == a
    for _ in range(20):
        assert update(t, [b]).near is None
    assert update(t, [a, b]).near is None
    result = update(t, [a, b])
    assert result.near == a and result.near_2 == b


def test_long_gap_does_not_accept_changed_appearance():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    player = person(2, 3, False)
    red = np.zeros((720, 1280, 3), np.uint8)
    blue = red.copy()
    x, y, w, h = map(int, player.bbox)
    red[y : y + h, x : x + w] = (0, 0, 255)
    blue[y : y + h, x : x + w] = (255, 0, 0)
    assert t.update([player], frame_height=720, homography=H, frame=red).near == player
    for _ in range(20):
        assert t.update([], frame_height=720, homography=H, frame=red).near is None
    for _ in range(3):
        assert t.update([player], frame_height=720, homography=H, frame=blue).near is None
    assert t.update([player], frame_height=720, homography=H, frame=red).near is None
    assert t.update([player], frame_height=720, homography=H, frame=red).near == player


def test_featureless_fixed_view_does_not_suppress_players():
    blank = np.zeros((720, 1280, 3), dtype=np.uint8)
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    player = person(2, 3)
    for _ in range(4):
        assert t.update([player], frame_height=720, homography=H, frame=blank).near == player


def test_watch_keeps_locked_player_outside_and_returns_to_court():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    t.watch_outside_tracking = True
    assert update(t, [person(0.05, 3)]).near is not None
    trusted = t.slots["near"].pos.copy()
    # Go well beyond the old 0.3 m and nine-frame limits, with smooth image movement.
    for x in np.linspace(-0.05, -1.2, 30):
        tracked = update(t, [person(x, 3)]).near
        assert tracked is not None and not tracked.court_position_valid
        assert np.allclose(t.slots["near"].pos, trusted)
    for x in np.linspace(-1.2, 0.1, 30):
        tracked = update(t, [person(x, 3)]).near
        assert tracked is not None
    assert tracked.court_position_valid


def test_watch_outside_candidates_cannot_seed_or_replace_players():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    t.watch_outside_tracking = True
    outside = person(-0.1, 3, False)
    assert update(t, [outside]).near is None
    red = np.full((720, 1280, 3), (0, 0, 255), dtype=np.uint8)
    blue = np.full_like(red, (255, 0, 0))
    inside = person(0.05, 3, False)
    assert t.update([inside], frame_height=720, homography=H, frame=red).near is not None
    assert t.update([outside], frame_height=720, homography=H, frame=blue).near is None
    assert t.update([outside], frame_height=720, homography=H, frame=red).near is not None
    impostor = outside.model_copy(update={"bbox": (outside.bbox[0] + 150, *outside.bbox[1:])})
    assert t.update([impostor], frame_height=720, homography=H, frame=red).near is None


def test_watch_recovers_brief_outside_occlusion_but_not_long_gap():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    t.watch_outside_tracking = True
    assert update(t, [person(0.05, 3)]).near is not None
    outside = person(-0.1, 3)
    assert update(t, [outside]).near is not None
    assert update(t, []).near is None
    assert update(t, [outside]).near is not None
    for _ in range(4):
        assert update(t, []).near is None
    assert update(t, [outside]).near is None


def test_watch_tracks_one_doubles_partner_outside_without_replacing_other():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "doubles", COURT_SIZE_M)
    t.watch_outside_tracking = True
    a, b = person(-0.4, 3), person(3, 3)
    result = update(t, [a, b])
    assert result.near == a and result.near_2 == b
    for x in np.linspace(-0.5, -1.2, 15):
        result = update(t, [person(x, 3), b])
        assert result.near is not None and not result.near.court_position_valid
        assert result.near_2 == b


def test_watch_far_player_stays_tracked_beyond_baseline():
    t = CourtPlayerTracker({"confirmation_frames": 1}, "singles", COURT_SIZE_M)
    t.watch_outside_tracking = True
    assert update(t, [person(2, 13.3)]).far is not None
    for y in np.linspace(13.45, 15.5, 25):
        far = update(t, [person(2, y)]).far
        assert far is not None and not far.court_position_valid
    for y in np.linspace(15.5, 13.2, 25):
        far = update(t, [person(2, y)]).far
        assert far is not None
    assert far.court_position_valid
