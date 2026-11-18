import threading
import time

import numpy as np
import pytest

from shuttlesense.io import FrameReader
from shuttlesense.io.prefetch import PrefetchFrames


def test_prefetch_bounds_decoding_and_closes_source():
    produced_two = threading.Event()
    produced_three = threading.Event()
    closed = threading.Event()

    def source():
        try:
            for index in range(5):
                if index == 1:
                    produced_two.set()
                if index == 2:
                    produced_three.set()
                yield index
        finally:
            closed.set()

    frames = PrefetchFrames(source, depth=2)
    try:
        assert produced_two.wait(3)
        assert not produced_three.wait(0.1)
        assert next(frames) == 0
        assert produced_three.wait(3)
        assert next(frames) == 1
    finally:
        frames.close()
    assert closed.is_set()
    assert not frames._thread.is_alive()
    assert frames._items.empty()
    with pytest.raises(StopIteration):
        next(frames)


def test_prefetch_propagates_source_error_and_closes():
    def source():
        yield 1
        raise ValueError("frame failure")

    frames = PrefetchFrames(source)
    try:
        assert next(frames) == 1
        with pytest.raises(ValueError, match="frame failure"):
            next(frames)
    finally:
        frames.close()
    assert not frames._thread.is_alive()


def test_prefetch_propagates_iterator_construction_error():
    def source():
        raise RuntimeError("cannot open source")

    frames = PrefetchFrames(source)
    try:
        with pytest.raises(RuntimeError, match="cannot open source"):
            next(frames)
    finally:
        frames.close()


def test_prefetch_preserves_real_reader_indices_and_pixels(tiny_video):
    reader = FrameReader(tiny_video)
    expected = list(reader.frames(0, len(reader)))
    frames = PrefetchFrames(lambda: reader.frames(0, len(reader)))
    try:
        actual = list(frames)
    finally:
        frames.close()
    assert [index for index, _ in actual] == [index for index, _ in expected]
    assert all(np.array_equal(a, b) for (_, a), (_, b) in zip(actual, expected, strict=True))


