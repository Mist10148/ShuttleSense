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


@pytest.mark.parametrize("finish", ["stop", "disconnect", "failure"])
def test_opt_in_queue_does_not_commit_unrequested_frames(
    tmp_path, tiny_video, monkeypatch, finish
):
    from fastapi.testclient import TestClient
    from shuttlesense.api.main import create_app
    from shuttlesense.api.settings import Settings
    import shuttlesense.io.prefetch as prefetch_module
    import shuttlesense.api.live as live_module

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
            elif finish == "failure":
                ws.send_json({"type": "next"})
                assert ws.receive_json()["type"] == "error"
        for _ in range(200):
            response = client.get(f"/jobs/{started['job_id']}/record")
            if response.status_code == 200:
                break
            time.sleep(0.01)
        assert response.status_code == 200
        assert [frame["frame"] for frame in response.json()["frames"]] == [0, 1]
        assert readers and all(not reader._thread.is_alive() for reader in readers)


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
                    frames.append((response["index"], response["jpeg"],
                                   frame_event.get("client_frame"), frame_event.get("ts")))
                    assert response["index"] == index
                ws.send_json({"type": "next"})
                saved = ws.receive_json()
                assert saved["type"] == "saved"
            record = client.get(f"/jobs/{saved['job_id']}/record").json()
            observations.append((frames, [frame["frame"] for frame in record["frames"]]))
    assert observations[0] == observations[1]
