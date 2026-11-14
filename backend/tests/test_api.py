"""API round trip with the stub pipeline: upload -> job -> record -> exports -> delete."""

from __future__ import annotations

import codecs
import csv
import io
import json
import time
from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from snapshots import assert_matches_snapshot

from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings
from shuttlesense.pipeline import STAGE_NAMES, available_stages

CORNERS = [[20, 80], [140, 80], [120, 20], [40, 20]]


def make_client(tmp_path: Path, **settings) -> TestClient:
    return TestClient(
        create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", **settings))
    )


@pytest.fixture
def client(tmp_path: Path) -> Iterator[TestClient]:
    with make_client(tmp_path) as c:
        yield c


def upload(client: TestClient, video: Path, headers: dict | None = None):
    with video.open("rb") as f:
        return client.post(
            "/videos", files={"file": ("rally.mp4", f, "video/mp4")}, headers=headers
        )


def wait_for(client: TestClient, job_id: str, timeout: float = 20.0) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        job = client.get(f"/jobs/{job_id}").json()
        if job["status"] in ("done", "failed", "cancelled"):
            return job
        time.sleep(0.1)
    raise AssertionError("job did not finish in time")


def test_health(client: TestClient) -> None:
    body = client.get("/health").json()
    assert body["status"] == "ok"
    assert body["auth_required"] is False
    assert set(body["stages"]) <= set(STAGE_NAMES)
    assert body["stages"][0] == "io" and body["stages"][-1] == "render"


def test_available_stages_skip_missing_weights() -> None:
    config = {"stages": {"tracking": {"tracknet_weights": "weights/does-not-exist.pt"}}}
    stages = available_stages(config)
    assert "tracking" not in stages
    assert {"io", "court", "hits", "analytics", "render"} <= set(stages)
    assert "court" not in available_stages({"stages": {"court": {"enabled": False}}})


def test_tracking_from_a_precomputed_csv_counts_as_available(tmp_path: Path) -> None:
    csv = tmp_path / "ball.csv"
    csv.write_text("Frame,Visibility,X,Y\n")
    tracking = {"tracknet_weights": "weights/does-not-exist.pt", "precomputed_csv": str(csv)}
    assert "tracking" in available_stages({"stages": {"tracking": tracking}})
    tracking["precomputed_csv"] = str(tmp_path / "missing.csv")
    assert "tracking" not in available_stages({"stages": {"tracking": tracking}})


def test_openapi_snapshot(client: TestClient) -> None:
    docs = Path(__file__).resolve().parents[2] / "docs" / "openapi.json"
    assert_matches_snapshot(client.app.openapi(), docs)


def test_full_round_trip(client: TestClient, tiny_video: Path) -> None:
    res = upload(client, tiny_video)
    assert res.status_code == 201, res.text
    video = res.json()
    assert video["width"] == 160 and video["height"] == 90 and video["num_frames"] == 10

    frame = client.get(f"/videos/{video['id']}/frames/0")
    assert frame.status_code == 200
    assert frame.headers["content-type"] == "image/jpeg"
    assert frame.headers["x-frame-width"] == "160"

    res = client.post("/jobs", json={"video_id": video["id"], "court_corners_px": CORNERS})
    assert res.status_code == 202, res.text
    job = wait_for(client, res.json()["id"])
    assert job["status"] == "done", job
    statuses = {s["name"]: s["status"] for s in job["stages"]}
    assert statuses["court"] == "done"
    assert statuses["referee"] == "skipped"  # referee not requested
    assert job["outputs"]["record"] and job["outputs"]["hits_csv"]

    record = client.get(f"/jobs/{job['id']}/record").json()
    assert record["clip_id"] == job["id"]
    assert len(record["frames"]) == 10
    assert record["court"]["corners_px"][0] == [20.0, 80.0]

    hits_csv = client.get(f"/jobs/{job['id']}/hits.csv").content
    assert hits_csv.startswith(codecs.BOM_UTF8 + b"id,frame")
    video_res = client.get(f"/jobs/{job['id']}/video")
    assert video_res.status_code == 200 and video_res.headers["content-type"] == "video/mp4"
    assert [j["id"] for j in client.get("/jobs").json()] == [job["id"]]

    assert client.delete(f"/jobs/{job['id']}").status_code == 204
    assert client.get(f"/jobs/{job['id']}").status_code == 404
    assert client.delete(f"/videos/{video['id']}").status_code == 204
    assert client.get(f"/videos/{video['id']}").status_code == 404


def test_without_corners_court_stages_skip(client: TestClient, tiny_video: Path) -> None:
    video = upload(client, tiny_video).json()
    job = wait_for(client, client.post("/jobs", json={"video_id": video["id"]}).json()["id"])
    statuses = {s["name"]: s["status"] for s in job["stages"]}
    assert job["status"] == "done"
    assert statuses["court"] == "skipped"


def test_rejects_bad_input(client: TestClient, tiny_video: Path) -> None:
    res = client.post("/videos", files={"file": ("notes.txt", b"hello", "text/plain")})
    assert res.status_code == 415
    video = upload(client, tiny_video).json()
    bad_order = [CORNERS[0], CORNERS[2], CORNERS[1], CORNERS[3]]
    res = client.post("/jobs", json={"video_id": video["id"], "court_corners_px": bad_order})
    assert res.status_code == 400
    res = client.post("/jobs", json={"video_id": video["id"], "overlays": ["sparkles"]})
    assert res.status_code == 400
    assert client.post("/jobs", json={"video_id": "missing"}).status_code == 404


def test_failed_stage_reports_error(tmp_path: Path, tiny_video: Path) -> None:
    def broken_pipeline(*_args, **_kwargs):
        raise RuntimeError("tracker exploded")

    app = create_app(Settings(storage_dir=tmp_path / "s", device="cpu"), pipeline=broken_pipeline)
    with TestClient(app) as c:
        video = upload(c, tiny_video).json()
        job = wait_for(c, c.post("/jobs", json={"video_id": video["id"]}).json()["id"])
    assert job["status"] == "failed"
    assert job["error"] == "tracker exploded"


def test_token_required_when_configured(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, token="s3cret") as c:
        assert c.get("/health").json()["auth_required"] is True
        assert c.get("/jobs").status_code == 401
        assert c.get("/jobs", headers={"Authorization": "Bearer nope"}).status_code == 401
        assert c.get("/jobs", headers={"Authorization": "Bearer s3cret"}).status_code == 200
        assert c.get("/jobs", headers={"Authorization": "bearer s3cret"}).status_code == 200
        assert c.get("/jobs?token=s3cret").status_code == 200
        assert upload(c, tiny_video, headers={"Authorization": "Bearer s3cret"}).status_code == 201


