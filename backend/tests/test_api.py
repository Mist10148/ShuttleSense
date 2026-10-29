"""API round trip with the stub pipeline: upload -> job -> record -> exports -> delete."""

from __future__ import annotations

import codecs
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
        assert rallies_csv.splitlines()[1].endswith(",0,1")


def test_correction_409_without_referee(tmp_path: Path, tiny_video: Path) -> None:
    with make_client(tmp_path, fake_pipeline=True) as client:
        vid = upload(client, tiny_video).json()["id"]
        job = client.post("/jobs", json={"video_id": vid}).json()
        assert wait_for(client, job["id"])["status"] == "done"
        res = client.patch(f"/jobs/{job['id']}/score", json={"rally_index": 0, "winner": "far"})
        assert res.status_code == 409