@pytest.mark.parametrize(
    "finish", ["stop", "disconnect", "failure", "project_failure", "event_failure"]
)
def test_opt_in_queue_does_not_commit_unrequested_frames(tmp_path, tiny_video, monkeypatch, finish):
    import cv2
    from fastapi.testclient import TestClient

    import shuttlesense.api.live as live_module
    import shuttlesense.io.prefetch as prefetch_module
    from shuttlesense.api.main import create_app
    from shuttlesense.api.settings import Settings
    from shuttlesense.stream.analyzer import StreamAnalyzer

    if finish in {"project_failure", "event_failure"}:
        method = "_project" if finish == "project_failure" else "_frame_event"
        original = getattr(StreamAnalyzer, method)
        fail_at = 2 if finish == "project_failure" else 3

        def fail_during_analysis(self, *args, **kwargs):
            if len(self.record.frames) == fail_at:
                raise RuntimeError("injected analysis failure")
            return original(self, *args, **kwargs)

        monkeypatch.setattr(StreamAnalyzer, method, fail_during_analysis)

    readers = []

    class TrackedPrefetch(PrefetchFrames):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            readers.append(self)

    monkeypatch.setattr(prefetch_module, "PrefetchFrames", TrackedPrefetch)
    processed = []
    original_frames = live_module._frames

    def track_processed(*args, **kwargs):
        if finish == "failure" and len(processed) == 2:
            raise RuntimeError("injected processing failure")
        result = original_frames(*args, **kwargs)
        processed.append(1)
        return result

    monkeypatch.setattr(live_module, "_frames", track_processed)
    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))
    with TestClient(app) as client:
        app.state.jobs.config.setdefault("watch", {})["frame_prefetch_depth"] = 2
        with tiny_video.open("rb") as source:
            video = client.post("/videos", files={"file": ("tiny.mp4", source)}).json()
        with client.websocket_connect("/watch") as ws:
            ws.send_json({"type": "start", "video_id": video["id"]})
            started = ws.receive_json()
            assert started["type"] == "started"
            # Let the producer fill its queue before the first analysis request.
            time.sleep(0.15)
            assert not processed
            for index in range(2):
                ws.send_json({"type": "next"})
                assert ws.receive_json()["index"] == index
                if index == 0:
                    # A pause is represented by not requesting another frame.
                    time.sleep(0.15)
                    assert len(processed) == 1
            # No further requests: queued frames must not be recorded on stop/disconnect.
            time.sleep(0.15)
            assert len(processed) == 2
            if finish == "stop":
                ws.send_json({"type": "stop"})
                assert ws.receive_json()["type"] == "saved"
            elif finish in {"failure", "project_failure", "event_failure"}:
                ws.send_json({"type": "next"})
                assert ws.receive_json()["type"] == "error"
        for _ in range(200):
            response = client.get(f"/jobs/{started['job_id']}/record")
            if response.status_code == 200:
                break
            time.sleep(0.01)
        assert response.status_code == 200
        expected_count = 3 if finish == "event_failure" else 2
        assert [frame["frame"] for frame in response.json()["frames"]] == list(
            range(expected_count)
        )
        assert readers and all(not reader._thread.is_alive() for reader in readers)
        assert all(reader._items.empty() for reader in readers)
        job_id = started["job_id"]
        for _ in range(500):
            job = client.get(f"/jobs/{job_id}").json()
            if job["status"] in {"done", "failed"}:
                break
            time.sleep(0.02)
        assert job["status"] == "done", job
        recording = app.state.storage.video_source(job["video_id"])
        annotated = app.state.storage.job_dir(job_id) / "annotated.mp4"
        for path in (recording, annotated):
            capture = cv2.VideoCapture(str(path))
            decoded = []
            while True:
                ok, frame = capture.read()
                if not ok:
                    break
                decoded.append(frame)
            capture.release()
            assert len(decoded) == expected_count, str(path)
            # The moving white circle makes missing or shifted frames observable,
            # including in the annotated export despite lossy compression.
            for index, frame in enumerate(decoded):
                region = frame[41:50, 6 + index * 14 : 15 + index * 14]
                assert float(region.mean()) > 80, (str(path), index)


def test_opt_in_queue_preserves_complete_watch_preview_and_timestamps(tmp_path, tiny_video):
    from fastapi.testclient import TestClient

    from shuttlesense.api.main import create_app
    from shuttlesense.api.settings import Settings

    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))
    observations = []
    with TestClient(app) as client:
        with tiny_video.open("rb") as source:
            video = client.post("/videos", files={"file": ("tiny.mp4", source)}).json()
        for depth in (0, 2):
            app.state.jobs.config.setdefault("watch", {})["frame_prefetch_depth"] = depth
            frames = []
            with client.websocket_connect("/watch") as ws:
                ws.send_json({"type": "start", "video_id": video["id"], "court": "doubles"})
                started = ws.receive_json()
                for index in range(started["frames"]):
                    ws.send_json({"type": "next"})
                    response = ws.receive_json()
                    frame_event = next(e for e in response["events"] if e["type"] == "frame")
                    frames.append(
                        (
                            response["index"],
                            response["jpeg"],
                            frame_event.get("client_frame"),
                            frame_event.get("ts"),
                        )
                    )
                    assert response["index"] == index
                ws.send_json({"type": "next"})
                saved = ws.receive_json()
                assert saved["type"] == "saved"
            record = client.get(f"/jobs/{saved['job_id']}/record").json()
            observations.append((frames, [frame["frame"] for frame in record["frames"]]))
    assert observations[0] == observations[1]


