# Backend API

### Watch & Analyze WebSocket

`GET /health` advertises `watch_video` when `WS /watch` is available. Upload a
video with `POST /videos`, then connect to `/watch` with the optional `token`
query parameter used by `/live`. Send `{"type":"start","video_id":"..."}`;
optional `corners` are four source-video pixel coordinates. The `started` event
reports normalized dimensions, FPS, frame count and job ID. Send one
`{"type":"next"}` at a time; each `video_frame` includes its index, a base64
JPEG, and analysis events. The request after the last frame finishes the session.
`{"type":"stop"}` finishes early. Both return `saved` with a job ID if frames
were processed. A disconnect also saves the analyzed portion. Pause by withholding
the next request; timestamps follow video time rather than wall-clock time.
The optional `provider_diagnostics` in `started` and `video_frame` identifies the
configured detector and pose providers, including fallback; `timing_ms` on a frame
reports server-side read, JPEG preparation and frame-processing durations. Older
clients can ignore these fields. Frame-by-frame analysis processes every normalized
frame: videos above the configured maximum frame rate may be sampled first.

Diagnostic clients may add `"profile_diagnostics": true` to the start message. Each
frame response then contains `profile_ms`, correlated by `index`, with session-local
wall-clock timings and candidate counts when available. Stage times can overlap and are
not direct GPU execution measurements. The field is absent when profiling is disabled.

Servers advertising `watch_realtime` also accept `"playback":"realtime"` in
the start message. In this mode clients play `GET /videos/{id}/source` separately
and send the current normalized frame `index` with each `next`. The backend
records intermediate frames without running perception and analyzes the requested
frame. Frame responses omit the JPEG in this mode. Indices must advance, and
analysis can miss events; recorded results end at the last processed frame. The
source endpoint supports range requests and the same token authentication as
other video endpoints. Older clients that omit `playback` retain the original
frame-by-frame behavior.

