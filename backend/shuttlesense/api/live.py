"""WS /live: live sessions (F19, D16). Protocol in docs/API.md.

Client -> server: a JSON `start` (or `resume`), then binary frames (12-byte header: uint32
frame index and float64 capture time in ms, little-endian, then one JPEG), JSON
`override`, `correct` and `stop`. Server -> client: JSON events (`started`, `frame`, `hit`,
`rally`, `line_call`, `score`, `stats`, `degraded`, `saved`, `error`).
"""

from __future__ import annotations

import asyncio
import contextlib
import hmac
import logging
import struct
import threading
import time
from dataclasses import dataclass
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from shuttlesense.api.models import Job, VideoInfoOut, utcnow
from shuttlesense.api.storage import Storage, new_id
from shuttlesense.schema import ScorePair
from shuttlesense.stream.session import LiveSession, StartRequest

log = logging.getLogger(__name__)

HEADER = struct.Struct("<Id")
START_TIMEOUT_S = 10.0

ws_router = APIRouter()


class LiveBusy(Exception):
    """The GPU is taken by a running job or another live session."""


class SessionGone(Exception):
    """No detached session with that id (it expired, was saved, or is still attached)."""


@dataclass
class _Entry:
    session: LiveSession
    video_id: str
    attached: bool = True
    expiry: asyncio.Task | None = None


class LiveManager:
    """At most one live session at a time; a dropped session waits ttl_s for a resume."""

    def __init__(self, app_state: Any, *, fake: bool, ttl_s: float) -> None:
        self.state = app_state
        self.fake = fake
        self.ttl_s = ttl_s
        self.entries: dict[str, _Entry] = {}
        self.lock = threading.Lock()

    @property
    def storage(self) -> Storage:
        return self.state.storage

    def create(self, request: StartRequest) -> _Entry:
        jobs = self.state.jobs
        if self.entries or not jobs.gpu.acquire(blocking=False):
            raise LiveBusy
        try:
            video_id = new_id()
            recording = self.storage.video_dir(video_id) / "source.mp4"
            session = self._session(new_id(), request, recording)
        except Exception:
            jobs.gpu.release()
            raise
        entry = _Entry(session=session, video_id=video_id)
        self.entries[session.id] = entry
        return entry

    def _session(self, session_id: str, request: StartRequest, recording) -> LiveSession:
        from shuttlesense.stream.session import LIVE_DEFAULTS, normalized_size

        config = self.state.jobs.config
        live = {**LIVE_DEFAULTS, **(config.get("live") or {})}
        size = normalized_size(request.width, request.height, int(live["target_height"]))
        corners = None
        if request.corners:
            sx, sy = size[0] / request.width, size[1] / request.height
            corners = [(x * sx, y * sy) for x, y in request.corners]
        classify = None
        if self.fake:
            # The camera is ignored: synthetic rallies replayed on a synthetic court.
            from shuttlesense.stream.analyzer import planned_classifier
            from shuttlesense.stream.perception import ReplayPerception
            from shuttlesense.stream.synthetic import CORNERS, HEIGHT, WIDTH, synthetic_record
            from shuttlesense.stream.synthetic import planned_strokes as planned

            record, truth = synthetic_record()
            perception = ReplayPerception(record, size)
            corners = [(x * size[0] / WIDTH, y * size[1] / HEIGHT) for x, y in CORNERS]
            classify = planned_classifier(planned(truth), period=len(record.frames))
        else:
            from shuttlesense.stream.perception import ModelPerception

            perception = ModelPerception(
                config, self.state.jobs.device, size, corners, int(live["background_frames"])
            )
        return LiveSession(
            session_id=session_id, request=request, config=config, perception=perception,
            court_corners=corners, recording=recording, device=self.state.jobs.device,
            classify=classify,
        )  # fmt: skip

    def resume(self, session_id: str) -> _Entry:
        entry = self.entries.get(session_id)
        if entry is None or entry.attached:
            raise SessionGone(session_id)
        if entry.expiry is not None:
            entry.expiry.cancel()
            entry.expiry = None
        entry.attached = True
        return entry

    def detach(self, entry: _Entry) -> None:
        """The socket dropped without `stop`: keep the session for ttl_s, then save it."""
        entry.attached = False

        async def expire() -> None:
            await asyncio.sleep(self.ttl_s)
            if not entry.attached and entry.session.id in self.entries:
                await asyncio.to_thread(self.finish, entry)

        entry.expiry = asyncio.get_running_loop().create_task(expire())

    def finish(self, entry: _Entry) -> Job | None:
        """Save the session as a normal job (None when no frame arrived) and free the GPU."""
        with self.lock:
            if self.entries.pop(entry.session.id, None) is None:
                return None
        try:
            return self._save(entry)
        finally:
            self.state.jobs.gpu.release()

    def _save(self, entry: _Entry) -> Job | None:
        from shuttlesense.analytics import write_exports
        from shuttlesense.referee import save_corrections, save_overrides
        from shuttlesense.render import OVERLAYS

        session = entry.session
        if session.stats.received == 0:
            session.close()
            self.storage.delete_video(entry.video_id)
            return None
        record = session.finish()
        source = self.storage.video_dir(entry.video_id) / "source.mp4"
        name = session.request.name or f"Live session {utcnow():%Y-%m-%d %H:%M}"
        self.storage.save_video_meta(VideoInfoOut(
            id=entry.video_id, filename=f"{name}.mp4", size_bytes=source.stat().st_size,
            fps=record.fps, width=record.width, height=record.height,
            num_frames=record.num_frames, duration_s=round(record.num_frames / record.fps, 3),
        ))  # fmt: skip
        job_id = new_id()
        record.clip_id = job_id
        record.source_name = f"{name}.mp4"
        start = session.request.start_score
        job = Job(
            id=job_id, video_id=entry.video_id, status="running", current_stage="render",
            started_at=utcnow(), progress=0.9, mode="live", referee=True, start_score=start,
            court_corners_px=list(session.corners) if session.corners else None,
            overlays=list(OVERLAYS),
        )  # fmt: skip
        job_dir = self.storage.job_dir(job_id)
        job_dir.mkdir(parents=True, exist_ok=True)
        save_overrides(job_dir, session.analyzer.overrides)
        save_corrections(job_dir, session.analyzer.corrections)
        write_exports(record, job_dir)
        self.state.jobs.add(job)
        threading.Thread(target=self._render, args=(job, record, source), daemon=True).start()
        return job

    def _render(self, job: Job, record, source) -> None:
        """Annotated video for the saved session, off the socket's thread."""
        from shuttlesense.io import FrameReader
        from shuttlesense.render import render_video

        try:
            reader = FrameReader(source, target_height=record.height, max_fps=record.fps)
            render_video(record, reader, self.storage.job_dir(job.id) / "annotated.mp4",
                         overlays=job.overlays, config=self.state.jobs.config)  # fmt: skip
            self.state.jobs.finish_outside(job.id)
        except Exception as exc:  # the record is saved; only the video is missing
            log.exception("rendering live session %s failed", job.id)
            self.state.jobs.finish_outside(job.id, error=f"render failed: {exc}")

    async def shutdown(self) -> None:
        for entry in list(self.entries.values()):
            if entry.expiry is not None:
                entry.expiry.cancel()
            await asyncio.to_thread(self.finish, entry)


