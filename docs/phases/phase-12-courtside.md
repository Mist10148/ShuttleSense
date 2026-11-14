# Phase 12 — Courtside referee and coach

[← Phase 11](phase-11-stroke-models.md) · [Phase overview](../PHASES.md)

> **Scope (Nov 14).** A review of the live referee and coach code, in the backend and the app, found
> bugs a referee or coach would hit courtside. It also found cheap gaps: joining a match in game 2,
> recording a let or a fault, a retirement, the screen locking mid-match, and no keyboard on a
> laptop. This phase fixes and fills them, and does the code-only steps still open in Phases 2, 4
> and 9. Nothing here needs footage, weights, a GPU or a device. Device checks of the new app pieces
> join the T8.14 and T8.15 courtside checklist.

| | |
| --- | --- |
| **Dates** | Sat Nov 14, 2026 (before the feature freeze on Nov 18) |
| **Goal** | The review findings are fixed with regression tests, the referee can record what happens in a real match, and the code-only steps of earlier phases are done |
| **Owners** | M1 (backend, API, docs), M3 (referee, coaching), M6 (app) |
| **Entry criteria** | Phases 10 and 11 on `main` |
| **Status** | Done Nov 14: every task landed with tests (backend 426, app 258), `ruff`, `flutter analyze` and `dart format` pass. Device checks of the new app pieces are open (see the end of this page) |
| **Exit gate** | Every task below is ✅; backend `pytest -m "not gpu"` and `ruff`, app `flutter analyze`, `flutter test` and `dart format` pass |

## Tasks

