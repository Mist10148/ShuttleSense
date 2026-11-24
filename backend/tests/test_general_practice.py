import json
import time
from types import SimpleNamespace

import cv2
import numpy as np
from fastapi.testclient import TestClient

from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings
from shuttlesense.coach.llm import FakeProvider
from shuttlesense.pose.watch_candidates import SelectedWatchCandidates
from shuttlesense.practice import general
from shuttlesense.render.player_boxes import display_players
from shuttlesense.schema import ClipRecord, Frame, Player, Players


def _person(wrist_y=8):
    points = [(0, 0, 0)] * 17
    points[0] = (18, 9, 0.9)
    points[6] = (18, 20, 0.9)
    points[8] = (24, 15, 0.9)
    points[10] = (30, wrist_y, 0.9)
    return Player(bbox=(2, 2, 40, 60), keypoints=points, score=0.9)


def test_watch_pose_filter_keeps_nearby_rivals_and_reopens_on_lost_track():
    track = SimpleNamespace(initialized=False, missing=0, bbox=(60, 30, 20, 40))
    selection = SelectedWatchCandidates(track, (320, 180), "filter", refresh_frames=5)
    boxes = [[60, 30, 80, 70], [99, 32, 115, 73], [250, 30, 270, 70]]
    shape = (180, 320, 3)
    assert selection.select(boxes, shape) == [True, True, True]
    track.initialized = True
    assert selection.select(boxes, shape) == [True, True, False]
    track.missing = 1
    assert selection.select(boxes, shape) == [True, True, True]


def test_watch_grid_selection_is_returned_in_source_coordinates_and_rejects_wrong_anchor(
    tmp_path, monkeypatch
):
    source = tmp_path / "fast.mp4"
    writer = cv2.VideoWriter(str(source), cv2.VideoWriter_fourcc(*"mp4v"), 60, (320, 180))
    assert writer.isOpened()
    for _ in range(8):
        writer.write(np.full((180, 320, 3), 35, dtype=np.uint8))
    writer.release()
    monkeypatch.setattr(general, "load_detector", lambda *args: lambda _: [_person()])
    settings = Settings(
        storage_dir=tmp_path / "storage", device="cpu", practice_general=True, coach_provider="off"
    )
    with TestClient(create_app(settings)) as client:
        client.app.state.jobs.config["live"] = {"target_height": 90, "max_fps": 30}
        with source.open("rb") as clip:
            upload = client.post("/videos", files={"file": ("fast.mp4", clip, "video/mp4")})
        video_id = upload.json()["id"]
        picker = client.get(f"/practice/videos/{video_id}/players?frame=1&watch_grid=true").json()
        assert picker["frame"] == 2
        assert picker["candidates"][0]["bbox"] == [4, 4, 80, 120]
        created = client.post(
            "/practice/sessions",
            json={
                "analysis_kind": "general",
                "video_id": video_id,
                "selection_frame": 2,
                "selected_bbox": [200, 10, 80, 120],
            },
        )
        assert created.status_code == 202, created.text
        url = f"/practice/sessions/{created.json()['id']}"

        def wait_for(status):
            for _ in range(200):
                observed = client.get(url).json()
                if observed["status"] in (status, "failed"):
                    break
                time.sleep(0.02)
            assert observed["status"] == status, observed
            return observed

        assert wait_for("needs_selection")["practice_selection_frame"] == 2
        response = client.post(
            f"{url}/selection",
            json={
                "frame": picker["frame"],
                "bbox": picker["candidates"][0]["bbox"],
            },
        )
        assert response.status_code == 202, response.text
        wait_for("done")
        result = client.get(f"{url}/analysis").json()
        assert result["fps"] == 30
        assert result["selection_frame"] == 1
        assert result["processed_frames"] == 4
        assert result["unobserved_indices"] == []
        render = tmp_path / "storage" / "jobs" / created.json()["id"] / "annotated.mp4"
        exported = cv2.VideoCapture(str(render))
        try:
            assert exported.get(cv2.CAP_PROP_FPS) == 30
            assert exported.get(cv2.CAP_PROP_FRAME_HEIGHT) == 90
            assert exported.get(cv2.CAP_PROP_FRAME_COUNT) == 4
        finally:
            exported.release()