def _start_request(msg: dict[str, Any]) -> StartRequest:
    fps, width, height = float(msg["fps"]), int(msg["width"]), int(msg["height"])
    if not (1 <= fps <= 240 and 16 <= width <= 7680 and 16 <= height <= 4320):
        raise ValueError("fps, width or height out of range")
    corners = msg.get("corners")
    if corners is not None:
        from shuttlesense.court import validate_corners

        validate_corners(corners)
        corners = [(float(x), float(y)) for x, y in corners]
    score = msg.get("start_score")
    court = msg.get("court", "singles")
    if court not in ("singles", "doubles"):
        raise ValueError("court must be singles or doubles")
    return StartRequest(
        fps=fps, width=width, height=height, corners=corners, court=court, name=msg.get("name"),
        start_score=ScorePair(**score) if score else None,
    )  # fmt: skip


async def _error(ws: WebSocket, code: str, detail: str, close: int | None = None) -> None:
    with contextlib.suppress(Exception):
        await ws.send_json({"type": "error", "code": code, "detail": detail})
        if close is not None:
            await ws.close(code=close)


@ws_router.websocket("/live")
async def live(ws: WebSocket, token: str | None = None) -> None:
    settings = ws.app.state.settings
    await ws.accept()
    if settings.token and not (
        token and hmac.compare_digest(token.encode(), settings.token.encode())
    ):
        await _error(ws, "unauthorized", "missing or invalid token", close=4401)
        return
    manager: LiveManager = ws.app.state.live
    try:
        first = await asyncio.wait_for(ws.receive_json(), START_TIMEOUT_S)
        if first.get("type") == "resume":
            entry = manager.resume(str(first.get("session_id")))
        elif first.get("type") == "start":
            entry = await asyncio.to_thread(manager.create, _start_request(first))
        else:
            raise ValueError("first message must be start or resume")
    except LiveBusy:
        await _error(ws, "busy", "the GPU is busy with a job or another live session", 4409)
        return
    except SessionGone:
        await _error(ws, "not_found", "no session to resume (it expired or was saved)", 4404)
        return
    except (ValueError, TypeError, KeyError) as exc:
        await _error(ws, "bad_request", str(exc) or "bad start message", 4400)
        return
    except (TimeoutError, WebSocketDisconnect):
        return
    session = entry.session
    await ws.send_json({
        "type": "started", "session_id": session.id, "resumed": first["type"] == "resume",
        "fps": session.fps, "width": session.width, "height": session.height,
        "frames": len(session.analyzer.record.frames), "stages": session.perception.available,
        "corners": session.corners, "budget_ms": session.live["budget_ms"],
    })  # fmt: skip
    await _serve(ws, manager, entry)