| ID | Task | Owner | Est. | Depends | Status |
| --- | --- | --- | --- | --- | --- |
| [T12.1](#t121) | Referee decision fixes (one undo, newest decision wins) | M1 + M3 | 4 h | T8.14 | ✅ |
| [T12.2](#t122) | Coach fixes (match result in the chat, notes kept) | M3 + M1 | 2 h | T8.8, T8.4 | ✅ |
| [T12.3](#t123) | Join a match under way, decision reasons, retirement (record 1.5) | M3 + M1 | 5 h | T8.13 | ✅ |
| [T12.4](#t124) | Match stats in the exports | M2 | 2 h | T5.10 | ✅ |
| [T12.5](#t125) | App live and scoreboard fixes, referee decisions | M6 | 5 h | T8.9, T8.14 | ✅ |
| [T12.6](#t126) | Courtside app controls: screen on, confirm Stop, keys, match over | M6 | 3 h | T8.9 | ✅ |
| [T12.7](#t127) | Code-only steps of Phases 2, 4 and 9 | M1 + M4 | 3 h | — | ✅ |
| [T12.8](#t128) | Docs | M1 | 1 h | — | ✅ |

---

<a id="t121"></a>
### T12.1 · Referee decision fixes

**Owner:** M1 + M3 · **Area:** backend · **Priority:** P3 · **Refs:** D32, T8.14

**Steps**
- [x] Undo takes back the newest of a correction, an award or a line-call override, by time. It used to pop only corrections, so award → override by mistake → Undo removed the award and kept the wrong call. Overrides are appended (the newest per rally applies), so undoing one restores the earlier call; REST undo also returns `line_calls`, and live sends the restored `line_call`.
- [x] An override after a winner correction on the same rally decides it. The older correction no longer masks it.
- [x] An award or correction after the match is won, which would change nothing, is refused: live `match_over`, REST `409`. Before, it sat on the undo stack.
- [x] A stage error in the final live tick is logged and the session is still saved.
- [x] A JPEG whose header declares far more pixels than the session (4× its frame) is refused before decoding.

**Tests.** `test_api.py` (undo order, override after correction, award after the match), `test_live.py` (the same live, final-tick failure, oversized JPEG).

---

<a id="t122"></a>
### T12.2 · Coach fixes

**Owner:** M3 + M1 · **Area:** backend · **Priority:** P3 · **Refs:** T8.8, T8.4

**Steps**
- [x] The chat digest states best of, per-game scores, games won and the winner, and tags each rally with its game in a multi-game match. It used to give only the last game's score, so the coach could not say who won a best of 3.
- [x] Session notes come before the rally and hit detail; a long session drops the oldest rallies' detail, never the notes.
- [x] The shots-out note ignores UNCERTAIN calls nobody confirmed (they decide no rally).

**Tests.** `test_chat.py`, `test_patterns.py`.

---

<a id="t123"></a>
### T12.3 · Join a match under way, decision reasons, retirement

**Owner:** M3 + M1 · **Area:** backend · **Priority:** P3 · **Refs:** D33, D21

**Steps**
- [x] `start_games` (games each side already won) on `POST /jobs`, the live `start` and `Score`; the game number, the change of ends at 11 in the deciding game and the match end follow from it.
- [x] `reason` (`let`, `fault`, `service_fault`, `misconduct`) on corrections and awards, REST and live.
- [x] `kind: "concede"`: `POST /jobs/{id}/score/concede` and a live `concede` message end the match for a retirement or walkover. Undo takes it back.
- [x] `interval` also after a game that does not end the match, with `interval_s` 60 or 120 (Laws 16.2).
- [x] Clip record 1.5 (optional fields only), JSON schema, OpenAPI, `DATA_FORMAT.md`, `API.md`.

**Tests.** `test_match.py` (game 2 and 3 starts, invalid starts, game interval, concession), `test_api.py`, `test_live.py`, `test_schema.py`.

---

<a id="t124"></a>
### T12.4 · Match stats in the exports

**Owner:** M2 · **Area:** backend · **Priority:** P2 · **Refs:** F13

**Steps**
- [x] `rallies.csv` gains `game`, `server_id`, `receiver_id`, `call`, `margin_cm` and `decision` (overrides and corrections in words), after the original columns.
- [x] `summary.json` gains `match`: games, games won, winner, concession, points won on serve per side, the longest rally and decision counts.

**Tests.** `test_logic.py::test_match_stats_and_referee_columns`, `test_api.py`.

---

<a id="t125"></a>
### T12.5 · App live and scoreboard fixes, referee decisions

**Owner:** M6 · **Area:** app · **Priority:** C · **Refs:** C5, C6, D32, D33

**Steps**
- [x] Live minimap: hit marks belong to the open rally (none between rallies). It marked every hit of the session. Offline between rallies, the hits since the last rally.
- [x] Scoreboard: the game header follows a scrub; finished games are listed (`G1 21–17`) and numbered from a mid-match start; the doubles game-service picker uses the job's or session's court; `isDoubles` is worked out once, not per rally and per hit.
- [x] Live controller: a double tap on Start opens one session; `match_over` and unknown error codes are notices, not the end of the session; Cancel ends the 90 s start wait.
- [x] Models: `score.game_service`, `start_games`, `interval_s`, `reason`, `concede`; undo replies restore line calls.
- [x] On a 1.5 backend: a **More** menu with fault, service fault, let and a confirmed retirement; a let shows as **Let**; "games already won" in the live setup for a best of 3.

**Tests.** `courtside_test.dart`, `live_test.dart` (double start, non-fatal errors).

---

<a id="t126"></a>
### T12.6 · Courtside app controls

**Owner:** M6 · **Area:** app · **Priority:** C · **Refs:** C5, TECH_STACK

**Steps**
- [x] The screen stays on from connecting to the end of the save (`wakelock_plus`, already in the build through media_kit).
- [x] Stop asks first once rallies or decisions exist; Back during a session asks too, instead of dropping the socket.
- [x] Keyboard (referee role): N / F point near / far, Z undo, L let, I / O confirm or override the call under review; listed under the controls on wide screens.
- [x] A won match shows a card with **Stop and save**; N and F stop awarding.

**Tests.** `live_test.dart` (screen on, Stop confirmation, keys, match-over card).

---

<a id="t127"></a>
### T12.7 · Code-only steps of Phases 2, 4 and 9

**Owner:** M1 + M4 · **Area:** app, backend, data · **Refs:** T2.2, T4.11, T9.2, T9.12

**Steps**
- [x] T4.11: connect, upload, history, settings, mode and chat screens at 200% text on a 360 dp phone, in `accessibility_test.dart` (no overflow found). The phone review stays open.
- [x] T2.2: a real TrackNet with random weights is loaded from a checkpoint with `map_location="cpu"` and run on CPU. Running the published weights on CPU stays open.
- [x] T9.2: `label_clip.py --boxes [--every 10]` labels the four player boxes, one slot at a time, into `labels/<clip>_boxes.csv`.
- [x] T9.12: `eval_doubles.py --boxes` reports ID switches (per labelled rally) and IDF1 under the best fixed assignment.
- [ ] T1.9: ShuttleSet's terms of use are still not recorded in TECH_STACK.md; they need a check of the upstream repository by a person.

---

<a id="t128"></a>
### T12.8 · Docs

**Steps**
- [x] This page; PHASES.md (table, timeline, snapshot, remaining work); D32 and D33; API.md, DATA_FORMAT.md, FEEDBACK_RULES.md, PRIVACY.md, TECH_STACK.md; step notes in Phases 2, 4, 8 and 9; README.

---

## Device checks (open)

Add these to the T8.14 / T8.15 courtside session:

- The screen stays on through a full game on an Android phone and an iPad.
- **More** → fault, service fault, let and retirement on a phone; a let reads as **Let** in the rally list.
- Joining at "games already won 1–1": game 3, ends change at 11, the match ends at 21.
- Keyboard N / F / Z / L / I / O on the Windows laptop with a webcam.
- Stop and Back confirmations; the match-over card after the last point.