def test_fake_pipeline_returns_hits(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        assert client.get("/health").json()["stages"] == list(STAGE_NAMES)
        video = upload(client, tiny_video).json()
        job = client.post("/jobs", json={"video_id": video["id"], "referee": True}).json()
        assert wait_for(client, job["id"])["status"] == "done"
        record = client.get(f"/jobs/{job['id']}/record").json()
        assert record["num_frames"] == 10 and len(record["frames"]) == 10
        assert [h["stroke"] for h in record["hits"]] == ["serve", "clear", "smash"]
        assert all(0 <= h["frame"] < 10 for h in record["hits"])
        assert record["court"] is None and record["score"]["near"] == 1


def test_fake_cli(tmp_path: Path, tiny_video: Path) -> None:
    from shuttlesense.run import main

    main(["--video", str(tiny_video), "--out", str(tmp_path / "out"), "--fake"])
    assert (tmp_path / "out" / "hits.csv").read_text().count("\n") == 4


def test_fake_record_is_normalized_like_the_io_stage(tmp_path: Path, tiny_video: Path) -> None:
    from shuttlesense.fake import fake_pipeline

    config = {"stages": {"io": {"target_height": 46}}}  # 160x90 -> 82x46, as FrameReader
    corners = [[20, 80], [140, 80], [120, 10], [40, 10]]
    record = fake_pipeline(
        tiny_video, tmp_path, clip_id="c", config=config, court_corners_px=corners
    )
    assert (record.width, record.height) == (82, 46)
    assert record.court.corners_px[0] == pytest.approx((20 * 82 / 160, 80 * 46 / 90))


def test_upload_over_duration_limit_is_400(tmp_path: Path, tiny_video: Path) -> None:
    config = tmp_path / "pipeline.yaml"
    config.write_text("stages:\n  io:\n    max_duration_s: 0.1\n")
    with make_client(tmp_path, config=config) as client:
        res = upload(client, tiny_video)
        assert res.status_code == 400 and "longer than" in res.json()["detail"]


def test_progress_is_monotonic(tmp_path: Path, tiny_video: Path) -> None:
    from shuttlesense.pipeline import run_pipeline

    def slow_pipeline(*args, on_event, **kwargs):
        def report(name, status, progress):
            time.sleep(0.01)
            on_event(name, status, progress)

        return run_pipeline(*args, on_event=report, **kwargs)

    with TestClient(
        create_app(Settings(storage_dir=tmp_path / "s", device="cpu"), pipeline=slow_pipeline)
    ) as client:
        video = upload(client, tiny_video).json()
        job_id = client.post("/jobs", json={"video_id": video["id"]}).json()["id"]
        seen = []
        deadline = time.time() + 20
        while time.time() < deadline:
            job = client.get(f"/jobs/{job_id}").json()
            seen.append(job["progress"])
            if job["status"] == "done":
                break
        assert seen == sorted(seen) and seen[-1] == 1.0


def test_rerender_only_runs_render_stage(
    tmp_path: Path, tiny_video: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from shuttlesense import pipeline
    from shuttlesense.pipeline import StageSpec

    calls = {"tracking": 0, "render": 0}
    real_render = {s.name: s.fn for s in pipeline.STAGES}["render"]

    def tracking(record, ctx):
        calls["tracking"] += 1
        return record

    def render(record, ctx):
        calls["render"] += 1
        assert ctx.overlays == (("boxes",) if calls["render"] == 2 else ("trail",))
        return real_render(record, ctx)

    stages = []
    for s in pipeline.STAGES:
        fn = {"tracking": tracking, "render": render}.get(s.name, s.fn)
        stages.append(StageSpec(s.name, fn, s.needs_court, s.referee))
    monkeypatch.setattr(pipeline, "STAGES", tuple(stages))

    with make_client(tmp_path) as client:
        video = upload(client, tiny_video).json()
        job = client.post("/jobs", json={"video_id": video["id"], "overlays": ["trail"]}).json()
        assert wait_for(client, job["id"])["status"] == "done"
        res = client.post(f"/jobs/{job['id']}/render", json={"overlays": ["boxes"]})
        assert res.status_code == 202 and res.json()["overlays"] == ["boxes"]
        done = wait_for(client, job["id"])
        assert done["status"] == "done" and done["outputs"]["video"]
        assert calls == {"tracking": 1, "render": 2}
        bad = client.post(f"/jobs/{job['id']}/render", json={"overlays": ["nope"]})
        assert bad.status_code == 400


def test_rallies_csv_endpoint(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        video = upload(client, tiny_video).json()
        job = client.post("/jobs", json={"video_id": video["id"], "referee": True}).json()
        assert wait_for(client, job["id"])["outputs"]["rallies_csv"]
        res = client.get(f"/jobs/{job['id']}/rallies.csv")
        assert res.status_code == 200
        assert res.content.startswith(codecs.BOM_UTF8 + b"index,start_frame")
        assert len(res.content.decode("utf-8-sig").strip().splitlines()) == 2


def _referee_job(client: TestClient, video: Path, start_score: dict | None = None) -> str:
    vid = upload(client, video).json()["id"]
    body = {"video_id": vid, "referee": True, "court_corners_px": CORNERS}
    if start_score:
        body["start_score"] = start_score
    job = client.post("/jobs", json=body).json()
    assert wait_for(client, job["id"])["status"] == "done"
    return job["id"]


def test_score_correction_recomputes_following_rallies(
    tmp_path: Path, tiny_video: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from shuttlesense import fake
    from shuttlesense.schema import Rally

    real_scale = fake.scale_record

    def three_rallies(*args, **kwargs):
        record = real_scale(*args, **kwargs)
        record.rallies = [
            Rally(index=i, start_frame=3 * i, end_frame=3 * i + 2, winner=w)
            for i, w in enumerate(["near", "near", "far"])
        ]
        return record

    monkeypatch.setattr(fake, "scale_record", three_rallies)
    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video)
        res = client.patch(f"/jobs/{job_id}/score", json={"rally_index": 0, "winner": "far"})
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["score"]["near"] == 1 and body["score"]["far"] == 2
        assert [(r["score_after"]["near"], r["score_after"]["far"]) for r in body["rallies"]] == [
            (0, 1), (1, 1), (1, 2),
        ]  # fmt: skip
        record = client.get(f"/jobs/{job_id}/record").json()
        assert record["score"]["corrections"][0]["winner_before"] == "near"
        summary = client.get(f"/jobs/{job_id}/summary.json").json()
        assert summary["score"]["far"] == 2
        rallies_csv = client.get(f"/jobs/{job_id}/rallies.csv").content.decode("utf-8-sig")
        row = next(csv.DictReader(io.StringIO(rallies_csv)))
        assert (row["score_near"], row["score_far"]) == ("0", "1")
        assert row["decision"] == "winner far"
        # The rally timeline follows the correction too.
        ends = [e for e in record["rally_events"] if e["type"] == "rally_end"]
        assert ends[0]["data"]["winner"] == "far"
        scores = [e["data"] for e in record["rally_events"] if e["type"] == "score"]
        assert scores[0] == {"near": 0, "far": 1}


def test_line_call_override_rescores(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video)
        record = client.get(f"/jobs/{job_id}/record").json()
        call = record["line_calls"][0]
        assert call["call"] == "in" and record["score"]["near"] == 1
        res = client.patch(f"/jobs/{job_id}/line-calls/{call['id']}", json={"call": "out"})
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["line_calls"][0]["override"]["call"] == "out"
        # The near player hit the last shot out, so the rally goes to far.
        assert body["rallies"][0]["winner"] == "far"
        assert (body["score"]["near"], body["score"]["far"]) == (0, 1)
        again = client.get(f"/jobs/{job_id}/record").json()
        assert again["line_calls"][0]["override"]["call"] == "out"
        assert any(
            e["type"] == "landing" and e["data"]["call"] == "out" for e in again["rally_events"]
        )
        # A re-render rebuilds the record from the cache and keeps the override.
        client.post(f"/jobs/{job_id}/render", json={"overlays": ["trail"]})
        assert wait_for(client, job_id)["status"] == "done"
        rerendered = client.get(f"/jobs/{job_id}/record").json()
        assert rerendered["line_calls"][0]["override"]["call"] == "out"
        assert rerendered["score"]["far"] == 1
        assert client.patch(f"/jobs/{job_id}/line-calls/9", json={"call": "in"}).status_code == 404


def test_old_record_is_migrated_when_served(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video)
        path = tmp_path / "storage" / "jobs" / job_id / "record.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        data["schema_version"] = "1.0"
        for key in ("mode", "line_calls", "rally_events", "coaching", "chat"):
            data.pop(key, None)
        path.write_text(json.dumps(data), encoding="utf-8")
        served = client.get(f"/jobs/{job_id}/record").json()
        assert served["schema_version"] == "1.6" and served["mode"] == "upload"
        assert served["line_calls"][0]["call"] == "in"


def test_correction_409_without_referee(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        vid = upload(client, tiny_video).json()["id"]
        job = client.post("/jobs", json={"video_id": vid}).json()
        assert wait_for(client, job["id"])["status"] == "done"
        res = client.patch(f"/jobs/{job['id']}/score", json={"rally_index": 0, "winner": "far"})
        assert res.status_code == 409


def test_calibrate_without_gui_explains(tiny_video: Path) -> None:
    import cv2

    from shuttlesense.run import click_corners

    if "GUI:                           NONE" not in cv2.getBuildInformation():
        pytest.skip("OpenCV has GUI support here; the window would wait for clicks")

    with pytest.raises(SystemExit, match="GUI support"):
        click_corners(tiny_video)


def test_worker_survives_storage_errors(tmp_path: Path, tiny_video: Path) -> None:
    def empty_error(*_args, **_kwargs):
        raise AssertionError

    app = create_app(Settings(storage_dir=tmp_path / "s", device="cpu"), pipeline=empty_error)
    with TestClient(app) as c:
        jobs = c.app.state.jobs
        real_save = jobs.storage.save_job
        calls = {"n": 0}

        def flaky_save(job):
            calls["n"] += 1
            if job.status == "running" and calls["n"] < 4:
                raise OSError("disk full")
            real_save(job)

        jobs.storage.save_job = flaky_save
        video = upload(c, tiny_video).json()
        first = wait_for(c, c.post("/jobs", json={"video_id": video["id"]}).json()["id"])
        assert first["status"] == "failed"
        jobs.storage.save_job = real_save
        # The worker is still alive, and an exception without a message reports its type.
        second = wait_for(c, c.post("/jobs", json={"video_id": video["id"]}).json()["id"])
        assert second["status"] == "failed" and second["error"] == "AssertionError"


def test_video_deleted_during_its_job_is_removed_when_the_job_stops(
    tmp_path: Path, tiny_video: Path
) -> None:
    import shutil

    app_ref = {}

    def pipeline(source, _out_dir, *, on_event, **_kwargs):
        # DELETE /videos/{id} arrives while the job holds the source open: as on Windows,
        # only meta.json can be removed now.
        storage = app_ref["app"].state.jobs.storage
        rmtree = shutil.rmtree
        shutil.rmtree = lambda *a, **k: None
        try:
            app_ref["client"].delete(f"/videos/{source.parent.name}")
        finally:
            shutil.rmtree = rmtree
        assert storage.video_deleted(source.parent.name)
        on_event("io", "running", 0.0)  # the worker notices the cancellation

    app = create_app(Settings(storage_dir=tmp_path / "s", device="cpu"), pipeline=pipeline)
    app_ref["app"] = app
    with TestClient(app) as c:
        app_ref["client"] = c
        video = upload(c, tiny_video).json()
        job_id = c.post("/jobs", json={"video_id": video["id"]}).json()["id"]
        video_dir = app.state.jobs.storage.video_dir(video["id"])
        deadline = time.time() + 10
        while video_dir.exists() and time.time() < deadline:
            time.sleep(0.05)
        assert not video_dir.exists()
        assert c.get(f"/jobs/{job_id}").status_code == 404
        assert c.get(f"/videos/{video['id']}/frames/0").status_code == 404


def test_unreadable_job_file_is_skipped(tmp_path: Path) -> None:
    from shuttlesense.api.storage import Storage

    storage = Storage(tmp_path / "s")
    bad = storage.jobs_dir / ("c" * 12)
    bad.mkdir()
    (bad / "job.json").write_text("{not json", encoding="utf-8")
    assert storage.load_jobs() == []


def test_queue_position_follows_enqueue_order(tmp_path: Path) -> None:
    from shuttlesense.api.jobs import JobManager
    from shuttlesense.api.models import Job, VideoInfoOut
    from shuttlesense.api.storage import Storage

    storage = Storage(tmp_path / "s")
    storage.video_dir("f" * 12).mkdir(parents=True)
    storage.save_video_meta(
        VideoInfoOut(id="f" * 12, filename="c.mp4", size_bytes=1, fps=30, width=2, height=2,
                     num_frames=1, duration_s=0.1)
    )  # fmt: skip
    manager = JobManager(storage, config={}, device="cpu")
    older = manager.submit(Job(id="a" * 12, video_id="f" * 12, overlays=[]))
    newer = manager.submit(Job(id="b" * 12, video_id="f" * 12, overlays=[]))
    assert (older.queue_position, manager.get(newer.id).queue_position) == (0, 1)
    with manager._lock:
        manager._jobs[older.id].status = "done"
    manager.rerender(older.id, [])  # back of the queue, although it was created first
    assert manager.get(newer.id).queue_position == 0
    assert manager.get(older.id).queue_position == 1


def test_job_for_a_video_deleted_meanwhile_is_refused(tmp_path: Path) -> None:
    """POST /jobs checked the video, then DELETE /videos hid it before the job was queued."""
    from shuttlesense.api.jobs import JobManager, VideoGone
    from shuttlesense.api.models import Job
    from shuttlesense.api.storage import Storage

    manager = JobManager(Storage(tmp_path / "s"), config={}, device="cpu")
    with pytest.raises(VideoGone):
        manager.submit(Job(id="a" * 12, video_id="f" * 12, overlays=[]))
    assert manager.list() == []


def test_ids_that_are_not_ours_are_not_found(client: TestClient, tiny_video: Path) -> None:
    for bad in ("..", "..%5C..%5Cstorage", "missing"):
        assert client.get(f"/videos/{bad}").status_code == 404
        assert client.delete(f"/videos/{bad}").status_code == 404
        assert client.get(f"/jobs/{bad}").status_code == 404
    assert client.post("/jobs", json={"video_id": "../videos"}).status_code == 404


def test_frame_out_of_range_is_404(client: TestClient, tiny_video: Path) -> None:
    video = upload(client, tiny_video).json()
    assert client.get(f"/videos/{video['id']}/frames/9").status_code == 200
    assert client.get(f"/videos/{video['id']}/frames/10").status_code == 404
    assert client.get(f"/videos/{video['id']}/frames/-1").status_code == 422


def test_upload_over_size_limit_leaves_nothing_behind(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, max_upload_mb=0) as client:
        assert upload(client, tiny_video).status_code == 413
    assert list((tmp_path / "storage" / "videos").iterdir()) == []


def test_chunked_upload_over_size_limit_is_stopped_early(tmp_path: Path) -> None:
    # Driven over raw ASGI: TestClient reads the whole body before sending it.
    import asyncio

    app = create_app(Settings(storage_dir=tmp_path / "s", device="cpu", max_upload_mb=0))
    boundary = "x" * 16
    head = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="big.mp4"\r\n'
        "Content-Type: video/mp4\r\n\r\n"
    ).encode()
    chunks = [head] + [b"\0" * 65536] * 64  # 4 MB against a 64 KB limit, no Content-Length
    read = {"n": 0}
    statuses = []

    async def receive() -> dict:
        i = read["n"]
        read["n"] += 1
        if i >= len(chunks):
            return {"type": "http.disconnect"}
        return {"type": "http.request", "body": chunks[i], "more_body": i + 1 < len(chunks)}

    async def send(message: dict) -> None:
        if message["type"] == "http.response.start":
            statuses.append(message["status"])

    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": "/videos",
        "raw_path": b"/videos",
        "query_string": b"",
        "root_path": "",
        "headers": [
            (b"content-type", f"multipart/form-data; boundary={boundary}".encode()),
            (b"transfer-encoding", b"chunked"),
        ],
        "client": ("test", 1),
        "server": ("test", 80),
    }
    asyncio.run(app(scope, receive, send))
    assert statuses == [413]
    assert read["n"] < len(chunks)  # stopped before the whole body was read


def test_negative_start_score_is_400(client: TestClient, tiny_video: Path) -> None:
    video = upload(client, tiny_video).json()
    body = {"video_id": video["id"], "referee": True, "start_score": {"near": -1, "far": 0}}
    assert client.post("/jobs", json=body).status_code == 400


def test_finished_game_start_score_is_400(client: TestClient, tiny_video: Path) -> None:
    video = upload(client, tiny_video).json()
    body = {"video_id": video["id"], "referee": True, "start_score": {"near": 21, "far": 15}}
    assert client.post("/jobs", json=body).status_code == 400
    body["start_score"] = {"near": 31, "far": 31}  # past the 30 cap: cannot happen
    assert client.post("/jobs", json=body).status_code == 400
    body["start_score"] = {"near": 21, "far": 20}  # deuce: still on
    assert client.post("/jobs", json=body).status_code == 202


def test_deleted_video_rejects_new_jobs_during_delete(
    client: TestClient, tiny_video: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    video = upload(client, tiny_video).json()
    jobs = client.app.state.jobs
    real = jobs.delete_for_video
    racing = {}

    def delete_for_video(video_id: str) -> None:
        # A POST /jobs arriving between the job snapshot and the delete.
        racing["status"] = client.post("/jobs", json={"video_id": video_id}).status_code
        real(video_id)

    monkeypatch.setattr(jobs, "delete_for_video", delete_for_video)
    assert client.delete(f"/videos/{video['id']}").status_code == 204
    assert racing["status"] == 404
    assert jobs.list() == []


def test_rerender_keeps_score_corrections(
    tmp_path: Path, tiny_video: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from shuttlesense import pipeline
    from shuttlesense.pipeline import StageSpec
    from shuttlesense.schema import Rally, Score

    def referee(record, ctx):
        record.rallies = [
            Rally(index=i, start_frame=3 * i, end_frame=3 * i + 2, winner=w)
            for i, w in enumerate(["near", "near", "far"])
        ]
        record.score = Score(near=2, far=1)
        return record

    stages = [
        StageSpec(s.name, referee, s.needs_court, s.referee) if s.name == "referee" else s
        for s in pipeline.STAGES
    ]
    monkeypatch.setattr(pipeline, "STAGES", tuple(stages))
    with make_client(tmp_path) as client:
        job_id = _referee_job(client, tiny_video)
        res = client.patch(f"/jobs/{job_id}/score", json={"rally_index": 0, "winner": "far"})
        assert res.status_code == 200 and res.json()["score"]["far"] == 2
        assert client.post(f"/jobs/{job_id}/render", json={"overlays": []}).status_code == 202
        assert wait_for(client, job_id)["status"] == "done"
        record = client.get(f"/jobs/{job_id}/record").json()
        assert [r["winner"] for r in record["rallies"]] == ["far", "near", "far"]
        assert (record["score"]["near"], record["score"]["far"]) == (1, 2)
        assert len(record["score"]["corrections"]) == 1


def test_fake_pipeline_uses_start_score(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video, start_score={"near": 10, "far": 12})
        record = client.get(f"/jobs/{job_id}/record").json()
        assert record["score"]["near"] >= 10 and record["score"]["far"] >= 12


def test_award_and_undo_over_rest(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video)
        before = client.get(f"/jobs/{job_id}/record").json()["score"]
        res = client.post(f"/jobs/{job_id}/score/award", json={"winner": "far"})
        assert res.status_code == 200 and res.json()["score"]["far"] == before["far"] + 1
        rally = client.get(f"/jobs/{job_id}/record").json()["rallies"][0]
        res = client.patch(f"/jobs/{job_id}/score", json={"rally_index": 0, "winner": None})
        assert res.status_code == 200 and res.json()["rallies"][0]["winner"] is None
        assert (
            client.post(f"/jobs/{job_id}/score/undo").json()["rallies"][0]["winner"]
            == (rally["winner"])
        )
        assert client.post(f"/jobs/{job_id}/score/undo").json()["score"] == before
        assert client.post(f"/jobs/{job_id}/score/undo").status_code == 404


def test_undo_keeps_line_call_overrides_like_a_rerender(tmp_path: Path, tiny_video: Path) -> None:
    """Correction, then override, then undo: the newest decision wins, undo takes back the
    override, and the score equals what a re-render gives (D32)."""
    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video)
        call = client.get(f"/jobs/{job_id}/record").json()["line_calls"][0]
        client.patch(f"/jobs/{job_id}/score", json={"rally_index": 0, "winner": None})
        res = client.patch(f"/jobs/{job_id}/line-calls/{call['id']}", json={"call": "out"})
        assert res.json()["rallies"][0]["winner"] == "far"  # the newer override wins
        undone = client.post(f"/jobs/{job_id}/score/undo").json()
        assert undone["rallies"][0]["winner"] is None  # the correction applies again
        assert undone["line_calls"][0]["override"] is None
        client.post(f"/jobs/{job_id}/render", json={"overlays": ["trail"]})
        assert wait_for(client, job_id)["status"] == "done"
        rerendered = client.get(f"/jobs/{job_id}/record").json()
        assert rerendered["score"]["near"] == undone["score"]["near"]
        assert rerendered["score"]["far"] == undone["score"]["far"]
        assert rerendered["rallies"][0]["winner"] is None
        assert rerendered["line_calls"][0]["override"] is None


def test_undo_takes_back_the_newest_decision_not_an_older_award(
    tmp_path: Path, tiny_video: Path
) -> None:
    """Award, then override: Undo removes the override and keeps the award (D32)."""
    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video)
        record = client.get(f"/jobs/{job_id}/record").json()
        call = record["line_calls"][0]
        awarded = client.post(f"/jobs/{job_id}/score/award", json={"winner": "near"}).json()
        client.patch(f"/jobs/{job_id}/line-calls/{call['id']}", json={"call": "out"})
        undone = client.post(f"/jobs/{job_id}/score/undo").json()
        assert undone["score"]["near"] == awarded["score"]["near"]
        assert undone["score"]["far"] == awarded["score"]["far"]
        assert [c["kind"] for c in undone["score"]["corrections"]] == ["award"]
        assert undone["line_calls"][0]["override"] is None
        assert client.get(f"/jobs/{job_id}/record").json()["line_calls"][0]["override"] is None


def test_rerender_waits_for_a_score_edit_in_progress(tmp_path: Path, tiny_video: Path) -> None:
    """A re-render cannot be queued while a score edit holds the job's lock."""
    import threading

    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video)
        jobs = client.app.state.jobs
        lock = jobs.job_lock(job_id)
        lock.acquire()
        worker = threading.Thread(target=jobs.rerender, args=(job_id, ["trail"]))
        worker.start()
        worker.join(timeout=0.3)
        assert worker.is_alive() and jobs.get(job_id).status == "done"
        lock.release()
        worker.join(timeout=5)
        assert not worker.is_alive()
        assert wait_for(client, job_id)["status"] == "done"


def test_job_match_settings_reach_the_record(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        vid = upload(client, tiny_video).json()["id"]
        body = {"video_id": vid, "referee": True, "court_corners_px": CORNERS, "best_of": 3,
                "first_server": "far"}  # fmt: skip
        job = client.post("/jobs", json=body).json()
        assert job["best_of"] == 3 and job["first_server"] == "far"
        assert wait_for(client, job["id"])["status"] == "done"
        score = client.get(f"/jobs/{job['id']}/record").json()["score"]
        assert score["best_of"] == 3 and score["first_server"] == "far"
        assert score["server"] in ("near", "far") and score["service_court"] in ("right", "left")
        body["best_of"] = 2
        assert client.post("/jobs", json=body).status_code == 422


def test_failed_rerender_can_be_retried_and_restart_restores_it(
    tmp_path: Path, tiny_video: Path
) -> None:
    from shuttlesense.api.jobs import JobManager
    from shuttlesense.pipeline import run_pipeline

    fail = {"on": False}

    def pipeline(*args, **kwargs):
        if fail["on"]:
            raise RuntimeError("ffmpeg failed")
        return run_pipeline(*args, **kwargs)

    settings = Settings(storage_dir=tmp_path / "s", device="cpu")
    with TestClient(create_app(settings, pipeline=pipeline)) as client:
        video = upload(client, tiny_video).json()
        job_id = client.post("/jobs", json={"video_id": video["id"]}).json()["id"]
        assert wait_for(client, job_id)["status"] == "done"
        fail["on"] = True
        client.post(f"/jobs/{job_id}/render", json={"overlays": ["boxes"]})
        assert wait_for(client, job_id)["status"] == "failed"
        assert client.get(f"/jobs/{job_id}/record").status_code == 200  # old outputs kept
        fail["on"] = False
        assert client.post(f"/jobs/{job_id}/render", json={"overlays": []}).status_code == 202
        assert wait_for(client, job_id)["status"] == "done"
        storage = client.app.state.storage

    # A re-render interrupted by a restart comes back as done, a first run as failed.
    job = storage.load_jobs()[0]
    job.status = "running"
    storage.save_job(job)
    restarted = JobManager(storage, config={}, device="cpu")
    assert restarted.get(job_id).status == "done"


def test_rerender_resets_started_at_and_restart_restores_last_run(
    tmp_path: Path, tiny_video: Path
) -> None:
    from shuttlesense.api.jobs import JobManager

    with make_client(tmp_path) as client:
        video = upload(client, tiny_video).json()
        job = client.post("/jobs", json={"video_id": video["id"], "overlays": ["trail"]}).json()
        done = wait_for(client, job["id"])
        storage = client.app.state.storage
        manager = client.app.state.jobs
        manager.stop()  # keep the re-render queued
        queued = manager.rerender(job["id"], ["boxes"])
        assert queued.started_at is None and queued.overlays == ["boxes"]

    # Interrupted by a restart: done again, describing the outputs of the last run.
    restarted = JobManager(storage, config={}, device="cpu")
    job_now = restarted.get(job["id"])
    assert job_now.status == "done"
    assert job_now.overlays == ["trail"]
    assert [s.status for s in job_now.stages] == [s["status"] for s in done["stages"]]


def test_failed_rerender_keeps_overlays_of_the_last_run(tmp_path: Path, tiny_video: Path) -> None:
    from shuttlesense.pipeline import run_pipeline

    fail = {"on": False}

    def pipeline(*args, **kwargs):
        if fail["on"]:
            raise RuntimeError("ffmpeg failed")
        return run_pipeline(*args, **kwargs)

    settings = Settings(storage_dir=tmp_path / "s", device="cpu")
    with TestClient(create_app(settings, pipeline=pipeline)) as client:
        video = upload(client, tiny_video).json()
        job = client.post("/jobs", json={"video_id": video["id"], "overlays": ["trail"]}).json()
        assert wait_for(client, job["id"])["status"] == "done"
        fail["on"] = True
        client.post(f"/jobs/{job['id']}/render", json={"overlays": ["boxes"]})
        failed = wait_for(client, job["id"])
        assert failed["status"] == "failed" and failed["overlays"] == ["trail"]
        assert failed["finished_at"] is not None


def test_storage_sweeps_leftovers_of_interrupted_deletes(tmp_path: Path) -> None:
    from shuttlesense.api.storage import Storage

    root = tmp_path / "s"
    storage = Storage(root)
    kept_video = storage.video_dir("a" * 12)
    gone_video = storage.video_dir("b" * 12)
    kept_job = storage.job_dir("c" * 12)
    gone_job = storage.job_dir("d" * 12)
    for d in (kept_video, gone_video, kept_job, gone_job):
        d.mkdir(parents=True)
        (d / "annotated.mp4").write_bytes(b"x")  # a file the delete could not remove
    (kept_video / "meta.json").write_text("{}")
    (kept_job / "job.json").write_text("{}")
    Storage(root)  # server restart
    assert kept_video.exists() and kept_job.exists()
    assert not gone_video.exists() and not gone_job.exists()


def test_doubles_job_reaches_the_record_and_the_cache(tmp_path: Path, tiny_video: Path) -> None:
    from shuttlesense.cache import initial_key
    from shuttlesense.config import court_type, with_court

    with make_client(tmp_path, fake_pipeline=True) as client:
        vid = upload(client, tiny_video).json()["id"]
        body = {"video_id": vid, "referee": True, "court_corners_px": CORNERS,
                "court": "doubles"}  # fmt: skip
        job = client.post("/jobs", json=body).json()
        assert job["court"] == "doubles"
        assert wait_for(client, job["id"])["status"] == "done"
        record = client.get(f"/jobs/{job['id']}/record").json()
        assert record["frames"][0]["players"]["near_2"] is not None
        assert record["hits"][0]["hitter"] == "near_1"
        assert client.post("/jobs", json={**body, "court": "mixed"}).status_code == 422
    # Singles cache keys stay as they were; doubles gets its own.
    assert court_type({}) == "singles" and court_type(with_court({}, "doubles")) == "doubles"
    assert initial_key(tiny_video, {}) == initial_key(tiny_video, {"court": "singles"})
    assert initial_key(tiny_video, {}) != initial_key(tiny_video, with_court({}, "doubles"))


def test_doubles_first_server_and_receiver_reach_the_score(
    tmp_path: Path, tiny_video: Path
) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        vid = upload(client, tiny_video).json()["id"]
        body = {"video_id": vid, "referee": True, "court_corners_px": CORNERS, "court": "doubles",
                "first_server_id": "far_2", "first_receiver_id": "near_2"}  # fmt: skip
        job = client.post("/jobs", json=body).json()
        assert job["first_server"] == "far" and job["first_server_id"] == "far_2"
        assert wait_for(client, job["id"])["status"] == "done"
        record = client.get(f"/jobs/{job['id']}/record").json()
        assert record["rallies"][0]["server_id"] == "far_2"
        assert record["rallies"][0]["receiver_id"] == "near_2"
        # Near won: near serves next and nobody moved; near_1 stands in near's left (odd) court.
        assert record["score"]["server_id"] == "near_1"
        for bad in ({"first_receiver_id": None}, {"first_receiver_id": "far_1"},
                    {"first_server": "near"}):  # fmt: skip
            assert client.post("/jobs", json={**body, **bad}).status_code == 422


def test_fake_doubles_job_with_only_a_first_server_completes(
    tmp_path: Path, tiny_video: Path
) -> None:
    """The golden record's service slots must not clash with the user's first server."""
    with make_client(tmp_path, fake_pipeline=True) as client:
        vid = upload(client, tiny_video).json()["id"]
        body = {"video_id": vid, "referee": True, "court_corners_px": CORNERS,
                "court": "doubles", "first_server": "far"}  # fmt: skip
        job = client.post("/jobs", json=body).json()
        assert wait_for(client, job["id"])["status"] == "done"
        record = client.get(f"/jobs/{job['id']}/record").json()
        assert record["score"]["first_server"] == "far"
        assert record["score"].get("first_server_id") is None
        assert all(r.get("server_id") is None for r in record["rallies"])


def test_service_slots_are_for_doubles_jobs_only(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        vid = upload(client, tiny_video).json()["id"]
        body = {"video_id": vid, "referee": True, "court_corners_px": CORNERS,
                "first_server_id": "near_1", "first_receiver_id": "far_1"}  # fmt: skip
        assert client.post("/jobs", json=body).status_code == 422
        assert client.post("/jobs", json={**body, "court": "doubles"}).status_code == 202


def test_a_singles_job_stays_singles_with_a_doubles_line_call_config(tmp_path: Path) -> None:
    from shuttlesense.api.jobs import JobManager
    from shuttlesense.api.models import Job
    from shuttlesense.api.storage import Storage
    from shuttlesense.config import court_type

    config = {"stages": {"referee": {"line_call": {"court": "doubles"}}}}
    jobs = JobManager(
        Storage(tmp_path / "s"), config=config, device="cpu", pipeline=lambda *a, **k: None
    )
    singles = Job(id="a" * 12, video_id="v" * 12)
    doubles = Job(id="b" * 12, video_id="v" * 12, court="doubles")
    assert court_type(jobs.job_config(singles)) == "singles"
    assert court_type(jobs.job_config(doubles)) == "doubles"
    # Without a doubles setting a singles config is left exactly as it was.
    plain = JobManager(
        Storage(tmp_path / "t"), config={"x": 1}, device="cpu", pipeline=lambda *a, **k: None
    )
    assert "court" not in plain.job_config(singles)


def test_delete_waits_for_an_edit_in_progress(tmp_path: Path, tiny_video: Path) -> None:
    """An edit holding the job lock finishes first; the folder is not recreated after."""
    import threading

    with make_client(tmp_path, fake_pipeline=True) as client:
        vid = upload(client, tiny_video).json()["id"]
        job = client.post("/jobs", json={"video_id": vid}).json()
        assert wait_for(client, job["id"])["status"] == "done"
        jobs = client.app.state.jobs
        lock = jobs.job_lock(job["id"])
        lock.acquire()
        done = threading.Event()
        worker = threading.Thread(target=lambda: (jobs.cancel_or_delete(job["id"]), done.set()))
        worker.start()
        assert not done.wait(0.3)  # blocked by the edit
        assert jobs.get(job["id"]) is not None
        lock.release()
        worker.join(5)
        assert done.is_set() and jobs.get(job["id"]) is None


def test_doubles_service_for_a_later_game_is_kept_through_a_rerender(
    tmp_path: Path, tiny_video: Path
) -> None:
    """D23: POST /jobs/{id}/score/service names game 2's first server and receiver."""
    with make_client(tmp_path, fake_pipeline=True) as client:
        vid = upload(client, tiny_video).json()["id"]
        body = {"video_id": vid, "referee": True, "court_corners_px": CORNERS,
                "court": "doubles", "best_of": 3, "first_server_id": "near_1",
                "first_receiver_id": "far_1"}  # fmt: skip
        job = client.post("/jobs", json=body).json()
        assert wait_for(client, job["id"])["status"] == "done"
        url = f"/jobs/{job['id']}/score"
        score = client.get(f"/jobs/{job['id']}/record").json()["score"]
        while score["game"] == 1:  # far wins game 1 on awarded points
            score = client.post(f"{url}/award", json={"winner": "far"}).json()["score"]
        assert score.get("server_id") is None  # game 2: unknown until named
        named = {"game": 2, "server_id": "far_2", "receiver_id": "near_2"}
        score = client.post(f"{url}/service", json=named).json()["score"]
        assert (score["server_id"], score["receiver_id"]) == ("far_2", "near_2")
        assert score["game_service"] == [named]
        assert client.get(f"/jobs/{job['id']}").json()["game_service"] == [named]
        for bad in ({**named, "game": 1}, {**named, "receiver_id": None},
                    {**named, "receiver_id": "far_1"}):  # fmt: skip
            assert client.post(f"{url}/service", json=bad).status_code == 422
        client.post(f"/jobs/{job['id']}/render", json={"overlays": ["score"]})
        assert wait_for(client, job["id"])["status"] == "done"
        score = client.get(f"/jobs/{job['id']}/record").json()["score"]
        assert score["game_service"] == [named] and score["server_id"] == "far_2"
        cleared = client.post(f"{url}/service", json={"game": 2}).json()["score"]
        assert cleared.get("server_id") is None and "game_service" not in cleared


def test_singles_jobs_have_no_service_order(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        vid = upload(client, tiny_video).json()["id"]
        body = {"video_id": vid, "referee": True, "court_corners_px": CORNERS}
        job = client.post("/jobs", json=body).json()
        assert wait_for(client, job["id"])["status"] == "done"
        named = {"game": 2, "server_id": "far_2", "receiver_id": "near_2"}
        assert client.post(f"/jobs/{job['id']}/score/service", json=named).status_code == 409


def test_stroke_model_is_a_job_option(tmp_path: Path, tiny_video: Path) -> None:
    from shuttlesense.api.models import Job

    with make_client(tmp_path, fake_pipeline=True) as client:
        assert client.get("/health").json()["stroke_models"] == ["cnn", "lstm", "rf"]
        vid = upload(client, tiny_video).json()["id"]
        assert client.post("/jobs", json={"video_id": vid}).json()["stroke_model"] == "cnn"
        job = client.post("/jobs", json={"video_id": vid, "stroke_model": "rf"}).json()
        assert job["stroke_model"] == "rf"
        assert wait_for(client, job["id"])["status"] == "done"
        assert client.get(f"/jobs/{job['id']}/record").json()["stroke_model"] == "rf"
        assert (
            client.post("/jobs", json={"video_id": vid, "stroke_model": "svm"}).status_code == 422
        )

        jobs = client.app.state.jobs
        config = jobs.job_config(jobs.get(job["id"]))
        assert config["stages"]["strokes"]["algorithm"] == "rf"
        assert jobs.config.get("stages", {}).get("strokes", {}).get("algorithm") != "rf"
    # A job.json written before the option existed loads as a CNN job.
    old = {"id": "a" * 32, "video_id": "b" * 32}
    assert Job.model_validate(old).stroke_model == "cnn"


def test_job_without_a_stroke_model_uses_the_configured_one(
    tmp_path: Path, tiny_video: Path
) -> None:
    config = tmp_path / "pipeline.yaml"
    config.write_text("stages:\n  strokes:\n    algorithm: lstm\n", encoding="utf-8")
    with make_client(tmp_path, fake_pipeline=True, config=config) as client:
        vid = upload(client, tiny_video).json()["id"]
        assert client.post("/jobs", json={"video_id": vid}).json()["stroke_model"] == "lstm"
        job = client.post("/jobs", json={"video_id": vid, "stroke_model": "cnn"}).json()
        assert job["stroke_model"] == "cnn"


def test_health_lists_only_installed_stroke_models(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from shuttlesense.strokes import registry

    monkeypatch.setattr(registry, "BACKEND_DIR", tmp_path)
    with make_client(tmp_path) as client:
        assert client.get("/health").json()["stroke_models"] == []
        (tmp_path / "weights" / "strokes").mkdir(parents=True)
        (tmp_path / "weights" / "strokes" / "stroke_rf.npz").write_bytes(b"x")
        assert client.get("/health").json()["stroke_models"] == ["rf"]  # no restart needed


def test_switching_the_stroke_model_reruns_only_strokes_onward(tmp_path: Path) -> None:
    from shuttlesense import cache
    from shuttlesense.config import with_stroke_model

    base = {"stages": {"tracking": {"a": 1}, "strokes": {"weights": "w.pt"}}}
    other = with_stroke_model(base, "lstm")
    assert "algorithm" not in base["stages"]["strokes"]  # the server config is not changed
    assert cache.key_config("tracking", base["stages"]) == cache.key_config(
        "tracking", other["stages"]
    )
    assert cache.key_config("strokes", base["stages"]) != cache.key_config(
        "strokes", other["stages"]
    )


def test_cli_stroke_model_flag(tmp_path: Path, tiny_video: Path) -> None:
    import json

    from shuttlesense.run import build_parser, main

    main(["--video", str(tiny_video), "--out", str(tmp_path / "out"), "--fake",
          "--stroke-model", "lstm"])  # fmt: skip
    record = json.loads((tmp_path / "out" / "record.json").read_text(encoding="utf-8"))
    assert record["stroke_model"] == "lstm"
    with pytest.raises(SystemExit):
        build_parser().parse_args(["--video", "v", "--out", "o", "--stroke-model", "svm"])


@pytest.mark.parametrize("rendered", [False, True])
def test_restart_during_a_live_render_keeps_the_session_openable(
    tmp_path: Path, rendered: bool
) -> None:
    from shuttlesense.api.jobs import JobManager
    from shuttlesense.api.models import Job
    from shuttlesense.api.storage import Storage

    storage = Storage(tmp_path / "s")
    # What LiveManager._save leaves on disk while the annotated video renders.
    job = Job(id="a" * 12, video_id="b" * 12, status="running", current_stage="render", mode="live")
    storage.save_job(job)
    for name in ("record.json", "summary.json", "hits.csv", "rallies.csv"):
        (storage.job_dir(job.id) / name).write_text("{}")
    if rendered:
        (storage.job_dir(job.id) / "annotated.mp4").write_bytes(b"x")

    restarted = JobManager(storage, config={}, device="cpu").get(job.id)
    assert restarted.status == ("done" if rendered else "failed")
    assert restarted.error == (None if rendered else "render interrupted")
    assert restarted.current_stage is None and restarted.finished_at is not None
    assert restarted.outputs.record and restarted.outputs.summary and restarted.outputs.hits_csv
    assert restarted.outputs.video is rendered
    assert storage.load_jobs()[0].outputs.record  # saved, not only in memory


def test_award_frame_must_be_inside_the_video(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video)
        frames = client.get(f"/jobs/{job_id}/record").json()["num_frames"]

        def award(frame: int) -> int:
            body = {"winner": "far", "frame": frame}
            return client.post(f"/jobs/{job_id}/score/award", json=body).status_code

        assert award(-1) == 422
        assert award(frames) == 400
        assert client.get(f"/jobs/{job_id}/record").json()["score"]["corrections"] == []
        assert award(frames - 1) == 200


def test_deleting_a_job_drops_its_edit_lock(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video)
        jobs = client.app.state.jobs
        assert client.post(f"/jobs/{job_id}/score/award", json={"winner": "far"}).status_code == 200
        assert job_id in jobs._job_locks
        assert client.delete(f"/jobs/{job_id}").status_code == 204
        assert job_id not in jobs._job_locks
        jobs.job_lock(job_id)  # a late edit of the deleted job, e.g. a coach answer being saved
        assert client.delete(f"/jobs/{'0' * 12}").status_code == 404
        assert jobs._job_locks == {}


def test_access_token_is_kept_out_of_the_logs(tmp_path: Path) -> None:
    import logging

    from shuttlesense.api.main import RedactToken

    def logged(msg: str, args: tuple | None) -> str:
        record = logging.LogRecord("uvicorn.access", logging.INFO, "", 0, msg, args, None)
        assert RedactToken().filter(record)
        return record.getMessage()

    access = ("127.0.0.1:5000", "GET", "/jobs/abc/video?token=s3cret&download=1", "1.1", 200)
    assert logged('%s - "%s %s HTTP/%s" %d', access) == (
        '127.0.0.1:5000 - "GET /jobs/abc/video?token=***&download=1 HTTP/1.1" 200'
    )
    socket = ("127.0.0.1:5000", "/live?token=s3cret")
    assert logged('%s - "WebSocket %s" [accepted]', socket) == (
        '127.0.0.1:5000 - "WebSocket /live?token=***" [accepted]'
    )
    assert logged("GET /videos/abc/frames/0?w=1&token=s3cret done", None) == (
        "GET /videos/abc/frames/0?w=1&token=*** done"
    )
    assert logged("GET /jobs?limit=5", None) == "GET /jobs?limit=5"

    for _ in range(2):  # every app installs it; the loggers must not collect copies
        create_app(Settings(storage_dir=tmp_path / "storage", device="cpu"))
    for name in ("uvicorn.access", "uvicorn.error"):
        filters = logging.getLogger(name).filters
        assert sum(isinstance(f, RedactToken) for f in filters) == 1


def test_award_after_the_match_is_won_is_refused(tmp_path: Path, tiny_video: Path) -> None:
    """Once the match is won, a point given after it changes nothing: 409, nothing logged."""
    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video, start_score={"near": 20, "far": 0})
        for _ in range(25):
            res = client.post(f"/jobs/{job_id}/score/award", json={"winner": "near"})
            if res.status_code == 409:
                break
            assert res.status_code == 200
        assert res.status_code == 409
        record = client.get(f"/jobs/{job_id}/record").json()
        assert record["score"]["match_winner"] == "near"
        logged = len(record["score"]["corrections"])
        assert client.post(f"/jobs/{job_id}/score/award", json={"winner": "far"}).status_code == 409
        assert len(client.get(f"/jobs/{job_id}/record").json()["score"]["corrections"]) == logged


def test_job_joins_a_match_under_way_and_takes_reasons(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        vid = upload(client, tiny_video).json()["id"]
        body = {"video_id": vid, "referee": True, "court_corners_px": CORNERS, "best_of": 3}
        bad = client.post("/jobs", json={**body, "start_games": {"near": 2, "far": 0}})
        assert bad.status_code == 400
        job = client.post("/jobs", json={**body, "start_games": {"near": 1, "far": 0}}).json()
        assert job["start_games"] == {"near": 1, "far": 0}
        assert wait_for(client, job["id"])["status"] == "done"
        score = client.get(f"/jobs/{job['id']}/record").json()["score"]
        assert score["game"] >= 2 and score["start_games"] == {"near": 1, "far": 0}
        res = client.post(f"/jobs/{job['id']}/score/award",
                          json={"winner": "far", "reason": "service_fault"})  # fmt: skip
        assert res.json()["score"]["corrections"][-1]["reason"] == "service_fault"
        bad = client.post(f"/jobs/{job['id']}/score/award", json={"winner": "far", "reason": "x"})
        assert bad.status_code == 422


def test_concede_ends_the_match_and_undo_takes_it_back(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        job_id = _referee_job(client, tiny_video)
        before = client.get(f"/jobs/{job_id}/record").json()["score"]
        res = client.post(f"/jobs/{job_id}/score/concede", json={"winner": "far"})
        assert res.status_code == 200 and res.json()["score"]["match_winner"] == "far"
        assert client.post(f"/jobs/{job_id}/score/concede", json={"winner": "near"}).status_code \
            == 409  # fmt: skip
        undone = client.post(f"/jobs/{job_id}/score/undo").json()["score"]
        assert undone["match_winner"] == before["match_winner"]
