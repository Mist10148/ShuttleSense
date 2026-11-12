"""Coach chat with a fake Claude client: no network, no key."""

from __future__ import annotations

import json
import time
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings
from shuttlesense.coach.chat import ChatSettings, build_request, validate_citations
from shuttlesense.coach.digest import build_digest
from shuttlesense.fake import load_golden
from shuttlesense.schema import ChatMessage, Moment


class FakeStream:
    def __init__(self, chunks: list[str], stop_reason: str) -> None:
        self.chunks, self.stop_reason = chunks, stop_reason

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc) -> None:
        return None

    @property
    def text_stream(self):
        async def gen():
            for c in self.chunks:
                yield c

        return gen()

    async def get_final_message(self):
        return SimpleNamespace(stop_reason=self.stop_reason)


class FakeClient:
    """Stands in for anthropic.AsyncAnthropic: records requests, replays canned answers."""

    def __init__(self, chunks=("Your smash elbow was bent ", "[t=1.5s] and [t=9.9s]."),
                 stop_reason="end_turn", error: Exception | None = None) -> None:  # fmt: skip
        self.requests: list[dict] = []
        self.chunks, self.stop_reason, self.error = list(chunks), stop_reason, error
        self.beta = SimpleNamespace(messages=SimpleNamespace(stream=self._stream))

    def _stream(self, **kwargs):
        self.requests.append(kwargs)
        if self.error is not None:
            raise self.error
        return FakeStream(self.chunks, self.stop_reason)


def test_digest_lists_data_and_moments_but_no_pixels() -> None:
    record = load_golden()
    digest = build_digest(record)
    assert "t=1.5s hit 2 by near | smash (86%)" in digest.text
    assert "elbow_extension FAIL (128)" in digest.text
    assert "line call at t=1.8s: IN, +190 cm" in digest.text
    assert "TOP FIX" in digest.text
    assert "homography" not in digest.text and "keypoints" not in digest.text
    assert {round(m.time_s, 3) for m in digest.moments} >= {0.167, 0.833, 1.5, 1.833}
    assert build_digest(record).text == digest.text  # deterministic, so it caches


def test_digest_explains_doubles_partners() -> None:
    record = load_golden()
    assert "Each side has two partners" not in build_digest(record).text
    frame = next(f for f in record.frames if f.players.near is not None)
    frame.players.near_2 = frame.players.near.model_copy(deep=True)
    record.hits[2].hitter = "near_2"
    record.rallies[0].server_id, record.rallies[0].receiver_id = "near_1", "far_2"
    text = build_digest(record).text
    assert "near_1 and near_2, far_1 and far_2" in text
    assert "t=1.5s hit 2 by near_2 | smash" in text
    assert "served by near_1 to far_2" in text


def test_long_sessions_are_shortened_per_rally() -> None:
    digest = build_digest(load_golden(), max_chars=900)
    assert digest.shortened and len(digest.text) <= 900
    assert "per-rally summaries" in digest.text


def test_citations_are_checked_against_the_data() -> None:
    moments = [Moment(frame=45, time_s=1.5, hit_id=2), Moment(frame=55, time_s=1.833)]
    text, cites = validate_citations("Bent arm [t=1.5s], also [t=1.8s] and [t=42.0s].", moments)
    assert text == "Bent arm [t=1.5s], also [t=1.8s] and."
    assert [c.frame for c in cites] == [45, 55]


def test_request_caches_the_digest_and_keeps_turns_alternating() -> None:
    digest = build_digest(load_golden())
    history = [
        ChatMessage(role="assistant", text="stray", at="2026-10-31T10:00:00Z"),
        ChatMessage(role="user", text="q1", at="2026-10-31T10:00:00Z"),
        ChatMessage(role="assistant", text="a1", at="2026-10-31T10:00:01Z"),
    ]
    req = build_request(digest, history, "q2", ChatSettings())
    assert req["model"] == "claude-opus-5-5" and req["output_config"] == {"effort": "medium"}
    assert req["system"][1]["cache_control"] == {"type": "ephemeral"}
    assert "Session data:" in req["system"][1]["text"]
    assert [m["role"] for m in req["messages"]] == ["user", "assistant", "user"]
    assert req["fallbacks"] == "default"
    assert "diagnose" in req["system"][0]["text"]


def _done_job(client: TestClient, video: Path) -> str:
    with video.open("rb") as f:
        vid = client.post("/videos", files={"file": ("clip.mp4", f, "video/mp4")}).json()["id"]
    job = client.post(
        "/jobs",
        json={
            "video_id": vid,
            "referee": True,
            "court_corners_px": [[10, 80], [150, 80], [120, 20], [40, 20]],
        },
    )
    job_id = job.json()["id"]
    for _ in range(200):
        if client.get(f"/jobs/{job_id}").json()["status"] == "done":
            return job_id
        time.sleep(0.05)
    raise AssertionError("job did not finish")


def _events(res) -> list[dict]:
    return [json.loads(line[6:]) for line in res.text.splitlines() if line.startswith("data: ")]


def _client(tmp_path: Path, chat_client=None, **settings) -> TestClient:
    settings = Settings(storage_dir=tmp_path / "s", device="cpu", fake_pipeline=True, **settings)
    return TestClient(create_app(settings, chat_client=chat_client))