`POST /videos/{video_id}/match-type` accepts `{"corners": [[x,y], ...]}` in
source-video pixels. It samples up to 12 frames and returns `suggestion` (singles,
doubles or null), `detail` and `sampled_frames`. Treat the result as a heuristic
that requires user confirmation. A busy server returns 409; demo mode or an
unavailable pose model returns 503. `watch_match_type` in `/health` advertises
support. Pass the confirmed `court` (singles or doubles) in the `/watch` start.
The watch-only `watch.stroke_min_confidence` setting is an unvalidated heuristic;
hits lacking a complete window, sufficient pose/shuttle observations, or sufficient
confidence remain unclassified and do not receive stroke-specific feedback.

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
  "schema_version": "1.7",
  "device": "cuda",
  "auth_required": true,
  "stages": ["io", "tracking", "pose", "court", "hits", "strokes", "feedback", "analytics", "referee", "render"],
  "stroke_models": ["cnn", "lstm", "rf"],
  "chat_available": true,
  "chat_max_messages": 20
}
```

`stroke_models` lists the stroke classifiers whose weights and packages are installed on this
server, in menu order: `cnn` (1D CNN), `lstm` and `rf` (Random Forest). It is checked on every
call. The app disables a model that is not listed.

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

### `POST /videos/{video_id}/court-corners?frame=0`

Analyzes the selected source frame and returns `{ "frame": 0, "corners": [[x, y], ...] }`.
Coordinates are source pixels in near-left, near-right, far-right, far-left order, and
always identify the singles reference court, including for doubles matches. `corners` is
`null` when the detector cannot find a sufficiently supported suggestion. Suggestions
must be reviewed and can be adjusted by the user. A missing video or frame returns 404.

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
| `start_score` | no | `{"near": 10, "far": 12}` when the clip starts mid-game; default 0–0. `400` if negative, already a finished game (e.g. 21–15) or above 29 |
| `best_of` | no | `1` (default) or `3`: games in the match ([D21](DECISIONS.md)). `start_score` is the score of the first game played |
| `start_games` | no | `{"near": 1, "far": 0}`: games each side had already won when the clip starts (v1.5, [D33](DECISIONS.md)), so a clip of game 2 or 3 numbers its games and ends the match correctly. `400` if negative or already a won match (2 in a best of 3, any in a best of 1) |
| `auto_change_ends` | no | `true` (default) or `false` (v1.7, [D36](DECISIONS.md)): the score follows the players when they change ends by the rules. Send `false` for players who stay at their ends; a change marked by hand works either way |
| `first_server` | no | `"near"` or `"far"`: who serves the first rally, for the server and service court; default unknown until a rally is won |
| `court` | no | `"singles"` (default) or `"doubles"` (Phase 9, [D22](DECISIONS.md)): doubles tracks four players, credits each hit to a partner and calls the doubles lines. Sent even without `referee` |
| `first_server_id`, `first_receiver_id` | no | Doubles: the slots (`near_1`, `near_2`, `far_1`, `far_2`) who serve and receive the first rally, both or neither, on opposite sides; `first_server` defaults to the server's side. With them the record says who serves and receives every rally of the first game (later games: `POST /jobs/{job_id}/score/service`). `422` if only one is given, both are on one side, the server is not on `first_server`'s side, or `court` is not `"doubles"` |
| `stroke_model` | no | Which stroke classifier labels the hits: `"cnn"`, `"lstm"` or `"rf"` ([D28](DECISIONS.md)). Default: the server's `stages.strokes.algorithm` (`cnn` as shipped). `422` for any other value. A model that is not installed (`/health` `stroke_models`) leaves the hits unlabelled and the `strokes` stage `skipped`. Running the same video again with another model reuses the cached tracking, pose and hits |

Response `202`: a Job object (below). `404` for an unknown video, including one deleted while the job was being created.

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

`court_corners_px`, `overlays`, `referee`, `start_score`, `best_of`, `start_games`, `first_server`, `court`, `first_server_id`, `first_receiver_id`, `stroke_model` and `game_service` (doubles slots named for later games) echo the options the job was created with, so the app can retry or re-render with the same settings.

`status` is one of `queued`, `running`, `done`, `failed`, `cancelled`. `queue_position` is the 0-based place in the queue while `queued` (a re-rendered job goes to the back) and `null` otherwise. `DELETE /jobs/{id}` removes a job at once, so polling a cancelled job returns 404 rather than `cancelled`. Stage `status` is one of `pending`, `running`, `done`, `skipped`, `failed`.

### `GET /jobs/{job_id}/record`

The full clip record ([DATA_FORMAT.md](DATA_FORMAT.md)). `404` until the pipeline has written it (when the job is `done`).

### `GET /jobs/{job_id}/video`

Annotated MP4 (`video/mp4`). Supports HTTP range requests so players can seek.

### `GET /jobs/{job_id}/summary.json` · `GET /jobs/{job_id}/hits.csv` · `GET /jobs/{job_id}/rallies.csv`

Export files (F13). Served with `Content-Disposition: attachment`. CSV files are UTF-8 with a byte-order mark so Excel opens them correctly. `summary.json` adds `rally_stats` (per rally: `stroke_count`, `start_s`, `end_s`, `duration_s`, `peak_speed_kmh`) and `match` (games, points won on serve, the longest rally and the referee's decisions; see [DATA_FORMAT.md](DATA_FORMAT.md)). `rallies.csv` has one row per rally: `index,start_frame,end_frame,start_s,end_s,stroke_count,peak_speed_kmh,winner,landing_in,landing_confidence,score_near,score_far,game,server_id,receiver_id,call,margin_cm,decision` (empty when the referee stage did not run).

### `POST /jobs/{job_id}/render`

Re-render the annotated video with a different overlay set, reusing cached stage outputs. Body `{"overlays": [...]}`. Returns `202` and the Job object with the new `overlays`; the job goes back to `queued`/`running`, the cached stages report `done` immediately and only `io` and `render` actually run. `409` while the job is queued or running, while a coach answer for it is still being written (the run would rewrite `record.json` under it), or when it never produced outputs (a `failed` job whose earlier run finished can be re-rendered again); `400` for unknown overlays.

### `PATCH /jobs/{job_id}/score`

Correct the winner of a rally (F16). Body:

```json
{"rally_index": 3, "winner": "far"}
```

`"winner": null` makes the rally undecided again, so it does not count.

Returns `{"score": {...}, "rallies": [...]}`: the updated score (with `corrections`) and every rally with its recomputed `score_after`. The correction is appended to `score.corrections` in the record, later rallies are re-scored from the job's `start_score`, and `summary.json`, `hits.csv` and `rallies.csv` are regenerated. Corrections to one job are serialized. `404` for an unknown rally; `409` unless the job is `done` (a re-render would rewrite `record.json`), or if the referee stage did not run or found no rallies, or the match is already won and the correction would change nothing.

### `POST /jobs/{job_id}/score/award`

A point for a rally the referee layer missed. Body `{"winner": "near", "frame": 1234}`; `frame` (optional, default the last frame) places the point after the rallies that ended by then. Stored in `score.corrections` with `"kind": "award"` (and in `corrections.json`, so re-renders keep it). Same response and exports as `PATCH /jobs/{job_id}/score`. `409` unless the job is `done`, if the referee stage did not run, or if the match is already won and the point would come after the deciding rally; unlike a correction, an award needs no detected rally.

### `POST /jobs/{job_id}/score/concede`

The other side retired or gave a walkover (v1.5, [D33](DECISIONS.md)). Body `{"winner": "near", "frame": 1234}`; `frame` (optional, default the last frame) places it like an award. Stored in `score.corrections` with `"kind": "concede"`; `winner` wins the match there and later rallies do not count. Same response and exports as `PATCH /jobs/{job_id}/score`; Undo takes it back. `409` unless the job is `done`, if the referee stage did not run, or if the match is already won.

`PATCH /jobs/{job_id}/score` and `POST /jobs/{job_id}/score/award` also take an optional `reason` (`let`, `fault`, `service_fault`, `misconduct`; `422` otherwise), kept on the correction.

### `POST /jobs/{job_id}/score/service`

Doubles ([D23](DECISIONS.md)): who serves and receives first in game 2 or 3. Body `{"game": 2, "server_id": "far_2", "receiver_id": "near_1"}`; send only `{"game": 2}` to forget that game's slots. The server must be on the side that won the previous game (otherwise the entry is kept but has no effect). Stored in `score.game_service` and on the job, so re-renders keep it. Same response and exports as `PATCH /jobs/{job_id}/score`. `422` if only one id is given or both are on one side; `409` for a singles job, unless the job is `done`, or if the referee stage did not run.

### `POST /jobs/{job_id}/score/ends`

The players changed ends (v1.7, [D36](DECISIONS.md)): early, late, or not when the rules said so. Body `{"frame": 1234}` (optional; default: the end of the video). From there on the points, games, server and doubles slots are at the other end; given where an automatic change happened, it cancels it. It is a decision like an award: logged, taken back by Undo, `409` when the job has no referee layer or the match is already won, `400` for a frame past the end. Same response as an award.

### `POST /jobs/{job_id}/score/undo`

Takes back the referee's newest decision ([D32](DECISIONS.md)): a correction, an award or a line-call override, whichever came last. A rally's winner goes back to what it was before that correction; an undone override puts the earlier override, or the automated call, back. Same response as above plus `line_calls`; `404` when there is nothing to undo.

### `PATCH /jobs/{job_id}/line-calls/{call_id}`

Confirm or override an automated line call (F20). Body `{"call": "in"}` or `{"call": "out"}`; sending the backend's own call confirms it. The decision is appended to `line_call_overrides.json` in the job folder (the newest per rally applies, so Undo can restore an earlier one) (re-applied after every re-render, like score corrections) and the call gets `override: {"call", "at"}`. A confirmed or overridden call counts as certain, so its rally winner is decided again from the landing side or the last hitter; a winner correction for that rally given before the override no longer applies, so the newest decision wins (D32). Returns `{"line_calls": [...], "score": {...}, "rallies": [...]}` and regenerates the exports. `404` for an unknown call; `409` unless the job is `done`, for a job without the referee layer, and for a call on a rally that fell after the deciding point of a match already won (it cannot change the result, D32; nothing is saved). A call on a rally that counted can still be confirmed or overridden after the match.

### `GET /jobs/{job_id}/record` and older records

A record written by an older 1.x backend is upgraded on the fly (`schema.migrate`): missing fields get their defaults and `line_calls` / `rally_events` are derived from the rallies. The file on disk is not rewritten.

### `WS /live`

Live sessions (F19, [D16](DECISIONS.md)). Authentication: `?token=` (browsers cannot set headers on a WebSocket). Design and latency budget: [Architecture → Live sessions](ARCHITECTURE.md#live-sessions).

**Client → server**

| Message | Format | Notes |
| --- | --- | --- |
| `start` | `{"type": "start", "fps": 30, "width": 1280, "height": 720, "corners": [[x,y]×4] \| null, "start_score": {"near": 0, "far": 0} \| null, "start_games": {"near": 1, "far": 0} \| null, "court": "singles" \| "doubles", "name": "Court 2", "best_of": 1 \| 3, "first_server": "near" \| "far" \| null, "first_server_id": "near_1" \| ... \| null, "first_receiver_id": ..., "stroke_model": "cnn" \| "lstm" \| "rf" \| null}` | First message. Corners are in the pixels of the frames the app will send; `best_of`, `first_server`, `court`, `first_server_id` and `first_receiver_id` as in `POST /jobs` (`bad_request` for service slots without `"court": "doubles"`); `stroke_model` as in `POST /jobs` (`bad_request` for an unknown model). In doubles, frame events carry `near_2` and `far_2` players and hits a `hitter` |
| `resume` | `{"type": "resume", "session_id": "..."}` | First message after a dropped connection, within the TTL |
| frame | binary: `uint32` frame index + `float64` capture time in ms (little-endian, 12 bytes), then one JPEG | Capture times must be finite and nondecreasing across reconnects; the clock origin is arbitrary. Frames larger than 720p are scaled down |
| `override` | `{"type": "override", "line_call_id": 0, "call": "out"}` | Confirm (same call) or override; the ID must be a nonnegative JSON integer. Refused with `match_over` for a call on a rally after the deciding point of a match already won |
| `correct` | `{"type": "correct", "rally_index": 0, "winner": "far", "reason": "let"}` | Score correction; the index must be a nonnegative JSON integer; `"winner": null` makes the rally undecided (with `"reason": "let"` it is a let, replayed). `reason` is optional, as for `award`; an unknown reason gets `bad_message` |
| `concede` | `{"type": "concede", "winner": "near"}` | The other side retired: `winner` wins the match after the rallies so far (v1.5). Refused with `match_over` once the match is won; Undo takes it back |
| `award` | `{"type": "award", "winner": "near", "reason": "fault"}` (`reason` optional: `let`, `fault`, `service_fault`, `misconduct`) | A point for a rally the system missed, counted after the rallies so far. Refused with `rally_in_play` while a rally is open or settling, and with `match_over` once the match is won |
| `ends` | `{"type": "ends"}` | The players changed ends now (v1.7): the score goes with them from the rallies so far. Refused with `rally_in_play` while a rally is open and `match_over` once the match is won; Undo takes it back |
| `undo` | `{"type": "undo"}` | Takes back the newest decision: correction, award or line-call override (`not_found` when there is none). An undone override is sent again as a `line_call` event before `score` |
| `service` | `{"type": "service", "game": 2, "server_id": "far_2", "receiver_id": "near_1"}` | Doubles: who serves and receives first in game 2 or 3, as `POST /jobs/{job_id}/score/service`; answered with `score`. `bad_request` (session kept) in singles or for invalid slots |
| `stop` | `{"type": "stop"}` | Ends and saves the session |

**Server → client** (JSON)

| Event | Payload |
| --- | --- |
| `started` | `session_id`, optional `job_id` (reserved replay ID, stable across resume), `resumed`, `fps`, `width`, `height` (processing size), `frames` (count so far), `stages` (`{"tracking": bool, "pose": bool}`: which models are installed), `corners` (processing pixels), `budget_ms`, and the session so far: `score`, `rallies`, `line_calls`, `hits`, `coaching` and `rally_summary` (null before the first rally). After a resume this restores the session summary |
| `frame` | `frame`, `time_s`, `client_frame`, `ts` (echo of the capture time), `shuttle`, `players` (measured boxes and keypoints), `display_players` (boxes with a `held` flag for display only), `court` (positions in m), `speed_kmh`, `rally_state`, `rally_start_frame`, `strokes_in_rally`, `latency_ms` (arrival → event), `skipped` (true when the frame got no perception) |
| `hit` | `hit`: a clip-record hit (stroke, confidence, feedback, speed); sent about `hit_lag` frames after the contact |
| `rally` | `state: "in_play"` with `start_frame`, `index`; or `state: "between_rallies"` with the finished `rally` |
| `line_call` | `line_call`: a clip-record line call (again after an override) |
| `score` | `score` (with the match state: `game`, `games`, `games_won`, `server`, `service_court`, `game_point`, `match_point`, `match_winner`, `interval`, `change_ends`) and every `rallies[]` entry |
| `coaching` | After each closed rally and referee decision: `coaching` (session notes and `top_fixes` so far, as in the record) and the latest `rally_summary`: `index`, `game`, `duration_s`, `strokes`, `peak_speed_kmh`, `winner`, `call`, `margin_cm`, `faults` (`hit_id`, `time_s`, `player`, `hitter`, `stroke`, `rule`, `tip` for each failed form rule; `player` is the side and `hitter` the doubles partner, `null` in singles or when the partners were too close to tell) |
| `stats` | `received`, `processed`, `skipped`, `dropped`, `p50_ms`, `p95_ms`, `level`, `drop_rate` (skipped or discarded share) every `check_every` processed frames. At `live.max_queue_frames`, the oldest waiting capture in the current batch is discarded to admit the newest. A capture cannot replace one queued before a control message. Already-filled capture slots are also counted as dropped |
| `error` with code `capture_gap` | A capture gap exceeded the resume window and was shortened in playback. The session continues |
| `degraded` | `level` (0 full, 1, 2), `scale`, `reason` |
| `saved` | `job_id` and `video_id` of the saved session (null when no frame arrived), final `stats` |
| `error` | `code` (`unauthorized`, `busy`, `not_found`, `bad_request`, `bad_frame`, `bad_message`, `rally_in_play`, `match_over`, `internal`) and `detail`; the first four close the socket (4401, 4409, 4404, 4400) when they answer `start` or `resume`; mid-session, `not_found` (an `override` or `correct` for an unknown line call or rally, or an `undo` with nothing to undo) keeps the session going. `bad_message` (a text frame that is not a JSON object, or an unknown control message) keeps the session going. `rally_in_play` (an `award` while a rally is open or settling) and `match_over` (an `award` or `correct` after the match is won that would change nothing, or an `override` of a call on a rally after the deciding point) keep the session going. A frame whose JPEG header declares more than four times the session's pixel count gets `bad_frame` without being decoded. `internal` means a server-side failure: at start or save it closes the socket (1011); mid-session the server closes the socket (1011) and keeps the session for a resume |

Only one live session runs at a time and none while a job is running (`busy`). The saved job has `"mode": "live"` and appears in `GET /jobs`. The reserved ID does not
create a job on its own. If the client loses the `saved` reply, it can check
`GET /jobs/{job_id}` for that ID; a 404 can mean saving is still in progress or no frames
were saved. With older servers that omit the ID, check History.

The `started` snapshot can also carry `rally_state`, `rally_start_frame`, and `strokes_in_rally`. These restore the active rally before the next camera frame.

When `started.decision_ack` is true, a referee command can include a nonnegative integer `decision_id` (up to 2⁵³ − 1). The server echoes it on the command reply (`score` or `error`). Automatic score events have no decision ID.

Live video and events use fixed-rate slots anchored at the first decoded capture. Missing slots repeat the previous image in playback and carry no new observations. The anchor survives resume. Gaps longer than the resume window are capped and the next capture starts a new anchor.

### `POST /jobs/{job_id}/chat`

Ask the coach about a finished job (F22, [D18](DECISIONS.md)). Body `{"message": "Why did my smashes land short?"}` (1 to 1000 characters). The answer streams as Server-Sent Events (`text/event-stream`), one JSON object per `data:` line:

- `{"type": "delta", "text": "..."}`: the next piece of the answer, as written;
- `{"type": "done", "message": {...}, "disclaimer": "..."}`: the final chat message (`role`, `text`, `at`, `citations`). Citations are `[t=12.3s]` markers that matched a moment in the session data (hits, line calls, rally starts and ends, note moments); markers that matched nothing are removed from `text`, so the app should show this text in place of the streamed one;
- `{"type": "error", "status": 429, "detail": "..."}`: the Claude API failed (rate limit, rejected key, offline); nothing is saved.

The question and the answer are appended to `record.chat.messages` and kept across re-renders. What is sent to the Claude API is listed in [PRIVACY.md](PRIVACY.md). `503` when the backend has no API key (`/health` reports `chat_available: false`), `409` unless the job is `done` or while another question on the same job is still being answered, `429` after `chat_max_messages` questions (in `/health`), `422` for an empty, blank or too long message.

### `DELETE /jobs/{job_id}`

Cancels a queued/running job or deletes a finished job's outputs. `204`.

## Polling and timeouts (client guidance)

- Poll `GET /jobs/{id}` every 1 s while `running`, every 3 s while `queued`; stop on `done`, `failed` or `cancelled`.
- Upload timeout: none (progress-driven); other requests: 15 s connect, 30 s receive.
- On a network error during polling, retry with back-off up to 30 s, then show "Lost connection to server" with a retry button. The job keeps running on the server.


## Change of ends (record 1.7)

`start` takes `"auto_change_ends": true | false` (default `true`; anything else is `bad_request`), and `started.change_ends` says the server follows the players. In every `score` event `near` and `far` are the ends as they are now, with `score.ends_swapped` when the side that started near is at the far end, so a client that knows nothing of this still shows the right numbers at the right end. After a game with the setting on, a doubles pair serves first from the end it crossed to: name later-game service (`service`) with the slots at those ends.

## Courtside depth (record 1.6)

`started.courtside_depth` enables goals, decision history and the interval timer.
`started.decision_dedup` enables exactly-once application of identified control commands
within the retained live session (including reconnects, not server restarts).
Send a stable `client_id` (1–128 characters) and increasing `decision_id` with each
command. Retry a lost acknowledgment with the **same complete command**. Reusing that
ID with a different payload returns `decision_conflict`; another client has its own
namespace. Receipts are retained until the session ends, capped at 10,000; further
identified commands return `command_limit`, so stop and save. Unidentified legacy
commands retain the old behavior. A duplicate success returns the current snapshot,
not an old score. Errors retain their original outcome.

`started` and referee `score` replies include `decision_log`, `interval_state` and
`practice_goals`. Goal/timer replies are also acknowledged `score` events. The client
applies the resumed snapshot and resolves its pending command before enabling controls.

| Command | Payload | Behavior |
| --- | --- | --- |
| `interval` | `action`: `start`, `pause`, `resume`, `reset`, `end` | Only while the score offers an interval; invalid transitions return `bad_request` |
| `goal` | `goal`: PracticeGoal | Replace the goal for this player filter; invalid player/rally/moment returns `bad_request` |

Timers start explicitly. Reset returns to ready, End dismisses the active clock, and
expiration never changes the score. Snapshot remaining time is server-owned; the app
counts down locally between acknowledgments. Undoing an interval's scoring transition
cancels it. A running timer is paused when its session is saved.

### `PUT /jobs/{job_id}/practice-goal`

Authenticated, serialized under the job edit lock. Body is a PracticeGoal:
`text` (trimmed, 1–240 characters), `player` (null/Both, near, far, or doubles partner),
`source` (`personal` default or `cue`), optional `rally_index` and `moment`, and
`completed` (false default). Completion is self-reported. A moment must reference a
recorded frame; its time is normalized from the frame and fps. Partner filters require
a doubles job. Returns the complete updated ClipRecord, 422 for invalid goals, 409
while a job is active, and 404 for a missing job. A failed render with a saved record
can still update its goals. Existing goals, decision history
and chat survive re-rendering. `summary.json` includes `coaching_recap` and `decision_log`.

A session with user decisions/goals but no decodable camera frames keeps a record-only
History entry with an explicit missing-video error; it does not fabricate footage.
