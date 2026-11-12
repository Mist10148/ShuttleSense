"""WS /live: live sessions (F19, D16). Protocol in docs/API.md.

Client -> server: a JSON `start` (or `resume`), then binary frames (12-byte header: uint32
frame index and float64 capture time in ms, little-endian, then one JPEG), JSON
`override`, `correct`, `award`, `undo` and `stop`. Server -> client: JSON events (`started`,
`frame`, `hit`, `rally`, `line_call`, `score`, `coaching`, `stats`, `degraded`, `saved`,
`error`).
"""

from __future__ import annotations

import asyncio
import contextlib
import hmac
import logging
import math
import struct
import threading
import time
from collections import deque
from dataclasses import dataclass
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from shuttlesense.api.models import Job, VideoInfoOut, utcnow
from shuttlesense.api.storage import Storage, new_id
from shuttlesense.schema import ScorePair
from shuttlesense.stream.analyzer import RallyInPlay
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
    job_id: str
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
        entry = _Entry(session=session, video_id=video_id, job_id=new_id())
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
            from shuttlesense.config import with_court
            from shuttlesense.stream.perception import ModelPerception

            perception = ModelPerception(
                with_court(config, request.court), self.state.jobs.device, size, corners,
                int(live["background_frames"]),
            )  # fmt: skip
        return LiveSession(
            session_id=session_id, request=request, config=config, perception=perception,
            court_corners=corners, recording=recording, device=self.state.jobs.device,
            classify=classify, resume_window_s=self.ttl_s,
        )  # fmt: skip

    def resume(self, session_id: str) -> _Entry:
        with self.lock:
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
        if entry.expiry is not None:  # one timer per session; an orphan would save it early
            entry.expiry.cancel()

        async def expire() -> None:
            await asyncio.sleep(self.ttl_s)
            # Claim the entry before leaving the event loop, so a resume arriving while the
            # session is being saved gets not_found instead of a half-saved session.
            with self.lock:
                if entry.attached or self.entries.get(entry.session.id) is not entry:
                    return
                del self.entries[entry.session.id]
            try:
                await asyncio.to_thread(self._save_and_release, entry)
            except Exception:  # the GPU is released; only this session's save is lost
                log.exception("saving expired live session %s failed", entry.session.id)

        entry.expiry = asyncio.get_running_loop().create_task(expire())

    def finish(self, entry: _Entry) -> Job | None:
        """Save the session as a normal job (None when no frame arrived) and free the GPU."""
        with self.lock:
            if self.entries.pop(entry.session.id, None) is None:
                return None
        return self._save_and_release(entry)

    def _save_and_release(self, entry: _Entry) -> Job | None:
        try:
            return self._save(entry)
        finally:
            self.state.jobs.gpu.release()

    def _save(self, entry: _Entry) -> Job | None:
        from shuttlesense.analytics import write_exports
        from shuttlesense.referee import save_corrections, save_overrides
        from shuttlesense.render import OVERLAYS

        session = entry.session
        if not session.analyzer.record.frames:  # nothing arrived, or nothing decoded
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
        job_id = entry.job_id
        record.clip_id = job_id
        record.source_name = f"{name}.mp4"
        start = session.request.start_score
        job = Job(
            id=job_id, video_id=entry.video_id, status="running", current_stage="render",
            started_at=utcnow(), progress=0.9, mode="live", referee=True, start_score=start,
            best_of=session.request.best_of, first_server=session.request.first_server,
            court=session.request.court, first_server_id=session.request.first_server_id,
            first_receiver_id=session.request.first_receiver_id,
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
            # An attached session may still be processing a frame on a worker thread; the
            # session lock makes finish() wait for it.
            entry.attached = False
            try:
                await asyncio.to_thread(self.finish, entry)
            except Exception:
                log.exception("saving live session %s at shutdown failed", entry.session.id)


MAX_NAME_LENGTH = 100  # the session name becomes the source name in History


def _start_request(msg: dict[str, Any]) -> StartRequest:
    fps, width, height = float(msg["fps"]), int(msg["width"]), int(msg["height"])
    if not (1 <= fps <= 240 and 16 <= width <= 7680 and 16 <= height <= 4320):
        raise ValueError("fps, width or height out of range")
    corners = msg.get("corners")
    if corners is not None:
        from shuttlesense.court import check_court_area, validate_corners

        validate_corners(corners)
        check_court_area(corners, (width, height))
        corners = [(float(x), float(y)) for x, y in corners]
    score = ScorePair(**msg["start_score"]) if msg.get("start_score") else None
    if score is not None:  # same checks as POST /jobs
        from shuttlesense.referee import validate_start_score

        validate_start_score(score)
    court = msg.get("court", "singles")
    if court not in ("singles", "doubles"):
        raise ValueError("court must be singles or doubles")
    best_of = msg.get("best_of", 1)
    if type(best_of) is not int or best_of not in (1, 3):  # not true or 1.0
        raise ValueError("best_of must be 1 or 3")
    name = msg.get("name")
    if name is not None and (not isinstance(name, str) or len(name) > MAX_NAME_LENGTH):
        raise ValueError(f"name must be text of at most {MAX_NAME_LENGTH} characters")
    first_server = msg.get("first_server")
    if first_server not in (None, "near", "far"):
        raise ValueError("first_server must be near or far")
    server_id, receiver_id = msg.get("first_server_id"), msg.get("first_receiver_id")
    slots = (None, "near_1", "near_2", "far_1", "far_2")
    if server_id not in slots or receiver_id not in slots:
        raise ValueError("first_server_id and first_receiver_id must be player slots")
    from shuttlesense.api.models import check_first_service

    check_first_service(first_server, server_id, receiver_id)
    if server_id and first_server is None:
        first_server = server_id[:-2]
    return StartRequest(
        fps=fps, width=width, height=height, corners=corners, court=court, name=name,
        start_score=score, best_of=best_of, first_server=first_server,
        first_server_id=server_id, first_receiver_id=receiver_id,
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
        if not isinstance(first, dict):
            raise ValueError("first message must be a JSON object")
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
    except Exception:  # e.g. a model failed to load; the GPU was released by create()
        log.exception("starting a live session failed")
        await _error(ws, "internal", "the live session could not start", 1011)
        return
    session = entry.session
    try:
        await ws.send_json({
            "type": "started", "session_id": session.id, "job_id": entry.job_id,
            "resumed": first["type"] == "resume",
            "fps": session.fps, "width": session.width, "height": session.height,
            "frames": len(session.analyzer.record.frames), "stages": session.perception.available,
            "corners": session.corners, "budget_ms": session.live["budget_ms"],
            "decision_ack": True,
            **_snapshot(session),
        })  # fmt: skip
    except Exception:  # the client left before the session started
        if first["type"] == "resume":
            manager.detach(entry)
        else:
            await asyncio.to_thread(manager.finish, entry)
        return
    await _serve(ws, manager, entry)


def _snapshot(session: LiveSession) -> dict[str, Any]:
    """What the app shows so far, so a start shows the start score and a resume restores all."""
    with session.lock:
        record = session.analyzer.record
        dump = lambda items: [i.model_dump(mode="json") for i in items]  # noqa: E731
        coaching = (
            session.analyzer.coaching_event(record.rallies[-1].index) if record.rallies else None
        )
        return {
            **session.analyzer.rally_status(),
            "score": record.score.model_dump(mode="json") if record.score else None,
            "rallies": dump(record.rallies),
            "line_calls": dump(record.line_calls),
            "hits": dump(record.hits),
            "coaching": coaching["coaching"] if coaching else None,
            "rally_summary": coaching["rally_summary"] if coaching else None,
        }


async def _serve(ws: WebSocket, manager: LiveManager, entry: _Entry) -> None:
    """Run the session until `stop` (save it) or until the socket ends (keep it for a resume).

    Whatever goes wrong, the session is either saved or detached, so the GPU lock is never
    left held by a session nobody can reach.
    """
    session = entry.session
    queue: asyncio.Queue[tuple[str, Any]] = asyncio.Queue()
    max_waiting = int(session.live["max_queue_frames"])
    waiting = 0
    tail: deque[tuple[bytes, float]] | None = None

    async def receive() -> None:
        nonlocal waiting, tail
        try:
            while True:
                msg = await ws.receive()
                if msg["type"] == "websocket.disconnect":
                    break
                if msg.get("bytes") is not None:
                    if waiting >= max_waiting:
                        session.drop()
                        if not tail:
                            continue  # a control separates these frames from the full batch
                        tail.popleft()
                        waiting -= 1
                    if tail is None:
                        tail = deque()
                        queue.put_nowait(("frames", tail))
                    tail.append((msg["bytes"], time.monotonic()))
                    waiting += 1
                elif msg.get("text") is not None:
                    tail = None
                    import json

                    try:
                        payload = json.loads(msg["text"])
                    except ValueError:  # not JSON: report it and keep the session
                        await queue.put(("bad", msg["text"]))
                        continue
                    if isinstance(payload, dict):
                        await queue.put(("control", payload))
                    else:
                        await queue.put(("bad", payload))
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
            if kind == "bad":
                await _send(ws, [_bad_message(payload)])
                continue
            if kind == "control":
                if payload.get("type") == "stop":
                    stopped = True
                    break
                await _send(ws, await asyncio.to_thread(_control, session, payload))
                continue
            # Only the newest waiting frame gets perception; older ones are recorded.
            if payload is tail:
                tail = None
            waiting -= len(payload)
            events = await asyncio.to_thread(_frames, session, list(payload))
            await _send(ws, events)
    except _ClientGone:
        pass
    except Exception:
        log.exception("live session %s failed", session.id)
        await _error(ws, "internal", "the live session hit an error; resume to continue", 1011)
    finally:
        receiver.cancel()
        if not stopped:
            manager.detach(entry)
    if stopped:
        try:
            job = await asyncio.to_thread(manager.finish, entry)
        except Exception:
            log.exception("saving live session %s failed", session.id)
            await _error(ws, "internal", "the live session could not be saved", 1011)
            return
        with contextlib.suppress(Exception):
            await ws.send_json({
                "type": "saved", "job_id": job.id if job else None,
                "video_id": job.video_id if job else None,
                "stats": session.stats.summary(),
            })  # fmt: skip
            await ws.close()


def _frames(session: LiveSession, frames: list[tuple[bytes, float]]) -> list[dict]:
    with session.lock:
        return _frames_locked(session, frames)


def _frames_locked(session: LiveSession, frames: list[tuple[bytes, float]]) -> list[dict]:
    events: list[dict] = []
    for i, (data, received) in enumerate(frames):
        if len(data) <= HEADER.size:
            events.append({"type": "error", "code": "bad_frame", "detail": "frame too short"})
            continue
        client_frame, ts = HEADER.unpack_from(data)
        if not math.isfinite(ts):
            events.append({"type": "error", "code": "bad_frame", "detail": "invalid capture time"})
            continue
        if session.last_capture_ts is not None and ts < session.last_capture_ts:
            events.append(
                {"type": "error", "code": "bad_frame", "detail": "capture time went backwards"}
            )
            continue
        jpeg = data[HEADER.size :]
        if i < len(frames) - 1:
            events += session.skip(jpeg, client_frame, ts)
        else:
            events += session.process(jpeg, client_frame, ts, received)
    return events


def _control(session: LiveSession, msg: dict[str, Any]) -> list[dict]:
    with session.lock:
        events = _control_locked(session, msg)
    decision_id = msg.get("decision_id")
    if type(decision_id) is int and 0 <= decision_id <= 2**53 - 1:
        for event in events:
            if event["type"] in ("score", "error"):
                event["decision_id"] = decision_id
    return events


def _control_locked(session: LiveSession, msg: dict[str, Any]) -> list[dict]:
    try:
        if (
            msg.get("type") == "override"
            and type(msg.get("line_call_id")) is int
            and msg["line_call_id"] >= 0
            and msg.get("call") in ("in", "out")
        ):
            return session.override(msg["line_call_id"], msg["call"])
        if (
            msg.get("type") == "correct"
            and type(msg.get("rally_index")) is int
            and msg["rally_index"] >= 0
            and "winner" in msg
            and msg["winner"] in ("near", "far", None)
        ):
            return session.correct(msg["rally_index"], msg.get("winner"))
        if msg.get("type") == "award" and msg.get("winner") in ("near", "far"):
            return session.award(msg["winner"])
        if msg.get("type") == "undo":
            return session.undo()
    except RallyInPlay as exc:
        return [{"type": "error", "code": "rally_in_play", "detail": str(exc)}]
    except (KeyError, TypeError, ValueError):
        detail = "nothing to undo" if msg.get("type") == "undo" else "no such line call or rally"
        return [{"type": "error", "code": "not_found", "detail": detail}]
    return [_bad_message(msg)]


def _bad_message(msg: Any) -> dict:
    return {"type": "error", "code": "bad_message", "detail": f"unknown message: {msg}"}


class _ClientGone(Exception):
    """Sending to the socket failed: the client went away."""


async def _send(ws: WebSocket, events: list[dict]) -> None:
    try:
        for event in events:
            await ws.send_json(event)
    except Exception as exc:
        raise _ClientGone from exc