def test_chat_streams_and_saves_validated_answers(tmp_path: Path, tiny_video: Path) -> None:
    fake = FakeClient()
    with _client(tmp_path, fake) as client:
        assert client.get("/health").json()["chat_available"] is True
        job_id = _done_job(client, tiny_video)
        res = client.post(f"/jobs/{job_id}/chat", json={"message": "Why did my smash land short?"})
        assert res.status_code == 200 and res.headers["content-type"].startswith(
            "text/event-stream"
        )
        events = _events(res)
        assert [e["type"] for e in events] == ["delta", "delta", "done"]
        done = events[-1]["message"]
        assert (
            "[t=9.9s]" not in done["text"]
            and "not professional coaching" in events[-1]["disclaimer"]
        )
        record = client.get(f"/jobs/{job_id}/record").json()
        assert [m["role"] for m in record["chat"]["messages"]] == ["user", "assistant"]
        assert record["chat"]["messages"][1]["citations"] == done["citations"]
        # The second question carries the first exchange.
        client.post(f"/jobs/{job_id}/chat", json={"message": "And my clears?"})
        assert [m["content"] for m in fake.requests[1]["messages"]][0].startswith("Why did")


def test_chat_off_without_key(tmp_path: Path, tiny_video: Path, monkeypatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with _client(tmp_path) as client:
        assert client.get("/health").json()["chat_available"] is False
        job_id = _done_job(client, tiny_video)
        res = client.post(f"/jobs/{job_id}/chat", json={"message": "hi"})
        assert res.status_code == 503 and "no Claude API key" in res.json()["detail"]


def test_message_limit_and_validation(tmp_path: Path, tiny_video: Path) -> None:
    with _client(tmp_path, FakeClient(), chat_max_messages=1) as client:
        job_id = _done_job(client, tiny_video)
        assert client.post(f"/jobs/{job_id}/chat", json={"message": ""}).status_code == 422
        assert client.post(f"/jobs/{job_id}/chat", json={"message": "  \n"}).status_code == 422
        assert client.post(f"/jobs/{job_id}/chat", json={"message": "x" * 1001}).status_code == 422
        assert client.post(f"/jobs/{job_id}/chat", json={"message": "one"}).status_code == 200
        res = client.post(f"/jobs/{job_id}/chat", json={"message": "two"})
        assert res.status_code == 429


def test_one_question_at_a_time_per_job(tmp_path: Path, tiny_video: Path) -> None:
    with _client(tmp_path, FakeClient()) as client:
        job_id = _done_job(client, tiny_video)
        client.app.state.chat_answering[job_id] = time.monotonic()  # an answer is streaming
        assert client.post(f"/jobs/{job_id}/chat", json={"message": "q"}).status_code == 409
        client.app.state.chat_answering[job_id] = time.monotonic() - 301  # a stale mark
        assert client.post(f"/jobs/{job_id}/chat", json={"message": "q"}).status_code == 200
        assert job_id not in client.app.state.chat_answering


def test_no_rerender_while_an_answer_is_being_written(tmp_path: Path, tiny_video: Path) -> None:
    with _client(tmp_path, FakeClient()) as client:
        job_id = _done_job(client, tiny_video)
        client.app.state.chat_answering[job_id] = time.monotonic()
        res = client.post(f"/jobs/{job_id}/render", json={"overlays": []})
        assert res.status_code == 409 and "coach answer" in res.json()["detail"]
        client.app.state.chat_answering.pop(job_id)
        assert client.post(f"/jobs/{job_id}/render", json={"overlays": []}).status_code == 202


def test_chat_survives_a_rerender(tmp_path: Path, tiny_video: Path) -> None:
    with _client(tmp_path, FakeClient()) as client:
        job_id = _done_job(client, tiny_video)
        client.post(f"/jobs/{job_id}/chat", json={"message": "Why did my smash land short?"})
        assert client.post(f"/jobs/{job_id}/render", json={"overlays": []}).status_code == 202
        for _ in range(200):
            if client.get(f"/jobs/{job_id}").json()["status"] == "done":
                break
            time.sleep(0.05)
        record = client.get(f"/jobs/{job_id}/record").json()
        assert [m["role"] for m in record["chat"]["messages"]] == ["user", "assistant"]


@pytest.mark.parametrize(
    ("stop_reason", "expect"), [("refusal", "can't help"), ("max_tokens", "cut short")]
)
def test_refusal_and_truncation(tmp_path: Path, tiny_video: Path, stop_reason, expect) -> None:
    with _client(tmp_path, FakeClient(stop_reason=stop_reason)) as client:
        job_id = _done_job(client, tiny_video)
        done = _events(client.post(f"/jobs/{job_id}/chat", json={"message": "q"}))[-1]
        assert expect in done["message"]["text"]


def test_api_errors_become_readable_events(tmp_path: Path, tiny_video: Path) -> None:
    import anthropic
    import httpx

    error = anthropic.APIConnectionError(request=httpx.Request("POST", "https://x"))
    with _client(tmp_path, FakeClient(error=error)) as client:
        job_id = _done_job(client, tiny_video)
        events = _events(client.post(f"/jobs/{job_id}/chat", json={"message": "q"}))
        detail = "The backend cannot reach the Claude API (offline?)."
        assert events == [{"type": "error", "status": 503, "detail": detail}]
        assert client.get(f"/jobs/{job_id}/record").json()["chat"] is None
