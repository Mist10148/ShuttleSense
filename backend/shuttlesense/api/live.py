"""WS /live: live sessions (F19, D16). Protocol in docs/API.md.

Client -> server: a JSON `start` (or `resume`), then binary frames (12-byte header: uint32
frame index and float64 capture time in ms, little-endian, then one JPEG), JSON
`override`, `correct`, `award`, `undo` and `stop`. Server -> client: JSON events (`started`,
`frame`, `hit`, `rally`, `line_call`, `score`, `coaching`, `stats`, `degraded`, `saved`,
`error`).
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import hmac
import json
import logging
import math
import struct
import threading
import time
from collections import deque
from copy import deepcopy
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from shuttlesense.api.models import Job, VideoInfoOut, utcnow
from shuttlesense.api.storage import Storage, new_id
from shuttlesense.courtside import control_interval, courtside_snapshot, log_decision, set_goal
from shuttlesense.schema import GameService, PracticeGoal, ScorePair
from shuttlesense.stream.analyzer import MatchOver, RallyInPlay
from shuttlesense.stream.session import LiveSession, StartRequest

log = logging.getLogger(__name__)

HEADER = struct.Struct("<Id")
START_TIMEOUT_S = 10.0

ws_router = APIRouter()


@ws_router.websocket("/watch")
async def watch_video(ws: WebSocket, token: str | None = None) -> None:
    """Analyze an uploaded video one requested frame at a time, on its video clock."""
    import cv2

    from shuttlesense.io import FrameReader

    await ws.accept()
    settings = ws.app.state.settings
    if settings.token and not (
        token and hmac.compare_digest(token.encode(), settings.token.encode())
    ):
        await _error(ws, "unauthorized", "missing or invalid token", 4401)
        return
    manager: LiveManager = ws.app.state.live
    entry = None
    frames = None
    watch_started = time.perf_counter()
    perception_s = 0.0
    processed = 0
    try:
        start = await asyncio.wait_for(ws.receive_json(), START_TIMEOUT_S)
        if not isinstance(start, dict) or start.get("type") != "start":
            raise ValueError("first message must be start")
        video_id = str(start.get("video_id", ""))
        meta = manager.storage.load_video_meta(video_id)
        source = manager.storage.video_source(video_id)
        if meta is None or source is None:
            raise ValueError("video not found")
        live_cfg = manager.state.jobs.config.get("live") or {}
        reader = await asyncio.to_thread(
            FrameReader,
            source,
            int(live_cfg.get("target_height", 720)),
            float(live_cfg.get("max_fps", 30)),
        )
        corners = start.get("corners")
        if corners is not None:
            corners = [
                [float(x) * reader.width / meta.width, float(y) * reader.height / meta.height]
                for x, y in corners
            ]
        request = _start_request(
            {
                **start,
                "corners": corners,
                "fps": reader.fps,
                "width": reader.width,
                "height": reader.height,
            }
        )
        playback = start.get("playback", "complete")
        if playback not in ("complete", "realtime"):
            raise ValueError("playback must be complete or realtime")
        entry = await asyncio.to_thread(manager.create, request)
        session = entry.session
        from shuttlesense.stream.perception import enable_watch_player_continuity

        enable_watch_player_continuity(session.perception)
        if playback == "complete" and not manager.fake:
            from shuttlesense.stream.watch_parallel import (
                ParallelWatchPerception,
                parallel_watch_enabled,
            )

            setting = (manager.state.jobs.config.get("watch") or {}).get(
                "frame_parallel_perception", False
            )
            if parallel_watch_enabled(setting, manager.state.jobs.device):
                session.perception = ParallelWatchPerception(session.perception)
        profiler = None
        if start.get("profile_diagnostics") is True:
            from shuttlesense.stream.watch_profile import WatchFrameProfiler

            profiler = WatchFrameProfiler(session)
            profiler.attach_reader(reader)
        # Video playback waits for each result, so it must not lower perception resolution
        # merely because a frame took longer than the camera-live latency budget.
        if playback == "complete":
            session.live["scales"] = [1.0]
        session.request.name = "Watch & Analyze (partial)"
        session.analyzer.watch_stroke_guard = True
        try:
            from shuttlesense.stage import StageSkipped
            from shuttlesense.strokes import registry
            from shuttlesense.strokes.classify import load_classifier

            strokes_cfg = session.config.get("stages", {}).get("strokes", {})
            name = registry.algorithm(strokes_cfg)
            _, checkpoint = await asyncio.to_thread(
                load_classifier, registry.weights_path(strokes_cfg, name), session.analyzer.device
            )
            session.analyzer.watch_checkpoint = checkpoint
            window = int(checkpoint.get("window_frames", strokes_cfg.get("window_frames", 32)))
            window_fps = checkpoint.get("window_fps")
            step = session.fps / float(window_fps) if window_fps else 1.0
            ahead = math.ceil((window - 1 - window // 2) * step)
            session.analyzer.hit_lag = max(session.analyzer.hit_lag, ahead + 1)
        except (StageSkipped, ImportError, OSError, ValueError, KeyError):
            log.warning("Watch stroke model unavailable; hits will remain unclassified")
        frames = iter(reader)
        next_index = 0
        await ws.send_json(
            {
                "type": "started",
                "fps": reader.fps,
                "width": reader.width,
                "height": reader.height,
                "frames": len(reader),
                "job_id": entry.job_id,
                "stages": session.perception.available,
                "playback": playback,
                "provider_diagnostics": getattr(
                    getattr(session.perception, "perception", session.perception),
                    "provider_diagnostics", None,
                ),
            }
        )
        previous_transport = None
        while True:
            msg = await ws.receive_json()
            if msg.get("type") == "stop":
                break
            if msg.get("type") != "next":
                await _error(ws, "bad_request", "expected next or stop")
                continue
            target = next_index
            if playback == "realtime":
                target = msg.get("index", next_index)
                if type(target) is not int or not next_index <= target < len(reader):
                    await _error(ws, "bad_request", "invalid or backward video frame index")
                    continue
                # Anchor the recording at zero even if playback advanced during startup.
                if next_index == 0:
                    target = 0
                while next_index < target:
                    skipped = await asyncio.to_thread(next, frames, None)
                    if skipped is None:
                        break
                    skipped_index, skipped_frame = skipped
                    ok, encoded = await asyncio.to_thread(cv2.imencode, ".jpg", skipped_frame)
                    if not ok:
                        raise ValueError("could not encode video frame")
                    packet = HEADER.pack(skipped_index, skipped_index * 1000.0 / reader.fps)
                    await asyncio.to_thread(_skip_watch_frame, session, packet + encoded.tobytes())
                    next_index = skipped_index + 1
            if profiler is not None:
                profiler.begin()
            read_started = time.perf_counter()
            item = await asyncio.to_thread(next, frames, None)
            read_ms = (time.perf_counter() - read_started) * 1000
            if item is None:
                session.request.name = "Watch & Analyze"
                break
            index, frame = item
            next_index = index + 1
            encode_started = time.perf_counter()
            ok, jpeg = await asyncio.to_thread(cv2.imencode, ".jpg", frame)
            encode_ms = (time.perf_counter() - encode_started) * 1000
            if not ok:
                raise ValueError("could not encode video frame")
            data = jpeg.tobytes()
            packet = HEADER.pack(index, index * 1000.0 / reader.fps) + data
            processing_start = time.perf_counter()
            events = await asyncio.to_thread(_frames, session, [(packet, time.monotonic())])
            frame_processing_s = time.perf_counter() - processing_start
            perception_s += frame_processing_s
            processed += 1
            response = {
                    "type": "video_frame",
                    "index": index,
                    **(
                        {"jpeg": base64.b64encode(data).decode("ascii")}
                        if playback == "complete"
                        else {}
                    ),
                    "events": events,
                    **({"profile_ms": profiler.finish()} if profiler is not None else {}),
                    "timing_ms": {"read": round(read_ms, 2), "jpeg": round(encode_ms, 2),
                                  "processing": round(frame_processing_s * 1000, 2)},
                    "provider_diagnostics": getattr(
                        getattr(session.perception, "perception", session.perception),
                        "provider_diagnostics", None,
                    ),
                }
            if profiler is None:
                await ws.send_json(response)
            else:
                # A send's duration is only known after it finishes, so return it
                # with the next frame and identify the frame it describes.
                if previous_transport is not None:
                    response["previous_transport"] = previous_transport
                # Comparable with the client's wall clock only on the same host;
                # this marks the start of serialization, before the send.
                response["server_serialize_epoch_us"] = time.time_ns() // 1000
                serialize_start = time.perf_counter()
                encoded_response = json.dumps(response, separators=(",", ":"), ensure_ascii=False)
                serialize_ms = (time.perf_counter() - serialize_start) * 1000
                send_start = time.perf_counter()
                await ws.send_text(encoded_response)
                previous_transport = {"frame": index, "serialize_ms": round(serialize_ms, 3),
                                      "send_await_ms": round((time.perf_counter() - send_start) * 1000, 3),
                                      "utf8_bytes": len(encoded_response.encode("utf-8"))}
    except LiveBusy:
        await _error(ws, "busy", "the GPU is busy with another job or live session", 4409)
    except (ValueError, TypeError, KeyError) as exc:
        await _error(ws, "bad_request", str(exc), 4400)
    except (WebSocketDisconnect, TimeoutError):
        pass
    except Exception:
        log.exception("watch session failed")
        await _error(ws, "internal", "video analysis failed", 1011)
    finally:
        if frames is not None:
            frames.close()
        if entry is not None:
            try:
                log.info("Frame Watch: %d frames, %.2fs elapsed including setup and pauses, "
                         "%.2fs frame processing", processed,
                         time.perf_counter() - watch_started, perception_s)
                job = await asyncio.to_thread(_finish_watch, manager, entry)
                with contextlib.suppress(Exception):
                    await ws.send_json({"type": "saved", "job_id": job.id if job else None})
                    await ws.close()
            except Exception:
                log.exception("saving watch session failed")


def _finish_watch(manager, entry):
    """Close concurrent workers and save in one thread, even if the socket is cancelled."""
    try:
        close = getattr(entry.session.perception, "close", None)
        if close is not None:
            close()
    finally:
        job = manager.finish(entry)
    return job


def _skip_watch_frame(session: LiveSession, packet: bytes) -> None:
    index, timestamp = HEADER.unpack_from(packet)
    with session.lock:
        session.skip(packet[HEADER.size :], index, timestamp)


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
        from shuttlesense.config import with_stroke_model
        from shuttlesense.stream.session import LIVE_DEFAULTS, normalized_size

        config = self.state.jobs.config
        if request.stroke_model:
            config = with_stroke_model(config, request.stroke_model)
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

            record, truth = synthetic_record(doubles=request.court == "doubles")
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
        if not session.analyzer.record.frames and not (
            session.analyzer.record.practice_goals or session.analyzer.record.decision_log
        ):  # nothing arrived and no user decisions to preserve
            session.close()
            self.storage.delete_video(entry.video_id)
            return None
        record = session.finish()
        source = self.storage.video_dir(entry.video_id) / "source.mp4"
        source.parent.mkdir(parents=True, exist_ok=True)
        name = session.request.name or f"Live session {utcnow():%Y-%m-%d %H:%M}"
        self.storage.save_video_meta(VideoInfoOut(
            id=entry.video_id, filename=f"{name}.mp4",
            size_bytes=source.stat().st_size if source.exists() else 0,
            fps=record.fps, width=record.width, height=record.height,
            num_frames=record.num_frames, duration_s=round(record.num_frames / record.fps, 3),
        ))  # fmt: skip
        job_id = entry.job_id
        record.clip_id = job_id
        record.source_name = f"{name}.mp4"
        start = session.request.start_score
        existing_job = self.state.jobs.get(job_id)
        # Watch background registers its job before analysis. Preserve that start
        # when the saved session replaces it with the rendering job.
        watch_started = (
            existing_job.started_at if existing_job and existing_job.started_at else
            datetime.fromtimestamp(session.started_at, UTC)
        ) if name.startswith("Watch & Analyze") else utcnow()
        job = Job(
            id=job_id, video_id=entry.video_id, status="running", current_stage="render",
            started_at=watch_started, progress=0.9, mode="live", referee=True, start_score=start,
            best_of=session.request.best_of, first_server=session.request.first_server,
            start_games=session.request.start_games, court=session.request.court,
            auto_change_ends=session.request.auto_change_ends,
            first_server_id=session.request.first_server_id,
            first_receiver_id=session.request.first_receiver_id,
            stroke_model=session.request.stroke_model or self.state.jobs.default_stroke_model(),
            game_service=list(record.score.game_service) if record.score else [],
            court_corners_px=list(session.corners) if session.corners else None,
            overlays=list(OVERLAYS),
            watch_focused_analysis=existing_job.watch_focused_analysis if existing_job else False,
        )  # fmt: skip
        job_dir = self.storage.job_dir(job_id)
        job_dir.mkdir(parents=True, exist_ok=True)
        save_overrides(job_dir, session.analyzer.overrides)
        save_corrections(job_dir, session.analyzer.corrections)
        write_exports(record, job_dir)
        self.state.jobs.add(job)
        if not record.frames:
            self.state.jobs.finish_outside(
                job.id, error="No camera frames were recorded; decisions and goals are saved."
            )
            return job
        threading.Thread(target=self._render, args=(job, record, source), daemon=True).start()
        return job

    def _render(self, job: Job, record, source) -> None:
        """Annotated video for the saved session, off the socket's thread."""
        from shuttlesense.api.jobs import JobCancelled
        from shuttlesense.io import FrameReader
        from shuttlesense.render import render_video

        jobs = self.state.jobs
        try:
            reader = FrameReader(source, target_height=record.height, max_fps=record.fps)
            last_progress = 0.0

            def on_progress(value: float) -> None:
                nonlocal last_progress
                jobs.check_cancelled(job.id)
                now = time.monotonic()
                if now - last_progress >= 0.5 or value >= 1:
                    # Keep 100% for the completed file, including encoder finalization.
                    jobs._update(job.id, progress=0.9 + 0.099 * min(max(value, 0), 1))
                    last_progress = now

            render_video(record, reader, self.storage.job_dir(job.id) / "annotated.mp4",
                         overlays=job.overlays, config=jobs.config,
                         progress=on_progress)  # fmt: skip
            jobs.check_cancelled(job.id)  # deleted while the last frames were written
            jobs.finish_outside(job.id)
        except JobCancelled:
            self.storage.delete_job(job.id)  # the render had files open, or wrote new ones
        except Exception as exc:  # the record is saved; only the video is missing
            log.exception("rendering live session %s failed", job.id)
            jobs.finish_outside(job.id, error=f"render failed: {exc}")
        finally:
            jobs.forget_cancelled(job.id)
            # DELETE /videos while this rendered: the recording was open, so finish the delete.
            if self.storage.video_deleted(job.video_id):
                self.storage.delete_video(job.video_id)

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
    start_games = ScorePair(**msg["start_games"]) if msg.get("start_games") else None
    from shuttlesense.referee import validate_start_games

    validate_start_games(start_games, best_of)
    # v1.7. A client that does not send it gets the rules, and still shows the right
    # score: near and far in every event are the ends as they are.
    auto_change_ends = msg.get("auto_change_ends", True)
    if type(auto_change_ends) is not bool:
        raise ValueError("auto_change_ends must be true or false")
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

    check_first_service(first_server, server_id, receiver_id, court)
    if server_id and first_server is None:
        first_server = server_id[:-2]
    stroke_model = msg.get("stroke_model")
    if stroke_model is not None:
        from shuttlesense.strokes import registry

        if stroke_model not in registry.ALGORITHMS:
            raise ValueError("stroke_model must be cnn, lstm or rf")
    return StartRequest(
        fps=fps, width=width, height=height, corners=corners, court=court, name=name,
        start_score=score, best_of=best_of, first_server=first_server, start_games=start_games,
        first_server_id=server_id, first_receiver_id=receiver_id, stroke_model=stroke_model,
        auto_change_ends=auto_change_ends,
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
            "decision_ack": True, "decision_dedup": True, "courtside_depth": True,
            "change_ends": True,
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
            **courtside_snapshot(record),
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
        events = _frames_locked(session, frames)
        for event in events:
            if event["type"] == "score":
                event.update(courtside_snapshot(session.analyzer.record))
        return events


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
    decision_id = msg.get("decision_id")
    client_id = msg.get("client_id", "legacy")
    identified = type(decision_id) is int and 0 <= decision_id <= 2**53 - 1
    if not isinstance(client_id, str) or not 1 <= len(client_id) <= 128:
        return [
            {
                "type": "error",
                "code": "bad_request",
                "detail": "invalid client_id",
                "decision_id": decision_id,
            }
        ]
    with session.lock:
        key = (client_id, decision_id)
        fingerprint = hashlib.sha256(
            json.dumps(msg, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        previous = session.command_receipts.get(key) if identified else None
        if previous is not None:
            if previous[0] != fingerprint:
                return [
                    {
                        "type": "error",
                        "code": "decision_conflict",
                        "detail": "decision ID already used for a different command",
                        "decision_id": decision_id,
                    }
                ]
            # A duplicate must not roll the screen back to an old score.
            errors = previous[1]
            events = (
                deepcopy(errors)
                if errors
                else [
                    {"type": "score", **_snapshot(session)},
                ]
            )
        else:
            # Never evict receipts and silently allow an old command to execute twice.
            if identified and len(session.command_receipts) >= 10000:
                return [
                    {
                        "type": "error",
                        "code": "command_limit",
                        "detail": "session command limit reached; stop and save",
                        "decision_id": decision_id,
                    }
                ]
            before_score = session.analyzer.record.score
            game = before_score.game if before_score else 1
            # Refuse a malformed decision before it changes the score: a failure after the
            # change would lose the receipt and let the client's retry apply it twice.
            problem = _decision_problem(msg)
            events = (
                [{"type": "error", "code": "bad_request", "detail": problem}]
                if problem
                else _control_locked(session, msg)
            )
            errors = [e for e in events if e["type"] == "error"]
            if not errors:
                try:
                    log_decision(session.analyzer.record, {**msg, "_game": game})
                except Exception:  # the decision stands; only its history entry is lost
                    log.exception("live session %s could not log a decision", session.id)
                for event in events:
                    if event["type"] == "score":
                        event.update(courtside_snapshot(session.analyzer.record))
            if identified:
                session.command_receipts[key] = (fingerprint, deepcopy(errors))
        if identified:
            for event in events:
                if event["type"] in ("score", "error"):
                    event["decision_id"] = decision_id
        return events


# A decision's optional reason (v1.5); None when the referee gave none.
REASONS = (None, "let", "fault", "service_fault", "misconduct")
DECISIONS = ("award", "correct", "override", "concede", "undo", "ends")


def _decision_problem(msg: dict[str, Any]) -> str | None:
    """What is wrong with a decision's optional history fields, or None.

    _control_locked checks the fields a decision acts on; these only reach the decision log.
    """
    kind = msg.get("type")
    if kind not in DECISIONS:
        return None
    frame = msg.get("frame")
    if frame is not None and (type(frame) is not int or frame < 0):
        return "frame must be a non-negative integer"
    if kind in ("override", "concede", "undo", "ends") and msg.get("reason") not in REASONS:
        return "unknown reason"
    rally_index = msg.get("rally_index")
    if (
        kind != "correct"
        and rally_index is not None
        and (type(rally_index) is not int or rally_index < 0)
    ):
        return "rally_index must be a non-negative integer"
    return None


def _control_locked(session: LiveSession, msg: dict[str, Any]) -> list[dict]:
    if msg.get("type") in ("interval", "goal"):
        try:
            record = session.analyzer.record
            if msg["type"] == "interval":
                control_interval(record, msg.get("action"))
            else:
                set_goal(
                    record,
                    PracticeGoal.model_validate(msg.get("goal")),
                    doubles=session.request.court == "doubles",
                )
            return [{"type": "score", **_snapshot(session)}]
        except (ValueError, TypeError) as exc:
            return [{"type": "error", "code": "bad_request", "detail": str(exc)}]
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
            and msg.get("reason") in REASONS
        ):
            return session.correct(msg["rally_index"], msg.get("winner"), msg.get("reason"))
        if (
            msg.get("type") == "award"
            and msg.get("winner") in ("near", "far")
            and msg.get("reason") in REASONS
        ):
            return session.award(msg["winner"], msg.get("reason"))
        if msg.get("type") == "concede" and msg.get("winner") in ("near", "far"):
            return session.concede(msg["winner"])
        if msg.get("type") == "undo":
            return session.undo()
        if msg.get("type") == "ends":
            return session.change_ends()
        if msg.get("type") == "service":
            try:
                game, service = _game_service(session, msg)
            except ValueError as exc:
                return [{"type": "error", "code": "bad_request", "detail": str(exc)}]
            return session.set_service(game, service)
    except RallyInPlay as exc:
        return [{"type": "error", "code": "rally_in_play", "detail": str(exc)}]
    except MatchOver as exc:
        return [{"type": "error", "code": "match_over", "detail": str(exc)}]
    except (KeyError, TypeError, ValueError):
        detail = "nothing to undo" if msg.get("type") == "undo" else "no such line call or rally"
        return [{"type": "error", "code": "not_found", "detail": detail}]
    return [_bad_message(msg)]


def _game_service(session: LiveSession, msg: dict[str, Any]) -> tuple[int, GameService | None]:
    """A `service` message: {game, server_id, receiver_id}; both ids null forgets the game.
    Raises ValueError (answered with bad_request) for anything else."""
    from shuttlesense.api.models import GameServiceIn

    if session.request.court != "doubles":
        raise ValueError("the service order is for doubles sessions")
    game = msg.get("game")
    if type(game) is not int:
        raise ValueError("game must be 2 or 3")
    body = GameServiceIn.model_validate(
        {"game": game, "server_id": msg.get("server_id"), "receiver_id": msg.get("receiver_id")}
    )
    if body.server_id is None or body.receiver_id is None:
        return body.game, None
    return body.game, GameService(game=body.game, server_id=body.server_id,
                                  receiver_id=body.receiver_id)  # fmt: skip


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
