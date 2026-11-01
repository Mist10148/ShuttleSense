# Backend API

REST contract between the Flutter app and the FastAPI backend. The server implements it in [`backend/shuttlesense/api/routes.py`](../backend/shuttlesense/api/routes.py); the app's client is [`app/lib/data/api_client.dart`](../app/lib/data/api_client.dart). FastAPI also serves live interactive docs at `/docs` (Swagger UI) and the OpenAPI JSON at `/openapi.json` on any running server.

Frozen at the end of Phase 1 (task T1.2), with the same change policy as the [clip record](DATA_FORMAT.md): breaking changes need the lead's approval and must update server, app client and this page in one PR.

## Basics

| Item | Value |
| --- | --- |
| Base URL | `http://<laptop-LAN-IP>:8000` or `https://<name>.trycloudflare.com` |
| Format | JSON (`application/json`), except uploads (`multipart/form-data`) and file downloads |
| Auth | If the server has `SHUTTLESENSE_TOKEN` set, every request except `GET /health` needs `Authorization: Bearer <token>` (the scheme is case-insensitive). Where headers cannot be set (the web build's `<video>` element), `?token=<token>` is accepted instead |
| CORS | Allowed origins from `SHUTTLESENSE_CORS_ORIGINS` (default `*`) so the web build works |
| IDs | URL-safe random strings (`uuid4().hex[:12]`) |
| Times | ISO 8601 UTC |

### Errors

All errors use FastAPI's shape with a stable `detail`:

```json
{"detail": "job not found"}
```

| Status | When |
| --- | --- |
| 400 | Invalid input (bad corners, unsupported overlay name, clip longer than `stages.io.max_duration_s`, bad `start_score`) |
| 401 | Missing or wrong bearer token |
| 404 | Unknown video or job id, or a result file that is not produced yet |
| 409 | Action not allowed in the current job state (e.g. score correction before referee ran) |
| 413 | Upload larger than `SHUTTLESENSE_MAX_UPLOAD_MB` (default 1024) |
| 415 | Unsupported video container (not MP4/MOV/AVI) |
| 422 | Request body failed validation |

## Endpoints

### `GET /health`

Liveness and capability check used by the connect screen.

```json
{
  "status": "ok",
  "version": "0.1.0",
  "schema_version": "1.1",
  "device": "cuda",
  "auth_required": true,
  "stages": ["io", "tracking", "pose", "court", "hits", "strokes", "feedback", "analytics", "referee", "render"],
  "chat_available": true,
  "chat_max_messages": 20
}
```

`stages` lists the stages whose dependencies and weights are installed on this host, so the app can grey out overlays that cannot be produced.

### `POST /videos`

Upload a video. `multipart/form-data` with field `file`.

Response `201`:

```json
{
  "id": "a1b2c3d4e5f6",
  "filename": "rally12.mp4",
  "size_bytes": 48211234,
  "fps": 30.0,
  "width": 1920,
  "height": 1080,
  "num_frames": 1800,
  "duration_s": 60.0,
  "created_at": "2026-11-05T09:12:44Z"
}
```

### `GET /videos/{video_id}`

Same body as the upload response.

### `GET /videos/{video_id}/frames/{n}`

JPEG of frame `n` (0-based), used for court calibration. Optional query `max_width` (default 1280) to downscale for phones. Coordinates the app sends back are always in **source video pixels** (the `width` × `height` reported by `POST /videos`), whatever size the JPEG was scaled to; the response includes headers `X-Frame-Width` and `X-Frame-Height` (source size) so the app can scale taps.

### `DELETE /videos/{video_id}`

Deletes the upload and every job created from it. `204`.

### `POST /jobs`

Start processing.

```json
{
  "video_id": "a1b2c3d4e5f6",
  "court_corners_px": [[212, 650], [1068, 650], [880, 210], [400, 210]],
  "overlays": ["trail", "pose", "boxes", "hits", "strokes", "court", "speed", "score"],
  "referee": true
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `video_id` | yes | From `POST /videos` |
| `court_corners_px` | no | 4 points in the order defined in [DATA_FORMAT.md](DATA_FORMAT.md#court-corners-order); omit to skip P2/P3 court features. `400` if they are not a convex quadrilateral in that order, or if the court they outline covers less than 10% or more than 95% of the frame ("corners look wrong") |
| `overlays` | no | Subset of `trail, pose, boxes, hits, strokes, court, minimap, speed, score`; default all nine (overlays whose stage did not run are simply not drawn) |
| `referee` | no | Run the referee layer (rally state, line calls, score); default `false` |
| `start_score` | no | `{"near": 10, "far": 12}` when the clip starts mid-game; default 0–0. `400` if negative or already a finished game (e.g. 21–15) |

Response `202`: a Job object (below).

### `GET /jobs`

List jobs, newest first. Query `limit` (default 50).

### `GET /jobs/{job_id}`

Job object, polled by the processing screen every 1 to 2 s.

```json
{
  "id": "f00dbabe1234",
  "video_id": "a1b2c3d4e5f6",
  "status": "running",
  "queue_position": null,
  "current_stage": "pose",
  "progress": 0.42,
  "stages": [
    {"name": "io",       "status": "done",    "progress": 1.0},
    {"name": "tracking", "status": "done",    "progress": 1.0},
    {"name": "pose",     "status": "running", "progress": 0.35},
    {"name": "hits",     "status": "pending", "progress": 0.0}
  ],
  "error": null,
  "created_at": "2026-11-05T09:13:01Z",
  "started_at": "2026-11-05T09:13:02Z",
  "finished_at": null,
  "outputs": {"record": false, "video": false, "summary": false, "hits_csv": false, "rallies_csv": false},
  "court_corners_px": [[212, 650], [1068, 650], [880, 210], [400, 210]],
  "overlays": ["trail", "pose", "boxes", "hits", "strokes"],
  "referee": false,
  "start_score": null
}
```

`court_corners_px`, `overlays`, `referee` and `start_score` echo the options the job was created with, so the app can retry or re-render with the same settings.

`status` is one of `queued`, `running`, `done`, `failed`, `cancelled`. `queue_position` is the 0-based place in the queue while `queued` (a re-rendered job goes to the back) and `null` otherwise. `DELETE /jobs/{id}` removes a job at once, so polling a cancelled job returns 404 rather than `cancelled`. Stage `status` is one of `pending`, `running`, `done`, `skipped`, `failed`.

### `GET /jobs/{job_id}/record`

The full clip record ([DATA_FORMAT.md](DATA_FORMAT.md)). `404` until the pipeline has written it (when the job is `done`).

### `GET /jobs/{job_id}/video`

Annotated MP4 (`video/mp4`). Supports HTTP range requests so players can seek.

### `GET /jobs/{job_id}/summary.json` · `GET /jobs/{job_id}/hits.csv` · `GET /jobs/{job_id}/rallies.csv`

Export files (F13). Served with `Content-Disposition: attachment`. CSV files are UTF-8 with a byte-order mark so Excel opens them correctly. `summary.json` adds `rally_stats` (per rally: `stroke_count`, `start_s`, `end_s`, `duration_s`, `peak_speed_kmh`). `rallies.csv` has one row per rally: `index,start_frame,end_frame,start_s,end_s,stroke_count,peak_speed_kmh,winner,landing_in,landing_confidence,score_near,score_far` (empty when the referee stage did not run).

### `POST /jobs/{job_id}/render`

Re-render the annotated video with a different overlay set, reusing cached stage outputs. Body `{"overlays": [...]}`. Returns `202` and the Job object with the new `overlays`; the job goes back to `queued`/`running`, the cached stages report `done` immediately and only `io` and `render` actually run. `409` while the job is queued or running, or when it never produced outputs (a `failed` job whose earlier run finished can be re-rendered again); `400` for unknown overlays.

### `PATCH /jobs/{job_id}/score`

Correct the winner of a rally (F16). Body:

```json
{"rally_index": 3, "winner": "far"}
```

Returns `{"score": {...}, "rallies": [...]}`: the updated score (with `corrections`) and every rally with its recomputed `score_after`. The correction is appended to `score.corrections` in the record, later rallies are re-scored from the job's `start_score`, and `summary.json`, `hits.csv` and `rallies.csv` are regenerated. Corrections to one job are serialized. `404` for an unknown rally; `409` unless the job is `done` (a re-render would rewrite `record.json`) or if the referee stage did not run.

### `PATCH /jobs/{job_id}/line-calls/{call_id}`

Confirm or override an automated line call (F20). Body `{"call": "in"}` or `{"call": "out"}`; sending the backend's own call confirms it. The decision is stored per rally in `line_call_overrides.json` in the job folder (re-applied after every re-render, like score corrections) and the call gets `override: {"call", "at"}`. A confirmed or overridden call counts as certain, so its rally winner is decided again from the landing side or the last hitter; explicit score corrections still take precedence. Returns `{"line_calls": [...], "score": {...}, "rallies": [...]}` and regenerates the exports. `404` for an unknown call or a job without the referee layer; `409` unless the job is `done`.

### `GET /jobs/{job_id}/record` and older records

A record written by an older 1.x backend is upgraded on the fly (`schema.migrate`): missing fields get their defaults and `line_calls` / `rally_events` are derived from the rallies. The file on disk is not rewritten.

### `WS /live`

Live sessions (F19, [D16](DECISIONS.md)). Authentication: `?token=` (browsers cannot set headers on a WebSocket). Design and latency budget: [Architecture → Live sessions](ARCHITECTURE.md#live-sessions).

**Client → server**

| Message | Format | Notes |
| --- | --- | --- |
| `start` | `{"type": "start", "fps": 30, "width": 1280, "height": 720, "corners": [[x,y]×4] \| null, "start_score": {"near": 0, "far": 0} \| null, "court": "singles" \| "doubles", "name": "Court 2"}` | First message. Corners are in the pixels of the frames the app will send |
| `resume` | `{"type": "resume", "session_id": "..."}` | First message after a dropped connection, within the TTL |
| frame | binary: `uint32` frame index + `float64` capture time in ms (little-endian, 12 bytes), then one JPEG | Frames larger than 720p are scaled down |
| `override` | `{"type": "override", "line_call_id": 0, "call": "out"}` | Confirm (same call) or override |
| `correct` | `{"type": "correct", "rally_index": 0, "winner": "far"}` | Score correction |
| `stop` | `{"type": "stop"}` | Ends and saves the session |

**Server → client** (JSON)

| Event | Payload |
| --- | --- |
| `started` | `session_id`, `resumed`, `fps`, `width`, `height` (processing size), `frames` (count so far), `stages` (`{"tracking": bool, "pose": bool}`: which models are installed), `corners` (processing pixels), `budget_ms` |
| `frame` | `frame`, `time_s`, `client_frame`, `ts` (echo of the capture time), `shuttle`, `players` (boxes and keypoints), `court` (positions in m), `speed_kmh`, `rally_state`, `rally_start_frame`, `strokes_in_rally`, `latency_ms` (arrival → event), `skipped` (true when the frame got no perception) |
| `hit` | `hit`: a clip-record hit (stroke, confidence, feedback, speed); sent about `hit_lag` frames after the contact |
| `rally` | `state: "in_play"` with `start_frame`, `index`; or `state: "between_rallies"` with the finished `rally` |
| `line_call` | `line_call`: a clip-record line call (again after an override) |
| `score` | `score` and every `rallies[]` entry |
| `stats` | `received`, `processed`, `skipped`, `p50_ms`, `p95_ms`, `level`, `drop_rate` every `check_every` processed frames |
| `degraded` | `level` (0 full, 1, 2), `scale`, `reason` |
| `saved` | `job_id` and `video_id` of the saved session (null when no frame arrived), final `stats` |
| `error` | `code` (`unauthorized`, `busy`, `not_found`, `bad_request`, `bad_frame`, `bad_message`, `internal`) and `detail`; the first four close the socket (4401, 4409, 4404, 4400). `internal` means a server-side failure: at start or save it closes the socket (1011); mid-session the server closes the socket and keeps the session for a resume |

Only one live session runs at a time and none while a job is running (`busy`). The saved job has `"mode": "live"` and appears in `GET /jobs`.

### `POST /jobs/{job_id}/chat`

Ask the coach about a finished job (F22, [D18](DECISIONS.md)). Body `{"message": "Why did my smashes land short?"}` (1 to 1000 characters). The answer streams as Server-Sent Events (`text/event-stream`), one JSON object per `data:` line:

- `{"type": "delta", "text": "..."}`: the next piece of the answer, as written;
- `{"type": "done", "message": {...}, "disclaimer": "..."}`: the final chat message (`role`, `text`, `at`, `citations`). Citations are `[t=12.3s]` markers that matched a moment in the session data (hits, line calls, rally starts and ends, note moments); markers that matched nothing are removed from `text`, so the app should show this text in place of the streamed one;
- `{"type": "error", "status": 429, "detail": "..."}`: the Claude API failed (rate limit, rejected key, offline); nothing is saved.

The question and the answer are appended to `record.chat.messages`. What is sent to the Claude API is listed in [PRIVACY.md](PRIVACY.md). `503` when the backend has no API key (`/health` reports `chat_available: false`), `409` unless the job is `done`, `429` after `chat_max_messages` questions (in `/health`), `422` for an empty or too long message.

### `DELETE /jobs/{job_id}`

Cancels a queued/running job or deletes a finished job's outputs. `204`.

## Polling and timeouts (client guidance)

- Poll `GET /jobs/{id}` every 1 s while `running`, every 3 s while `queued`; stop on `done`, `failed` or `cancelled`.
- Upload timeout: none (progress-driven); other requests: 15 s connect, 30 s receive.
- On a network error during polling, retry with back-off up to 30 s, then show "Lost connection to server" with a retry button. The job keeps running on the server.
