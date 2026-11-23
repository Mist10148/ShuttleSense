from shuttlesense.practice.pipeline import PracticeSetup
from shuttlesense.practice.runner import save_watch_practice
from shuttlesense.schema import ClipRecord, Frame, Hit, Player, Players, Shuttle
from shuttlesense.stream.perception import SelectedPracticePerception


def test_selected_watch_slot_is_locked_and_never_rebound():
    near = Player(bbox=(0, 0, 20, 40), score=0.9)
    far = Player(bbox=(60, 0, 20, 40), score=0.9)

    class Watch:
        available = {"tracking": False, "pose": True}
        calls = 0

        def _shuttle(self, frame):
            return Shuttle()

        def _players(self, frame):
            self.calls += 1
            return Players(near=near, far=far if self.calls != 2 else None)

    adapter = SelectedPracticePerception(Watch(), far.bbox, 0)
    _, players = adapter(None, 0)
    assert adapter.selected_slot == "far" and players.far == far and players.near == near
    _, players = adapter(None, 1)
    assert players.near == near and 1 in adapter.unobserved
    _, players = adapter(None, 2)
    assert adapter.selected_slot == "far" and players.far == far


def test_ambiguous_selection_does_not_bind_a_slot():
    target = Player(bbox=(0, 0, 20, 40), score=0.9)

    class Watch:
        available = {}

        def _players(self, frame):
            return Players(near=target, far=target)

    adapter = SelectedPracticePerception(Watch(), target.bbox, 0)
    for i in range(12):
        adapter.players_for_frame(None, i)
    assert adapter.selected_slot is None
    assert len(adapter.unobserved) == 12


def test_report_evidence_uses_only_selected_slot_and_observed_frames(tmp_path):
    import json

    near = Player(bbox=(0, 0, 20, 40), score=0.9)
    far = Player(bbox=(60, 0, 20, 40), score=0.9)
    record = ClipRecord(
        clip_id="test",
        mode="practice",
        fps=10,
        width=100,
        height=80,
        num_frames=3,
        frames=[Frame(frame=i, players=Players(near=near, far=far)) for i in range(3)],
        hits=[
            Hit(id=0, frame=0, time_s=0, player="near", stroke="clear"),
            Hit(id=1, frame=1, time_s=0.1, player="far", stroke="smash"),
            Hit(id=2, frame=2, time_s=0.2, player="far", stroke="clear"),
        ],
    )
    setup = PracticeSetup(
        video_id="x",
        selected_bbox=far.bbox,
        stroke="clear",
        arm="right",
        attempt_seconds=[0.1, 0.2],
    )
    save_watch_practice(record, setup, {1}, 3, tmp_path, False, "far", False)
    data = json.loads((tmp_path / "practice.json").read_text())
    assert [event["frame"] for event in data["automatic_events"]] == [2]
    manual = [
        a for a in data["observations"] if a["observations"][0]["provenance"] == "user_marked"
    ]
    assert all(o["status"] == "unavailable" for o in manual[0]["observations"])
    assert data["selected_slot"] == "far" and data["unobserved_indices"] == [1]


def test_doubles_report_requires_selected_hitter(tmp_path):
    import json

    player = Player(bbox=(10, 10, 20, 40), score=0.9)
    record = ClipRecord(
        clip_id="test",
        mode="practice",
        fps=10,
        width=100,
        height=80,
        num_frames=3,
        frames=[Frame(frame=i, players=Players(near=player, near_2=player)) for i in range(3)],
        hits=[
            Hit(id=0, frame=0, time_s=0, player="near", hitter="near_1", stroke="clear"),
            Hit(id=1, frame=1, time_s=0.1, player="near", hitter="near_2", stroke="clear"),
            Hit(id=2, frame=2, time_s=0.2, player="near", hitter=None, stroke="clear"),
        ],
    )
    setup = PracticeSetup(video_id="x", selected_bbox=player.bbox, stroke="clear", arm="right")
    save_watch_practice(record, setup, set(), 3, tmp_path, False, "near_2", True)
    data = json.loads((tmp_path / "practice.json").read_text())
    assert [event["frame"] for event in data["automatic_events"]] == [1]


def test_selected_slot_uses_actual_watch_court_tracker():
    import numpy as np

    from shuttlesense.court import compute_homography, court_to_image
    from shuttlesense.pose.player_tracker import CourtPlayerTracker
    from shuttlesense.schema import COURT_SIZE_M

    homography = compute_homography([[212, 650], [1068, 650], [880, 210], [400, 210]])

    def at(x, y):
        px, py = court_to_image(homography, np.array([[x, y]]))[0]
        points = [(0.0, 0.0, 0.0)] * 15 + [(float(px), float(py), 0.9)] * 2
        return Player(bbox=(float(px) - 30, float(py) - 150, 60, 150), keypoints=points, score=0.9)

    near, far = at(2, 3), at(2, 10)
    frame = np.zeros((720, 1280, 3), dtype=np.uint8)

    class Watch:
        available = {}
        tracker = CourtPlayerTracker({}, "singles", COURT_SIZE_M)
        calls = 0

        def _players(self, image):
            self.calls += 1
            people = [near, far] if self.calls <= 3 else [far]
            return self.tracker.update(people, frame_height=720, homography=homography, frame=image)

    core = Watch()
    adapter = SelectedPracticePerception(core, near.bbox, 0)
    assert adapter.players_for_frame(frame, 0).near is None
    assert adapter.players_for_frame(frame, 1).near is None
    assert adapter.players_for_frame(frame, 2).near == near
    assert adapter.selected_slot == "near"
    assert adapter.players_for_frame(frame, 3).near is None
    assert adapter.selected_slot == "near" and 3 in adapter.unobserved


def test_selected_second_player_uses_doubles_watch_slot():
    import numpy as np

    from shuttlesense.court import compute_homography, court_to_image
    from shuttlesense.pose.player_tracker import CourtPlayerTracker
    from shuttlesense.schema import COURT_SIZE_M

    homography = compute_homography([[212, 650], [1068, 650], [880, 210], [400, 210]])

    def person(x):
        px, py = court_to_image(homography, np.array([[x, 3.0]]))[0]
        points = [(0.0, 0.0, 0.0)] * 15 + [(float(px), float(py), 0.9)] * 2
        return Player(bbox=(float(px) - 30, float(py) - 150, 60, 150), keypoints=points, score=0.9)

    first, selected = person(1), person(4)
    frame = np.zeros((720, 1280, 3), dtype=np.uint8)

    class Watch:
        available = {}

        def __init__(self, court):
            self.tracker = CourtPlayerTracker({}, court, COURT_SIZE_M)
            self.tracker.watch_outside_tracking = True

        def _players(self, image):
            return self.tracker.update(
                [first, selected], frame_height=720, homography=homography, frame=image
            )

    singles = SelectedPracticePerception(Watch("singles"), selected.bbox, 0)
    doubles = SelectedPracticePerception(Watch("doubles"), selected.bbox, 0)
    for i in range(10):
        singles.players_for_frame(frame, i)
        doubles.players_for_frame(frame, i)
    assert singles.selected_slot is None
    assert doubles.selected_slot == "near_2"
    assert 9 not in doubles.unobserved