async def _serve(ws: WebSocket, manager: LiveManager, entry: _Entry) -> None:
    session = entry.session
    queue: asyncio.Queue[tuple[str, Any]] = asyncio.Queue()

    async def receive() -> None:
        try:
            while True:
                msg = await ws.receive()
                if msg["type"] == "websocket.disconnect":
                    break
                if msg.get("bytes") is not None:
                    await queue.put(("frame", (msg["bytes"], time.monotonic())))
                elif msg.get("text") is not None:
                    import json

                    await queue.put(("control", json.loads(msg["text"])))
        except (WebSocketDisconnect, RuntimeError, ValueError):
            pass
        await queue.put(("closed", None))

    receiver = asyncio.create_task(receive())
    stopped = False
    try:
        while True:
            kind, payload = await queue.get()
            if kind == "closed":
                break
            if kind == "control":
                if payload.get("type") == "stop":
                    stopped = True
                    break
                await _send(ws, await asyncio.to_thread(_control, session, payload))
                continue
            # Only the newest waiting frame gets perception; older ones are recorded.
            frames = [payload]
            while not queue.empty():
                nxt = queue.get_nowait()
                if nxt[0] != "frame":
                    queue.put_nowait(nxt)  # keep controls for the next loop
                    break
                frames.append(nxt[1])
            events = await asyncio.to_thread(_frames, session, frames)
            await _send(ws, events)
    finally:
        receiver.cancel()
    if stopped:
        job = await asyncio.to_thread(manager.finish, entry)
        with contextlib.suppress(Exception):
            await ws.send_json({
                "type": "saved", "job_id": job.id if job else None,
                "video_id": job.video_id if job else None,
                "stats": session.stats.summary(),
            })  # fmt: skip
            await ws.close()
    else:
        manager.detach(entry)


def _frames(session: LiveSession, frames: list[tuple[bytes, float]]) -> list[dict]:
    events: list[dict] = []
    for i, (data, received) in enumerate(frames):
        if len(data) <= HEADER.size:
            events.append({"type": "error", "code": "bad_frame", "detail": "frame too short"})
            continue
        client_frame, ts = HEADER.unpack_from(data)
        jpeg = data[HEADER.size :]
        if i < len(frames) - 1:
            events += session.skip(jpeg, client_frame, ts)
        else:
            events += session.process(jpeg, client_frame, ts, received)
    return events


def _control(session: LiveSession, msg: dict[str, Any]) -> list[dict]:
    try:
        if msg.get("type") == "override" and msg.get("call") in ("in", "out"):
            return session.override(int(msg["line_call_id"]), msg["call"])
        if msg.get("type") == "correct" and msg.get("winner") in ("near", "far"):
            return session.correct(int(msg["rally_index"]), msg["winner"])
    except (KeyError, TypeError, ValueError):
        return [{"type": "error", "code": "not_found", "detail": "no such line call or rally"}]
    return [{"type": "error", "code": "bad_message", "detail": f"unknown message: {msg}"}]


async def _send(ws: WebSocket, events: list[dict]) -> None:
    for event in events:
        await ws.send_json(event)
