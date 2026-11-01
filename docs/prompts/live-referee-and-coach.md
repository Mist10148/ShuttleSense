# Prompt: live referee mode, line calls, coaching notes and coach chat

Paste everything below the line into a fresh Claude Code session opened in the ShuttleSense repo.

---

## Goal

Extend ShuttleSense so the user picks one of two input modes, and add a referee layer with line calls and a coaching layer with notes and chat.

1. **Input mode: Upload or Live.** Upload keeps the current flow (offline processing of a clip). Live processes a camera feed in real time and shows results while the rally is being played.
2. **Referee mode** (reference: the demo video `AQMGaYhw...mp4`, phone pointed at a court). A live overlay shows player boxes, shuttle trail, `IN PLAY / between rallies` status with timer and shot count, running score, shuttle speed, hit callouts, and a top-down minimap. It also gives **in/out line calls** for each landing.
3. **Coaching notes** per stroke and per session, shown in the app.
4. **Coach chat**: the user asks questions about their session ("why did my smashes land short?", "what should I fix first?") and gets answers grounded in their own data.

## Read first (do not skip)

- `docs/PRD.md`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/API.md`, `docs/DATA_FORMAT.md`, `docs/FEEDBACK_RULES.md`, `docs/PHASES.md`, `docs/TECH_STACK.md`
- Backend: `backend/shuttlesense/pipeline.py`, `schema.py`, `referee/` (`rally.py`, `scoring.py`), `feedback/rules.py`, `court/`, `tracking/`, `pose/`, `hits/`, `strokes/`, `analytics/`, `api/` (`routes.py`, `jobs.py`)
- App: `app/lib/features/` (`upload`, `processing`, `results`, `calibration`, `connect`), `app/lib/data/`, `app/lib/core/router/app_router.dart`

Everything flows through one JSON clip record. Keep it that way: new modules read from and write to the record, and the schema, `tests/fixtures/clip_record.schema.json`, the golden records on both sides and `docs/DATA_FORMAT.md` change together.

## Scope conflicts to resolve first

The PRD currently lists **live real-time streaming** and **official line calls** as out of scope, and the build plan treats the referee layer as a P3 stretch. Before coding:

- Update `docs/PRD.md` (scope, non-goals, requirements), `docs/DECISIONS.md` (record the reversal with reasons), `docs/PHASES.md` (new tasks, ordering, owners) and `README.md` (features, limitations, roadmap).
- Tell me anything in those docs that now contradicts the new scope instead of silently leaving it.

## Requirements

### A. Mode selection (app)
- First screen after connecting offers **Upload clip** or **Go live**. Remember the last choice in settings.
- Upload mode: unchanged behaviour, plus it must benefit from the new referee and coaching features.
- Live mode: camera preview (phone camera on Android/iOS, webcam on web/Windows), court corner calibration on the live frame (reuse the calibration screen), start/stop session, then a live results view mirroring the offline results layout (video + overlays, status bar, minimap, scoreboard, timeline).
- A live session is saved as a normal clip record and appears in History, so it can be replayed and chatted about afterwards.

### B. Live pipeline (backend)
- Add a streaming transport. Recommend WebSocket (or WebRTC if justified in `DECISIONS.md`): app sends frames, backend returns incremental events (shuttle position, players/pose, hit, stroke, rally state, line call, score, speed).
- Refactor stages so they can run frame-by-frame or in a sliding window (TrackNetV3 needs a small frame buffer; hit detection and stroke classification need a short look-behind). Offline and live must share the same stage code, not fork it.
- Define a latency budget (target under about 300 ms from frame to overlay on the team GPU) and a graceful degrade path: drop frames or lower resolution rather than lag behind. Show a visible "reduced quality" indicator when degrading.
- Handle disconnects, camera permission denial, backend unreachable, and session resume. Show clear errors.
- Add a mock/fake live source (replay a sample video as if it were a camera) so everything is testable in CI without a GPU or camera. See `backend/shuttlesense/fake.py` and `samples/`.

### C. Referee layer and line calls
- Rally state (in play / between rallies), hit count, rally timer, shuttle speed, assisted scoreboard with BWF 21-point rally scoring and manual correction, as in the reference video.
- **Line calls:** at each landing, project the shuttle to the court plane via the homography, decide IN or OUT against the correct lines for singles (and doubles if cheap), and emit `{call, landing_xy, margin_cm, confidence, uncertain}`. Show a clear IN/OUT banner and the landing marker on the minimap.
- Calls inside an uncertainty band (set from homography error and tracking error, configurable in `configs/pipeline.yaml`) are marked **UNCERTAIN** and let the user confirm or override. Overrides are logged and change the score.
- Be honest in the UI and docs: with one camera these are **automated calls with a stated confidence**. They are not certified Hawk-Eye-level officiating and must not be labelled "official" or "certified" in the product. Say so in `docs/PRD.md` and the README limitations. If I want the word "official" anyway, flag the trade-off to me and ask.
- Evaluate: add a labelled set of landings (use ShuttleSet plus my own phone clips), report precision/recall for IN/OUT and the false-call rate near lines in `docs/EVALUATION.md`. Do not claim accuracy numbers you have not measured.

### D. Coaching notes
- Per stroke: keep the rule-based tips from `feedback/rules.py`, and add pattern-level notes per session ("late split-step on 4 of 6 net shots", "smash contact behind the head in 3 of 5"). These are computed from the clip record, deterministic and testable.
- A session summary view with the top 3 things to fix, each linked to the timeline moments that show it (tap to seek).
- Tone: short, specific, actionable cues. Heuristic guidance, not professional coaching or medical advice (keep the existing disclaimer).
- Add any new rules to `docs/FEEDBACK_RULES.md` with source and threshold, and put thresholds in `configs/pipeline.yaml`.

### E. Coach chat
- Chat screen in the app, available from a finished or live session, with a clear "ask your coach" entry point.
- Backend endpoint (for example `POST /clips/{id}/chat`, streaming responses) that calls an LLM through the Claude API. Use a current Claude model and read the `claude-api` skill before writing it. Configure the API key server-side via env/settings only, never in the app, never committed.
- **Grounding:** build the prompt from the clip record (stroke table, form results, rally stats, line calls, pattern notes), and instruct the model to answer only from that data, say when the data does not show something, and never invent timestamps or stats. Cite timeline moments so the app can render tap-to-seek chips.
- Safety: same non-medical, non-professional-coaching disclaimer; refuse injury diagnosis; keep user clips private (state exactly what is sent to the API in `docs/` and in the app's settings or privacy text).
- Handle offline/no-key states gracefully (chat disabled with an explanation; coaching notes still work).
- Cost and rate limits: cap context size, summarise long sessions, add a per-session message limit setting.

## Data format changes
Extend the clip record (version bump, migration for old records) with at least: `mode` (`upload|live`), `line_calls[]`, `rally_events[]`, `coaching.session_notes[]`, `chat` (optional, message history), and per-event timestamps usable for tap-to-seek. Update `schema.py`, JSON schema fixture, golden records (backend and app), `docs/DATA_FORMAT.md`, `docs/API.md` and regenerate `docs/openapi.json`.

## Constraints
- Match existing code style, naming and comment density. Small, reviewable commits using the repo's conventional-commit style. **Do not add `Co-Authored-By` trailers to commits.**
- Keep the existing test suites green; add tests for each new module (backend pytest, Flutter widget and golden tests, the fake live source for streaming tests). Update the CI workflows if needed.
- Don't regress upload mode, accessibility tests, or the responsive layouts.
- No new heavy dependencies without recording the reason in `docs/TECH_STACK.md`.
- Do not push, tag or release.

## Process
1. Do not write code yet. Read the files above and reply with a short plan: the doc changes, the schema changes, the streaming design with its latency budget, the app screens, and a phased task list with risks. Call out anything that you think cannot be met honestly with one camera.
2. Wait for my approval of the plan.
3. Then do the docs and schema changes first, then backend, then app, one phase at a time, running tests after each phase.
4. At the end, update `README.md`, `docs/PHASES.md` and `docs/EVALUATION.md` with what is actually done and measured, and what is still a stretch.

## Done when
- I can choose Upload or Live; both produce a results view with referee overlays, scoreboard, line calls, coaching notes and chat.
- Live mode runs end-to-end against the fake live source in CI and on a real camera on my machine.
- All docs match the new scope, with no leftover "out of scope" statements that are now untrue.
- Tests pass, and every accuracy or latency claim in the docs is backed by a number I can reproduce.
