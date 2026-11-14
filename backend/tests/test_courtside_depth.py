from shuttlesense.api.live import _control
from shuttlesense.config import load_config
from shuttlesense.stream.perception import ReplayPerception
from shuttlesense.stream.session import LiveSession, StartRequest
from shuttlesense.stream.synthetic import synthetic_record


def session():
    record, _ = synthetic_record()
    return LiveSession(
        session_id="test",
        request=StartRequest(fps=30, width=640, height=360),
        config=load_config(),
        perception=ReplayPerception(record, (640, 360)),
        court_corners=None,
        recording=None,
    )


def test_duplicate_decisions_are_session_and_client_scoped():
    live = session()
    command = {"type": "award", "winner": "near", "client_id": "a", "decision_id": 1}
    assert _control(live, command)[0]["score"]["near"] == 1
    assert _control(live, command)[0]["score"]["near"] == 1
    assert _control(live, {**command, "winner": "far"})[0]["code"] == "decision_conflict"
    assert _control(live, {**command, "client_id": "b"})[0]["score"]["near"] == 2
    # A retry returns current state, never the old score cached with the receipt.
    assert _control(live, command)[0]["score"]["near"] == 2
    undo = {"type": "undo", "client_id": "a", "decision_id": 2}
    assert _control(live, undo)[0]["score"]["near"] == 1
    assert _control(live, undo)[0]["score"]["near"] == 1
    assert _control(session(), command)[0]["score"]["near"] == 1
