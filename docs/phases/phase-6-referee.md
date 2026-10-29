# Phase 6 — P3 referee (stretch)

[← Phase 5](phase-5-analysis.md) · [Phase overview](../PHASES.md) · Next: [Phase 7 — Freeze, evaluation, release →](phase-7-release.md)

| | |
| --- | --- |
| **Dates** | Mon Nov 16 – Wed Nov 18, 2026 |
| **Goal** | Rally state, landing and in/out estimation, and an assisted BWF scoreboard with manual correction |
| **Owners** | M3 (referee logic), M1 (API), M6 (app scoreboard), M2 (overlays) |
| **Entry criteria** | **Go/no-go on Mon Nov 16:** Phases 2–5 exit gates passed or only cosmetic issues open. If not, skip this phase and move F14–F16 to Future work (see [cut lines](../PHASES.md#cut-lines)) |
| **Exit gate** | On team footage, rally boundaries ≥ 80% correct, score updates after each rally and corrections persist; or the phase is formally cut at the freeze |
| **Milestone** | `Phase 6 — P3 referee` (due Nov 18) |

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T6.1](#t61) | Rally state detection | M3 | 6 h | T3.6 | ⬜ | [#76](https://github.com/Mist10148/ShuttleSense/issues/76) |
| [T6.2](#t62) | Landing point and in/out with confidence | M3 | 6 h | T6.1, T5.2 | ⬜ | [#77](https://github.com/Mist10148/ShuttleSense/issues/77) |
| [T6.3](#t63) | BWF scoring and rally winner | M3 | 4 h | T6.2 | ⬜ | [#78](https://github.com/Mist10148/ShuttleSense/issues/78) |
| [T6.4](#t64) | Score correction API | M1 | 3 h | T6.3 | ⬜ | [#79](https://github.com/Mist10148/ShuttleSense/issues/79) |
| [T6.5](#t65) | App scoreboard with corrections and rally state | M6 | 4 h | T6.4, T4.5 | ⬜ | [#80](https://github.com/Mist10148/ShuttleSense/issues/80) |
| [T6.6](#t66) | Scoreboard and rally-state overlays | M2 | 3 h | T6.3 | ⬜ | [#81](https://github.com/Mist10148/ShuttleSense/issues/81) |
| [T6.7](#t67) | Rally boundary labels and evaluation | M3 | 3 h | T7.1 | ⬜ | [#82](https://github.com/Mist10148/ShuttleSense/issues/82) |

---

<a id="t61"></a>
### T6.1 · Rally state detection

**Owner:** M3 · **Estimate:** 6 h · **Priority:** P3 · **Area:** backend · **Refs:** F14, FR-14 · **Depends on:** T3.6 · **Blocks:** T6.2, T6.7

**Inputs.** `record.hits`, `frames[].shuttle`, config `stages.referee` (`stationary_frames_end`, `lost_frames_end`).

**Steps**
- [ ] In `referee/rally.py`, add a pure state machine `segment_rallies(visible, xy, hits, cfg) -> list[(start, end)]`:
  - start: the first hit after ≥ `lost_frames_end` frames of no play (serve), or the first hit of the clip;
  - end: shuttle invisible for `lost_frames_end` frames, or shuttle y-position stationary (< 3 px movement) for `stationary_frames_end` frames after the last hit.
- [ ] Fill `rallies[]` (index, start_frame, end_frame, stroke_count), `hits[].rally_index`, and `frames[].rally_state` (`in_play` inside a rally, `between_rallies` outside).
- [ ] Handle clips that start mid-rally (first rally has no serve) and end mid-rally (last rally open: `end_frame = num_frames - 1`, winner null).

**Tests** (`tests/test_referee.py`): `test_two_rallies_separated_by_pause`, `test_rally_ends_when_shuttle_stationary`, `test_clip_starting_mid_rally`.

**Acceptance criteria.** On team clips, boundaries within ±1 s of manual labels for ≥ 80% of rallies (measured in T6.7).

---

<a id="t62"></a>
### T6.2 · Landing point and in/out with confidence

**Owner:** M3 · **Estimate:** 6 h · **Priority:** P3 · **Area:** backend · **Refs:** F15, FR-15 · **Depends on:** T6.1, T5.2 · **Blocks:** T6.3

**Steps**
- [ ] Landing frame = first frame after the last hit where the shuttle's vertical image velocity drops to ~0 and it stays (from T6.1's end rule), or the last visible frame.
- [ ] Project the shuttle position at the landing frame with `image_to_court`; the shuttle is on the floor there, so the projection is valid.
- [ ] In/out for singles: inside `0 ≤ x ≤ 5.18`, `0 ≤ y ≤ 13.40` (long service line for singles = baseline).
- [ ] Confidence from distance to the nearest line: `min(1, d / 0.3 m)`; below `in_out_margin_m` → mark `uncertain` (confidence < 0.5) and never auto-award without user confirmation in the app.
- [ ] Fill `rallies[].landing`.

**Tests.** `test_referee.py::test_inside_court_is_in`, `::test_close_to_line_is_uncertain`, `::test_landing_frame_is_after_last_hit`.

**Acceptance criteria.** Clear in/out cases correct on test rallies; close calls flagged.

---

<a id="t63"></a>
### T6.3 · BWF scoring and rally winner

**Owner:** M3 · **Estimate:** 4 h · **Priority:** P3 · **Area:** backend · **Refs:** F16, FR-16 · **Depends on:** T6.2 · **Blocks:** T6.4, T6.6

**Inputs.** `referee/scoring.py::game_winner` (21 points, win by 2, cap 30).

**Steps**
- [ ] Winner rule: landing **in** on a player's side → the other player wins the rally; landing **out** → the player who hit last loses. Hitter of the last shot from `hits`; side from landing `y` (< 6.70 m near half).
- [ ] Add `apply_rallies(rallies, start_score=(0, 0)) -> list[ScorePair]` that computes `score_after` for each rally and stops at `game_winner`.
- [ ] Optional starting score from the job request (`POST /jobs` field `start_score`, API change) for clips that start mid-game.
- [ ] Fill `rallies[].winner`, `score_after`, and `record.score`.

**Tests.** Existing `test_bwf_game_winner`; add `test_out_shot_loses_rally`, `test_in_shot_wins_rally`, `test_score_sequence`, `test_deuce_to_30`.

**Acceptance criteria.** Score sequence correct on a hand-built 10-rally scenario and on team footage.

---

<a id="t64"></a>
### T6.4 · Score correction API

**Owner:** M1 · **Estimate:** 3 h · **Priority:** P3 · **Area:** backend · **Refs:** F16 · **Depends on:** T6.3 · **Blocks:** T6.5

**Inputs.** `PATCH /jobs/{id}/score` in `api/routes.py` (partially implemented: changes the winner and appends a correction).

**Steps**
- [ ] Recompute `score_after` for all rallies after the corrected one using `apply_rallies`.
- [ ] Regenerate `summary.json` and `hits.csv` (`write_exports`).
- [ ] Concurrency: protect the read-modify-write with a per-job lock in `JobManager`.
- [ ] Return the updated `score` and `rallies`.

**Tests.** `test_api.py::test_score_correction_recomputes_following_rallies`, `::test_correction_409_without_referee`.

**Acceptance criteria.** A correction changes the score, is logged in `score.corrections` and survives a server restart.

---

<a id="t65"></a>
### T6.5 · App scoreboard with corrections and rally state

**Owner:** M6 · **Estimate:** 4 h · **Priority:** P3 · **Area:** app · **Refs:** F14, F16 · **Depends on:** T6.4, T4.5 · **Blocks:** —

**Inputs.** `features/results/widgets/scoreboard.dart`, `StatusStrip`, `ApiClient.correctScore`.

**Steps**
- [ ] Parse `rallies` in `ClipRecord` (winner, landing, score_after).
- [ ] Scoreboard shows the score at the current playback position (last rally ended before the current frame).
- [ ] Rally list with winner chips; tapping a chip flips the winner via `correctScore`, then refreshes the record.
- [ ] Uncertain in/out calls show a "?" and ask the user to confirm.
- [ ] Status strip shows IN PLAY / BETWEEN RALLIES from `frames[].rally_state`.

**Tests.** `test/scoreboard_test.dart`: score follows playback; correction calls the API.

**Acceptance criteria.** Correction updates the score on phone, tablet and laptop layouts.

---

<a id="t66"></a>
### T6.6 · Scoreboard and rally-state overlays

**Owner:** M2 · **Estimate:** 3 h · **Priority:** P3 · **Area:** backend · **Refs:** F14, F16 · **Depends on:** T6.3 · **Blocks:** —

**Steps**
- [ ] `score` layer: scoreboard box (Near : Far) updating after each rally, like the reference demo.
- [ ] Rally state text in the status bar; landing marker (in = green, out = red, uncertain = yellow) for 1 s after landing.

**Tests.** `test_render.py::test_score_layer_updates_after_rally`.

**Acceptance criteria.** Overlays visible and in sync on a multi-rally clip.

---

<a id="t67"></a>
### T6.7 · Rally boundary labels and evaluation

**Owner:** M3 · **Estimate:** 3 h · **Priority:** P3 · **Area:** data · **Refs:** Success metrics (rally boundary ≥ 80%) · **Depends on:** T7.1 · **Blocks:** T7.2

**Steps**
- [ ] Use T7.1 labels (rally start/end times) for team footage.
- [ ] `scripts/eval_rallies.py`: a rally is correct if start and end are within ±1 s of the label; report accuracy and the score sequence vs ground truth.

**Tests.** `tests/test_eval.py::test_rally_boundary_matching`.

**Acceptance criteria.** Accuracy reported in README Evaluation.

---

## Phase gate checklist (Nov 18, at feature freeze)

1. Process a multi-rally team clip with the referee layer on.
2. Show rally state changes and the score updating in the video and the app.
3. Correct one rally in the app; show the score change and the correction log.
4. Decide: ship P3, ship it labelled "beta", or cut it to Future work.
