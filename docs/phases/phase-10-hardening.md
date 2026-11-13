# Phase 10 — Hardening and courtside follow-ups

[← Phase 9](phase-9-doubles.md) · [Phase overview](../PHASES.md)

> **Scope (Nov 14).** A review of `main` after the Phase 9 code and the Nov 13 redesign found
> bugs in the referee, the API, live hit detection, the evaluation scripts and the app. It also
> left a few steps in earlier phases that need only code or docs. This phase collects that work
> so it has task cards like every other phase. Nothing here needs footage, weights, a GPU or a
> device; device checks of the new app pieces join the existing device checklists.

| | |
| --- | --- |
| **Dates** | Sat Nov 14 – Tue Nov 17, 2026 (before the feature freeze on Nov 18) |
| **Goal** | The review findings are fixed with regression tests, a doubles match keeps its service order in every game, and the code-only steps left in Phases 4, 5 and 7 are done |
| **Owners** | M1 (backend, API, docs), M3 (referee), M6 (app) |
| **Entry criteria** | Phase 9 code on `main` (Nov 12–13) |
| **Exit gate** | Every task below is ✅; backend `pytest -m "not gpu"` and `ruff`, app `flutter analyze`, `flutter test` and `dart format` pass; web, Windows and Android release builds pass |

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T10.1](#t101) | Backend review fixes | M1 + M3 | 8 h | — | ⬜ | — |
| [T10.2](#t102) | App review fixes | M6 | 6 h | — | ⬜ | — |
| [T10.3](#t103) | Doubles service order in every game | M3 + M1 + M6 | 10 h | T9.6 | ⬜ | — |
| [T10.4](#t104) | Notify when a job finishes | M6 | 4 h | T4.4 | ⬜ | — |
| [T10.5](#t105) | Speed report by stroke class | M2 | 3 h | T5.6 | ⬜ | — |
| [T10.6](#t106) | Auth token tests | M4 | 2 h | T4.6 | ⬜ | — |
| [T10.7](#t107) | Docs sync and late decisions | M1 | 4 h | — | ⬜ | — |
| [T10.8](#t108) | media_kit library license notes | M1 | 2 h | T7.13 | ⬜ | — |

---

<a id="t101"></a>
### T10.1 · Backend review fixes

**Owner:** M1 + M3 · **Area:** backend · **Priority:** P3 · **Refs:** FR-P3, D21, D22

**Goal.** Fix the backend findings of the Nov 14 review, each with a regression test.

**Steps**
- [ ] `referee/scoring.py` `flag_service`: work out the score before each rally from the same
      match steps that set `server_id`, so awarded points count. Today an award followed by a
      rally gives a false "should serve from the … court" review flag.
- [ ] `fake.py`: a doubles job that sets `first_server` without slot ids must not keep the
      golden record's `near_1` / `far_1` slots (the job failed with "first_server_id must be on
      the first_server side"). With no first server, the fake record shows no service order.
- [ ] `api/models.py`, `api/live.py`: refuse `first_server_id` / `first_receiver_id` unless the
      court is doubles (`422` / `bad_request`).
- [ ] `api/jobs.py`: a job that does not name a court is singles; it no longer inherits
      `stages.referee.line_call.court` from `pipeline.yaml`.
- [ ] `DELETE /jobs/{id}` takes the job lock, so an edit in flight cannot recreate the folder.
- [ ] Re-render and coach chat: the "answer in flight" check and the re-render start happen
      under one lock.
- [ ] Live hit detection: frames that live perception skipped do not split a visible run and do
      not count as "hidden" between two hits.
- [ ] `scripts/eval_line_calls.py`: drop non-finite projected landings; ShuttleSet rallies are
      matched on their start, and the report states how many rallies did not match.

**Tests.** One per step in `tests/` (referee, fake pipeline, API, live hits, eval script).

**Acceptance criteria.** The scenarios above fail before the fix and pass after it; the full
non-GPU suite passes.

**Risks.** Live hit changes could move the offline/live parity test (D20). Fallback: keep the
offline result as the reference and change only the live window.

---

<a id="t102"></a>
### T10.2 · App review fixes

**Owner:** M6 · **Area:** app · **Priority:** C · **Refs:** C-live, C-chat, C-results

**Goal.** Fix the app findings of the Nov 14 review, each with a test.

**Steps**
- [ ] Live: when the socket closes during connecting or reconnecting, fail at once instead of
      waiting 90 s for `started` (about 7.5 min across reconnect attempts).
- [ ] Live: the "Game already under way" start score is kept until the session has started,
      so Try again does not restart at 0–0.
- [ ] Chat: a question that fails (429, server error, network) goes back into the input box.
- [ ] Results: the stroke chart legend wraps instead of overflowing in a narrow side panel.
- [ ] Doubles wording: rally winner tooltips and the minimap heat description say "pair".
- [ ] Minimap: a doubles hit with no known partner is drawn in a neutral colour, not as partner 1.
- [ ] Live minimap: a doubles session draws the doubles court from the start.

**Tests.** Widget or unit tests in `app/test/` for each step.

**Acceptance criteria.** `flutter analyze`, `flutter test` and `dart format` pass.

---

<a id="t103"></a>
### T10.3 · Doubles service order in every game

**Owner:** M3 + M1 + M6 · **Area:** backend, app · **Priority:** P3 · **Refs:** T9.6, D21, D23

**Goal.** Today the doubles service order stops after game 1, because the game winners choose
who serves and receives next. Let the user give the server and receiver for each later game, so
`server_id`, `receiver_id` and the service check work for the whole match.

**Inputs.** `referee/match.py` (`play`, `courts = None` at the end of a game), `Score`,
`corrections.json`, the live control messages, `match_setup_field.dart`.

**Steps**
- [ ] Record the chosen slots per game (game number, server, receiver) with the score and keep
      them through re-renders like other user changes (D10, D21).
- [ ] `play()` restarts the service order at a game that has slots.
- [ ] REST: `POST /jobs/{id}/score/service` sets or clears a game's slots.
      Live: a `service` control message does the same and is answered with a score update.
- [ ] App: once a doubles game is won, the referee view and the results scoreboard offer
      "Who serves game N?" (server and receiver).
- [ ] Docs: API, DATA_FORMAT, README limits, DECISIONS (D23).

**Outputs.** Per-game service slots in the record; rallies in games 2 and 3 carry `server_id`
and `receiver_id` when the slots are set.

**Tests.** Table-driven `play()` tests over three games; REST and live round trips; an app
widget test for the picker.

**Acceptance criteria.** A three-game doubles match with slots for games 2 and 3 has a
`server_id` on every decided rally; singles records are unchanged.

**Risks.** A record change: keep it additive (clip record 1.3, `migrate()` upgrades older
records; the app accepts any 1.x).

---

<a id="t104"></a>
### T10.4 · Notify when a job finishes

**Owner:** M6 · **Area:** app · **Priority:** C · **Refs:** T4.4

**Goal.** The open step of T4.4: a local notification when processing ends while the app is in
the background.

**Steps**
- [ ] A `JobNotifier` behind a provider, with a no-op version on web and in tests.
- [ ] The processing screen calls it when a job ends (done or failed) and the app is not in the
      foreground.
- [ ] A Settings switch, on by default; Android 13+ asks for the notification permission
      the first time.

**Tests.** The processing screen calls the notifier only in the background, and not when the
switch is off.

**Acceptance criteria.** Unit and widget tests pass; web, Windows and Android release builds
pass. The phone check joins the T4.4 device checks.

**Risks.** A notification plugin can break a platform build. Fallback: keep the notifier
interface with only the in-app banner, and note the plugin problem here.

---

<a id="t105"></a>
### T10.5 · Speed report by stroke class

**Owner:** M2 · **Area:** ml, docs · **Priority:** P2 · **Refs:** T5.6, T5.13

**Goal.** `docs/results/speed.md` is made by a script, not by hand.

**Steps**
- [ ] `scripts/speed_report.py RECORD.json [...] --out docs/results/speed.md --plot speed.png`:
      count, median and 90th percentile of the estimated speed per stroke class, and a box plot.
- [ ] `docs/results/README.md` names the script.

**Tests.** The script on the golden record gives one row per class with hits.

**Acceptance criteria.** The test passes. The T5.13 check itself still needs calibrated team clips.

---

<a id="t106"></a>
### T10.6 · Auth token tests

**Owner:** M4 · **Area:** app · **Priority:** C · **Refs:** T4.6

**Goal.** Cover the token handling that T4.6 asks to verify: the `Authorization` header on API
calls and the token on the video URL.

**Tests.** API client sends the header when a token is set and not otherwise; the video URL
carries the token.

**Acceptance criteria.** The tests pass. The on-device check stays with T4.6.

---

<a id="t107"></a>
### T10.7 · Docs sync and late decisions

**Owner:** M1 · **Area:** docs · **Refs:** T7.8, T7.12

**Steps**
- [ ] Fix stale lines found in the review: live re-render in ARCHITECTURE; latency numbers in
      the PRD, README and EVALUATION; singles-only wording; the expected schema in Phase 4; the
      superseded open items in PHASES.md.
- [ ] ARCHITECTURE: a doubles section.
- [ ] DECISIONS: D23 and the late decisions (change of ends in a one-game match, saved live jobs
      re-render the saved analysis, capture-time frame slots, design tokens).
- [ ] README: every relative link resolves (T7.8).

**Acceptance criteria.** No doc contradicts the code on these points; a link check passes.

---

<a id="t108"></a>
### T10.8 · media_kit library license notes

**Owner:** M1 · **Area:** docs · **Refs:** T7.13

**Goal.** Record the licenses of the libmpv and FFmpeg builds that media_kit bundles, and what a
release must ship with them.

**Steps**
- [ ] `docs/TECH_STACK.md`: library, version, license and the notice/source obligations per
      platform, from the upstream media_kit build repositories.

**Acceptance criteria.** The T7.13 doc step is ticked; the ML venv scan stays open (it needs the
ML requirements installed).

## Risks across the phase

| Risk | Effect | Fallback |
| --- | --- | --- |
| Fixes change singles output | Release path moves | Singles goldens and the full suite must pass unchanged |
| New plugin breaks a build | No release build | Drop the plugin, keep the interface (T10.4) |
| Late work near the freeze | Rushed merges | Every task is small and lands with its own tests |