def test_review_picks_respect_gaps_and_distinguish_still_poses():
    def clip(players):
        frames = [Frame(frame=i, players=Players(near=p)) for i, p in enumerate(players)]
        return ClipRecord(
            clip_id="test", fps=10, width=160, height=90, num_frames=len(frames), frames=frames
        )

    still = _person(30)
    raised = _person(8)
    assert [m["kind"] for m in general.review_moments(clip([still] * 4), [])] == ["snapshot"]
    assert [m["frame"] for m in general.review_moments(clip([still, still, raised]), [])] == [2]
    moments = general.review_moments(clip([still, None, raised]), [0.1])
    assert [m["kind"] for m in moments] == ["snapshot", "marked"]
    assert all(o["status"] == "unavailable" for o in moments[-1]["observations"])


def test_general_job_finishes_with_gaps_and_only_cites_the_selected_player(
    tmp_path, tiny_video, monkeypatch
):
    detections = iter([[_person()], *([[]] * 8)])
    monkeypatch.setattr(general, "load_detector", lambda *args: lambda frame: next(detections))
    tracker_class = general.SelectedIdentityTracker

    def tracker(box, **options):
        return tracker_class(box, **{**options, "max_gap": 7})

    monkeypatch.setattr(general, "SelectedIdentityTracker", tracker)
    hold_frames = set()
    labels = []
    render = general.render_watch_video
    put_text = cv2.putText

    def capture_render(*args, **kwargs):
        hold_frames.update(kwargs["config"]["stages"]["render"]["practice_occlusion_boxes"])
        return render(*args, **kwargs)

    def capture_label(img, text, *args, **kwargs):
        labels.append(text)
        return put_text(img, text, *args, **kwargs)

    monkeypatch.setattr(general, "render_watch_video", capture_render)
    monkeypatch.setattr(cv2, "putText", capture_label)
    provider = FakeProvider(
        ["Review the frame [t=0.04s]. The missing frames [t=0.08s] [t=0.36s] add no evidence."],
        {"ReportChoice": {"evidence_ids": ["pose-1-right-elbow_image_angle"]}},
        embed_model=None,
    )
    provider.name = "gemini"
    settings = Settings(storage_dir=tmp_path / "storage", device="cpu", practice_general=True)
    with TestClient(create_app(settings, coach_provider=provider)) as client:
        with tiny_video.open("rb") as clip:
            upload = client.post("/videos", files={"file": ("test.mp4", clip, "video/mp4")})
        assert upload.status_code == 201, upload.text
        setup = {
            "analysis_kind": "general",
            "video_id": upload.json()["id"],
            "selection_frame": 1,
            "selected_bbox": [2, 2, 40, 60],
            "review_seconds": [0.04, 0.36],
        }
        assert (
            client.post("/practice/sessions", json={**setup, "review_seconds": [0.0]}).status_code
            == 422
        )
        created = client.post("/practice/sessions", json=setup)
        assert created.status_code == 202, created.text
        job_id = created.json()["id"]
        path = f"/practice/sessions/{job_id}"
        for _ in range(200):
            job = client.get(path).json()
            if job["status"] in ("done", "failed"):
                break
            time.sleep(0.02)
        assert job["status"] == "done", job
        analysis = client.get(f"{path}/analysis").json()
        assert analysis["analysis_kind"] == "general"
        assert analysis["unobserved_indices"] == list(range(2, 10))
        assert analysis["tracking_lost_from_s"] == 0.08
        assert [m["frame"] for m in analysis["review_moments"]] == [1, 9]
        assert analysis["rules_report"]["session_overview"]["tracked_frames"] == 1
        assert not provider.json_calls
        record_path = settings.storage_dir / "jobs" / job_id / "practice_frames.json"
        record = ClipRecord.model_validate_json(record_path.read_text(encoding="utf8"))
        assert display_players(record, 1) and display_players(record, 2) == {}
        assert hold_frames == set(range(2, 8))
        assert all(record.frames[i].players.near is None for i in hold_frames)
        assert labels.count("Temporarily obscured") >= 6
        assert "Looking for selected player" in labels
        assert client.get(f"/jobs/{job_id}/video").status_code == 200
        assert client.put(f"{path}/events", json={"events": []}).status_code == 409

        report = client.get(f"{path}/report").json()
        assert report["generated_by"] == "gemini"
        assert "Do not infer the racket hand" in provider.json_calls[0]["system"]
        assert all(e["frame"] == 1 and "stroke" not in e for e in report["evidence"])
        response = client.post(
            f"{path}/chat",
            json={"message": "What was visible?", "context_version": report["context_version"]},
        )
        assert response.status_code == 200, response.text
        events = [
            json.loads(line[6:]) for line in response.text.splitlines() if line.startswith("data: ")
        ]
        assert events[-1]["type"] == "done"
        assert [m["frame"] for m in events[-1]["message"]["citations"]] == [1]
        assert "[t=0.08s]" not in events[-1]["message"]["text"]
