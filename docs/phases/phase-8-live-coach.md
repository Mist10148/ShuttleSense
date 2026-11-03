# Phase 8 — Live mode, line calls and coaching

[← Phase 7](phase-7-release.md) · [Phase overview](../PHASES.md)

| | |
| --- | --- |
| **Dates** | Mon Nov 9 – Wed Nov 18, 2026 (runs alongside Phases 5 and 6) |
| **Goal** | The user picks Upload or Live; both end in a results view with referee overlays, scoreboard, line calls, coaching notes and a coach chat |
| **Owners** | M1 (schema, live socket, chat API), M2 (incremental tracking, latency), M3 (line calls, session notes), M4 (labelled landings, evaluation, app chat), M6 (mode picker, live screen, summary) |
| **Entry criteria** | PRD v1.2 and decisions D16–D20 merged; Phase 5 court stage and Phase 6 rally segmentation on `main` |
| **Exit gate** | Live runs end to end against the fake live source in CI and on a real camera on the team laptop; line calls carry margin, confidence and an UNCERTAIN state with override; notes and chat work on a finished upload and a saved live session; every accuracy or latency number in the docs comes from a script in the repo |
| **Milestone** | `Phase 8 — Live and coach` (due Nov 18) |

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T8.1](#t81) | Scope reversal in the docs | M1 | 2 h | — | ✅ | [#97](https://github.com/Mist10148/ShuttleSense/issues/97) |
| [T8.2](#t82) | Clip record v1.1 and migration | M1 | 4 h | T8.1 | ✅ | [#98](https://github.com/Mist10148/ShuttleSense/issues/98) |
| [T8.3](#t83) | Line calls with uncertainty band and override | M3 | 6 h | T6.2, T8.2 | ⬜ | [#99](https://github.com/Mist10148/ShuttleSense/issues/99) |
| [T8.4](#t84) | Session coaching notes and top fixes | M3 | 5 h | T5.8, T8.2 | ✅ | [#100](https://github.com/Mist10148/ShuttleSense/issues/100) |
| [T8.5](#t85) | Incremental stage cores and parity test | M2 + M1 | 10 h | T8.2 | ✅ | [#101](https://github.com/Mist10148/ShuttleSense/issues/101) |
| [T8.6](#t86) | Live WebSocket session, degrade, resume, save | M1 | 8 h | T8.5 | ⬜ | [#102](https://github.com/Mist10148/ShuttleSense/issues/102) |
| [T8.7](#t87) | Fake live source and streaming tests in CI | M1 | 3 h | T8.6 | ✅ | [#103](https://github.com/Mist10148/ShuttleSense/issues/103) |
| [T8.8](#t88) | Coach chat endpoint (Claude API) | M1 | 6 h | T8.4 | ⬜ | [#104](https://github.com/Mist10148/ShuttleSense/issues/104) |
| [T8.9](#t89) | App mode picker and live screen | M6 | 10 h | T8.6 | ⬜ | [#105](https://github.com/Mist10148/ShuttleSense/issues/105) |
| [T8.10](#t810) | App line-call banner, minimap landings, session summary | M6 | 6 h | T8.3, T8.4 | ⬜ | [#106](https://github.com/Mist10148/ShuttleSense/issues/106) |
| [T8.11](#t811) | App coach chat screen | M4 | 5 h | T8.8 | ⬜ | [#107](https://github.com/Mist10148/ShuttleSense/issues/107) |
| [T8.12](#t812) | Line-call and live latency evaluation | M4 + M2 | 5 h | T8.3, T8.6, T7.1 | ⬜ | [#108](https://github.com/Mist10148/ShuttleSense/issues/108) |
| [T8.13](#t813) | Match play: games, server, service court, intervals | M3 + M1 | 4 h | T6.3 | ✅ | [#109](https://github.com/Mist10148/ShuttleSense/issues/109) |
| [T8.14](#t814) | Award a point, clear a winner, undo | M1 + M6 | 3 h | T8.13 | ⬜ | [#110](https://github.com/Mist10148/ShuttleSense/issues/110) |
| [T8.15](#t815) | Between-rally coaching in live mode | M3 + M6 | 4 h | T8.4, T8.6 | ⬜ | [#111](https://github.com/Mist10148/ShuttleSense/issues/111) |
| [T8.16](#t816) | Live state snapshot on start and resume | M1 + M6 | 2 h | T8.6 | ✅ | [#112](https://github.com/Mist10148/ShuttleSense/issues/112) |

### Added on Nov 3

T8.13–T8.16 came out of a review of what a referee or coach courtside needs and are on `main` with tests. T8.14 and T8.15 stay ⬜ until they are tried on a device in a real session. Issues #109–#112 (the ✅ ones closed).

### Reliability follow-up on Nov 4

Re-rendering a saved live session now draws from its saved record, preserving the original
singles or doubles calls, score corrections and coaching. Skipped perception frames are treated
as unobserved when detecting a rally end; prolonged skipping can delay a decision and still
miss hits. Capture-time-based playback and portrait camera alignment remain open, as do the
real-camera, device, accuracy and latency checks in the task cards below. Doubles partners and
individual service order are not tracked, and 2D pose does not establish serve height.

### Status on Oct 31

Code for every task is on `main` with tests (backend `pytest -m "not gpu"`, app `flutter test`). A task stays ⬜ until its acceptance check is met:

- **T8.3:** calls, band and override work and are tested; the accuracy check waits for labelled landings (T8.12).
- **T8.6:** runs end to end against the fake source in CI; still needs a session on a real camera against a server with weights.
- **T8.8:** tested with a fake client; still needs one run with a real API key to check answers and citations.
- **T8.9–T8.11:** widget, layout and accessibility tests pass; Windows and web release builds pass; device checks (Android phone, tablet, Windows webcam, Chrome) are open.
- **T8.12:** scripts are in; only the fake-perception latency is measured.

---

<a id="t81"></a>
### T8.1 · Scope reversal in the docs

**Owner:** M1 · **Priority:** P3 · **Area:** docs · **Refs:** F18–F22

**Steps**
- [x] PRD v1.2: live mode, line calls and coaching in scope; "official/certified" calls and medical advice stay non-goals.
- [x] D16–D20 in `DECISIONS.md`; D3 marked superseded for live only.
- [x] README features, limitations, privacy; `PRIVACY.md`.

**Acceptance criteria.** No doc still calls live streaming or line calls out of scope.

---

<a id="t82"></a>
### T8.2 · Clip record v1.1 and migration

**Owner:** M1 · **Priority:** P3 · **Area:** backend · **Refs:** D19

**Steps**
- [x] `schema.py`: `mode`, `line_calls[]`, `rally_events[]`, `coaching`, `chat`, `FeedbackItem.value`; `SCHEMA_VERSION = "1.1"`.
- [x] `schema.migrate(data)` upgrades 1.0 dicts (derives `line_calls` from `rallies[].landing`); every record load goes through it.
- [x] Regenerate the JSON schema snapshot, golden records (backend and app) and `docs/openapi.json`; update `DATA_FORMAT.md`.
- [x] Dart models parse the new fields; the app accepts any `1.x` schema.

**Tests.** `test_schema.py::test_migrate_1_0_record`, `models_test.dart` v1.1 parsing.

---

<a id="t83"></a>
### T8.3 · Line calls with uncertainty band and override

**Owner:** M3 · **Priority:** P3 · **Area:** backend · **Refs:** F20, FR-20

**Steps**
- [x] `court/lines.py`: doubles width and doubles lines next to the singles ones.
- [x] `referee/linecalls.py::call_landing(point_m, court, band_m)`: signed distance to the nearest relevant line (positive inside), `call`, `margin_cm`, `confidence`, `uncertain = |margin| < band`.
- [x] Band = `max(min_band_m, sqrt(homography_err_m² + tracking_err_m²))` from `stages.referee.line_call` in `pipeline.yaml`.
- [x] Fill `line_calls[]` and keep `rallies[].landing` in sync; `PATCH /jobs/{id}/line-calls/{n}` stores an override in `line_call_overrides.json` and re-scores.

**Tests.** `tests/test_linecalls.py` (inside, outside, on the line, inside the band, doubles), `test_api.py::test_line_call_override_rescores`.

**Acceptance criteria.** A call never reads "official"; overrides change the score and survive re-render.

---

<a id="t84"></a>
### T8.4 · Session coaching notes and top fixes

**Owner:** M3 · **Priority:** P3 · **Area:** backend · **Refs:** F21, FR-21

**Steps**
- [x] Keep each rule's measured value in `feedback[].value`.
- [x] `feedback/patterns.py`: per rule and stroke class, count failures over the session; a note fires when `failures ≥ min_count` and `failures / total ≥ min_rate`; text like "Contact below the head on 3 of 5 smashes".
- [x] Rank by failures × severity, take the top 3 as `coaching.top_fixes`; every note lists its moments (`frame`, `time_s`, `hit_id`).
- [x] Thresholds in `stages.feedback.patterns`; rows in `FEEDBACK_RULES.md`.

**Tests.** `tests/test_patterns.py` (deterministic, thresholds, ranking, moments).

---

<a id="t85"></a>
### T8.5 · Incremental stage cores and parity test

**Owner:** M2 + M1 · **Priority:** P3 · **Area:** backend · **Refs:** D20

**Steps**
- [x] Factor each stage into a pure core over arrays that both the batch `run()` and the streaming session call (tracking window, outlier/gap filling, pose per frame, hit detection over a trailing window, stroke window, feedback, speed, rally end and landing).
- [x] `stream/session.py` keeps ring buffers and commits an event once the stage's look-ahead has passed.
- [x] Live-only differences: background median from the first frames, InpaintNet off, trailing smoothing.

**Tests.** `tests/test_stream.py::test_offline_live_parity`.

---

<a id="t86"></a>
### T8.6 · Live WebSocket session, degrade, resume, save

**Owner:** M1 · **Priority:** P3 · **Area:** backend · **Refs:** F19, FR-19, D16

**Steps**
- [x] `WS /live`: `start`, binary JPEG frames, `override`, `correct`, `stop`, `resume`; events `frame`, `hit`, `rally`, `line_call`, `score`, `degraded`, `saved`, `error`.
- [x] Newest-frame queue; when p95 processing time over the last 30 frames is above the budget, lower the input resolution, then skip frames, and send `degraded`.
- [x] Keep a disconnected session for 60 s so the app can resume; refuse a second session while the GPU is busy.
- [x] On `stop`, write the received frames to `source.mp4` and the record as a normal done job with `mode = "live"`.

**Tests.** `tests/test_live.py` (protocol, degrade, resume, save, auth).

---

<a id="t87"></a>
### T8.7 · Fake live source and streaming tests in CI

**Owner:** M1 · **Priority:** P3 · **Area:** infra

**Steps**
- [x] `stream/fake_source.py` replays a video as camera frames; `python -m shuttlesense.live_replay` drives a running server.
- [x] With `SHUTTLESENSE_FAKE_PIPELINE=1` the live session plays the golden record's events, so CI needs no GPU or camera.

---

<a id="t88"></a>
### T8.8 · Coach chat endpoint (Claude API)

**Owner:** M1 · **Priority:** P3 · **Area:** backend · **Refs:** F22, FR-22, D18

**Steps**
- [x] `coach/digest.py` builds a capped text digest of the record; `coach/chat.py` streams answers; `POST /jobs/{id}/chat` returns Server-Sent Events.
- [x] System prompt: answer only from the digest, say when the data does not show something, cite `[t=12.3s]`, no injury diagnosis.
- [x] Citations are checked against real frames before they reach the app; history saved in `record.chat`.
- [x] Key and model in backend settings only; `/health` reports `chat_available`; per-session message limit.

**Tests.** `tests/test_chat.py` with a fake client (no network).

---

<a id="t89"></a>
### T8.9 · App mode picker and live screen

**Owner:** M6 · **Priority:** P3 · **Area:** app · **Refs:** F18, F19, C5

**Steps**
- [x] Mode picker after connect; choice saved in `shared_preferences`.
- [x] Live screen: camera preview, live calibration (calibration screen on a captured still), start/stop, live layout with status, minimap, scoreboard and timeline; reduced-quality chip.
- [x] Errors: camera permission denied, backend unreachable, socket dropped (auto resume).

**Tests.** Widget tests with a fake frame source and a fake socket; accessibility guidelines.

---

<a id="t810"></a>
### T8.10 · App line-call banner, minimap landings, session summary

**Owner:** M6 · **Priority:** P3 · **Area:** app · **Refs:** F20, F21, C6

**Steps**
- [x] IN / OUT / UNCERTAIN banner with confirm and override; landing markers on the minimap.
- [x] Session summary with the top 3 fixes; each moment chip seeks the video.

---

<a id="t811"></a>
### T8.11 · App coach chat screen

**Owner:** M4 · **Priority:** P3 · **Area:** app · **Refs:** F22, C6

**Steps**
- [x] "Ask your coach" from results; streamed answers; citation chips seek the video; disabled with an explanation when the backend has no key; privacy note.

---

<a id="t812"></a>
### T8.12 · Line-call and live latency evaluation

**Owner:** M4 + M2 · **Priority:** P3 · **Area:** data · **Refs:** Success metrics

**Steps**
- [ ] Landing labels: ShuttleSet landing positions converted to court metres where the court is calibrated, plus team phone clips labelled with `scripts/label_landings.py`.
- [x] `scripts/eval_line_calls.py`: precision/recall for IN and OUT, false-call rate for landings within 20 cm of a line, share of UNCERTAIN calls.
- [x] `scripts/bench_live.py`: frame-to-event latency p50/p95 and event lag per event type; fake run in `docs/results/live_latency.md` (Nov 3).
- [ ] The same with TrackNetV3 and pose on the team GPU.
- [x] Report in `docs/EVALUATION.md` only what was run.

---

<a id="t813"></a>
### T8.13 · Match play: games, server, service court, intervals

**Owner:** M3 + M1 · **Priority:** P3 · **Area:** backend · **Refs:** F16, D21

**Steps**
- [x] `referee/match.py::play(winners, start, best_of, first_server)`: per-rally game and score, finished games, games won, next server (rally winner; game winner serves first), service court from the server's score parity, interval at 11, change of ends after a game and at 11 in the deciding game, game and match point, match winner.
- [x] `scoring.apply_rallies` uses it; `best_of` (1 or 3) and `first_server` on `POST /jobs` and the live `start`; the new `Score` fields and `Rally.game` are optional v1.1 additions.
- [x] Start scores above 29 in an open game are refused (upload and live share `validate_start_score`).

**Tests.** `tests/test_match.py`, `test_api.py::test_job_match_settings_reach_the_record`, `test_live.py` start-message cases.

**Acceptance criteria.** With `best_of=1` the old single-game behaviour is unchanged; every correction re-derives the whole match.

---

<a id="t814"></a>
### T8.14 · Award a point, clear a winner, undo

**Owner:** M1 + M6 · **Priority:** P3 · **Area:** backend, app · **Refs:** F16, D21

**Steps**
- [x] `ScoreCorrection.kind = "award"` places a point before the next detected rally; `winner_after: null` clears a rally. Kept in `corrections.json` (survives re-renders).
- [x] Live `award` and `undo` messages; REST `POST /jobs/{id}/score/award` and `/score/undo`.
- [x] App scoreboard: Point Near / Point Far, Undo, tap the chosen winner to clear; live decisions while reconnecting are refused with a message.
- [ ] Try it courtside: award a missed rally and undo it during a real live session.

**Tests.** `test_live.py::test_live_award_clear_and_undo`, `test_api.py::test_award_and_undo_over_rest`, `scoreboard_test.dart`, `live_test.dart`.

---

<a id="t815"></a>
### T8.15 · Between-rally coaching in live mode

**Owner:** M3 + M6 · **Priority:** P3 · **Area:** backend, app · **Refs:** F21

**Steps**
- [x] After each closed rally the server sends `coaching`: the session notes and top fixes so far (same `feedback/patterns.py` as the saved session) and a rally summary (length, strokes, peak speed, winner, call, form faults).
- [x] Live coach panel: last rally and "Focus so far"; a callout for the newest hit.
- [ ] Check on a device that the panel is readable between rallies at arm's length (phone and tablet).

**Tests.** `test_live.py::test_started_snapshot_and_coaching_between_rallies`, `live_test.dart` referee and coach panels.

---

<a id="t816"></a>
### T8.16 · Live state snapshot on start and resume

**Owner:** M1 + M6 · **Priority:** P3 · **Area:** backend, app · **Refs:** F19

**Steps**
- [x] `started` carries `score`, `rallies`, `line_calls`, `hits` and `coaching`; the app seeds its view from it, so a start score shows at once and a resume restores what was missed.

**Tests.** `test_live.py` resume and snapshot tests, `live_test.dart` "started restores the session so far".

---

## Phase gate checklist

1. Upload a clip: results show line calls, the session summary and chat.
2. Go live with the laptop webcam: overlays, score and calls update during play; stop saves the session to History.
3. Override an UNCERTAIN call; the score changes. Award a missed point and undo it.
4. Live with Best of 3 and a first server: the scoreboard shows who serves from which court and the coach panel fills after each rally.
5. Show the latency, event-lag and line-call numbers next to the commands that produced them.
