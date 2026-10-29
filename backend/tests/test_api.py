"""API round trip with the stub pipeline: upload -> job -> record -> exports -> delete."""

from __future__ import annotations

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

    assert client.get(f"/jobs/{job['id']}/hits.csv").text.startswith("id,frame")
    assert client.get(f"/jobs/{job['id']}/video").status_code == 404  # render is a stub
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