@pytest.mark.parametrize("depth", [0, 2])
def test_complete_watch_normalized_sequence_matches_preview_and_exports(
    tmp_path, monkeypatch, depth
):
    import base64

    import cv2
    from fastapi.testclient import TestClient

    import shuttlesense.api.live as live_module
    from shuttlesense.api.main import create_app
    from shuttlesense.api.settings import Settings
    from shuttlesense.render import style
    from shuttlesense.render.overlays import RenderState, draw_frame
    from shuttlesense.schema import ClipRecord

    source = tmp_path / "50fps.mp4"
    writer = cv2.VideoWriter(str(source), cv2.VideoWriter_fourcc(*"mp4v"), 50, (160, 90))
    assert writer.isOpened()
    for index in range(20):
        image = np.full((90, 160, 3), 40, dtype=np.uint8)
        cv2.circle(image, (10 + 7 * index, 45), 4, (255, 255, 255), -1)
        writer.write(image)
    writer.release()

    def assert_marker(image, index):
        x = 10 + 14 * index  # Every second source frame survives normalization.
        assert float(image[41:50, x - 4 : x + 5].mean()) > 80, index

    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))
    committed = []
    original = live_module._frames

    def track_processed(*args, **kwargs):
        result = original(*args, **kwargs)
        committed.append(1)
        return result

    monkeypatch.setattr(live_module, "_frames", track_processed)
    with TestClient(app) as client:
        app.state.jobs.config.setdefault("watch", {})["frame_prefetch_depth"] = depth
        with source.open("rb") as file:
            video = client.post("/videos", files={"file": (source.name, file)}).json()
        with client.websocket_connect("/watch") as ws:
            # The original client does not send a playback option.
            ws.send_json({"type": "start", "video_id": video["id"]})
            started = ws.receive_json()
            assert started["fps"] == 25
            assert started["frames"] == 10
            for index in range(started["frames"]):
                if index == 3:
                    time.sleep(0.15)  # Pause without another request, then resume.
                    assert len(committed) == index
                ws.send_json({"type": "next"})
                response = ws.receive_json()
                event = next(e for e in response["events"] if e["type"] == "frame")
                assert response["index"] == event["frame"] == event["client_frame"] == index
                assert event["ts"] == pytest.approx(index * 40.0)
                preview = cv2.imdecode(
                    np.frombuffer(base64.b64decode(response["jpeg"]), dtype=np.uint8),
                    cv2.IMREAD_COLOR,
                )
                assert preview is not None
                assert_marker(preview, index)
            ws.send_json({"type": "next"})
            saved = ws.receive_json()
            assert saved["type"] == "saved"
        record = client.get(f"/jobs/{saved['job_id']}/record").json()
        assert [frame["frame"] for frame in record["frames"]] == list(range(10))
        assert record["fps"] == 25
        for _ in range(500):
            job = client.get(f"/jobs/{saved['job_id']}").json()
            if job["status"] in {"done", "failed"}:
                break
            time.sleep(0.02)
        assert job["status"] == "done", job
        paths = (
            app.state.storage.video_source(job["video_id"]),
            app.state.storage.job_dir(saved["job_id"]) / "annotated.mp4",
        )
        decoded_videos = []
        for path in paths:
            capture = cv2.VideoCapture(str(path))
            assert capture.isOpened(), str(path)
            assert capture.get(cv2.CAP_PROP_FPS) == pytest.approx(25)
            frames = []
            while True:
                ok, frame = capture.read()
                if not ok:
                    break
                frames.append(frame)
            capture.release()
            assert len(frames) == 10, str(path)
            for index, frame in enumerate(frames):
                assert_marker(frame, index)
            decoded_videos.append(frames)

        # Compare the actual export with the production overlays applied to the
        # matching recorded image and record frame. Allow encoder loss.
        clip = ClipRecord.model_validate(record)
        state = RenderState(config=app.state.jobs.config, scale=style.scale_for(clip.height))
        changed = False
        for index, (recorded, exported) in enumerate(zip(*decoded_videos, strict=True)):
            expected = draw_frame(recorded.copy(), clip, index, job["overlays"], state)
            changed |= not np.array_equal(expected, recorded)
            mean_error = np.abs(expected.astype(np.int16) - exported.astype(np.int16)).mean()
            assert mean_error < 12, (index, mean_error)
        assert changed, "the alignment check must exercise real overlays"
