# Phase 9 — Doubles support

[← Phase 8](phase-8-live-coach.md) · [Phase overview](../PHASES.md) · [Phase 10 →](phase-10-hardening.md)

> **Scope (D22, Nov 12).** Doubles moved into scope and its code lands on `main` before the
> feature freeze, under one rule: the singles path stays behaviourally identical. Every
> existing test passes, and singles records serialize as before because new fields are left
> out when empty. Accuracy work (T9.2, T9.12 numbers, T9.7 training) needs doubles footage
> and continues after `v1.0.0`. Milestone "Phase 9 — Doubles support", issues #113–#125.

| | |
| --- | --- |
| **Dates** | Code from Thu Nov 12, 2026; footage, labels and measurement after `v1.0.0` (estimates below sum to ~150 h) |
| **Goal** | A doubles rally gets four stable player IDs, each hit is credited to one player, the doubles service order is followed, and the app shows four players in every view |
| **Owners** | M1 (schema, API, live), M2 (4-player tracking), M3 (service order, feedback rules), M4 (labels, evaluation), M5 (hitter attribution, strokes), M6 (app) |
| **Entry criteria** | [D22](../DECISIONS.md) (scope and record shape) merged; for the measurement tasks, at least 5 consented doubles rallies recorded |
| **Exit gate** | On labelled doubles clips: ID switches, hitter attribution and service order are measured by scripts in the repo and reported; singles records and tests are unchanged |

## Starting point (Nov 12, before the Phase 9 code)

| Area | Doubles today | Where |
| --- | --- | --- |
| Court lines, in/out, serve box | ✅ Done (wide sidelines, short long-service line) | `court/lines.py`, `referee/linecalls.py` |
| Court choice in live setup | ✅ Done | `live_controller.dart`, `match_setup_field.dart` |
| Court choice in upload | ❌ Hard-coded to `'singles'` in the app; `POST /jobs` has no `court` field, so uploads use `stages.referee.line_call.court` from config | `upload_screen.dart:184`, `api/models.py` (`JobCreate`) |
| Players per frame | ❌ At most 2, one `near`, one `far` | `pose/tracking.py` (`max_players=2`, `PlayerTracker`), `schema.Players` |
| Who hit | ❌ Side only (`near` / `far`) | `hits/detector.py`, `schema.Hit.player` |
| Server and service court | ⚠️ Correct per side; which partner serves is not tracked | `referee/match.py` |
| Stroke model | ⚠️ Trained on singles only; drives excluded | Phase 3, `docs/EVALUATION.md` |
| Feedback rules | ⚠️ Some are singles rules (serve) | `docs/FEEDBACK_RULES.md` |
| Stats, minimap, skeletons, timeline | ❌ Two players | `analytics/`, `render/`, `court_minimap.dart`, `app_theme.dart` |

## Key design decision (D22): record shape

`PlayerSide = "near" | "far"` stays as the **team** side. Scoring, rally winners, line calls and
the server side keep using it, so `referee/` barely changes.

Add a **player slot** for individuals:

```python
PlayerId = Literal["near_1", "near_2", "far_1", "far_2"]

class Players(BaseModel):
    near: Player | None = None     # = near_1, kept so singles records are unchanged
    far: Player | None = None      # = far_1
    near_2: Player | None = None   # doubles only
    far_2: Player | None = None

class Hit(BaseModel):
    player: PlayerSide                 # unchanged
    hitter: PlayerId | None = None     # doubles: which partner; None = not sure
    hitter_confidence: float | None = None
```

- Bump `SCHEMA_VERSION` to `1.2`. Migration from `1.1` adds nothing (new fields are optional).
- New fields are left out of the JSON when they are empty, so a singles `record.json`, its
  exports and live frame events keep their size and shape.
- A `slot_attr()` helper maps a `PlayerId` to its `Players` field (`near_1` → `near`,
  `near_2` → `near_2`) for code that reads a player by name.
- Slot numbers belong to a **person**, not a court half. Partners swap left and right during
  a rally, so `near_1` is "the player in the red shirt", not "the player on the left".
- Rejected: `players: {near: [p, p]}` lists. Cleaner, but it breaks every singles reader in
  the backend and the app for no gain in singles.

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T9.1](#t91) | Decision record and clip record v1.2 | M1 | 4 h | — | ✅ | [#113](https://github.com/Mist10148/ShuttleSense/issues/113) |
| [T9.2](#t92) | Record and label doubles clips | M4 | 12 h | — | ⬜ | [#114](https://github.com/Mist10148/ShuttleSense/issues/114) |
| [T9.3](#t93) | Four-player filter and per-side tracker | M2 | 16 h | T9.1 | ✅ | [#115](https://github.com/Mist10148/ShuttleSense/issues/115) |
| [T9.4](#t94) | Appearance cue for partner identity | M2 | 10 h | T9.3 | ⬜ | [#116](https://github.com/Mist10148/ShuttleSense/issues/116) |
| [T9.5](#t95) | Hitter attribution within a side | M5 | 8 h | T9.3 | ⬜ | [#117](https://github.com/Mist10148/ShuttleSense/issues/117) |
| [T9.6](#t96) | Doubles service order and receiver | M3 + M1 | 8 h | T9.1 | ✅ | [#118](https://github.com/Mist10148/ShuttleSense/issues/118) |
| [T9.7](#t97) | Strokes in doubles: drive class and confidence | M5 | 16 h | T9.2 | ⬜ | [#119](https://github.com/Mist10148/ShuttleSense/issues/119) |
| [T9.8](#t98) | Doubles feedback rules and per-player analytics | M3 | 8 h | T9.5 | ✅ | [#120](https://github.com/Mist10148/ShuttleSense/issues/120) |
| [T9.9](#t99) | Live mode with four players | M1 + M2 | 10 h | T9.3, T9.5 | ⬜ | [#121](https://github.com/Mist10148/ShuttleSense/issues/121) |
| [T9.10](#t910) | Court choice in upload (app and API), doubles match setup | M6 + M1 | 7 h | T9.6 | ✅ | [#122](https://github.com/Mist10148/ShuttleSense/issues/122) |
| [T9.11](#t911) | App: four players in overlays, minimap, stats | M6 + M4 | 12 h | T9.1, T9.8 | ✅ | [#123](https://github.com/Mist10148/ShuttleSense/issues/123) |
| [T9.12](#t912) | Doubles evaluation scripts and report | M4 | 10 h | T9.2–T9.6 | ⬜ | [#124](https://github.com/Mist10148/ShuttleSense/issues/124) |
| [T9.13](#t913) | Docs: PRD, README, API, data format | M1 | 4 h | T9.12 | ⬜ | [#125](https://github.com/Mist10148/ShuttleSense/issues/125) |

**Critical path:** T9.1 → T9.3 → T9.4 → T9.5 → T9.12. T9.2 (data) starts on day 1 because
everything measurable waits on it. T9.6 and T9.10 can run in parallel with tracking.

---

<a id="t91"></a>
### T9.1 · Decision record and clip record v1.2

**Owner:** M1 · **Area:** backend, docs

**Steps**
- [x] Write the record-shape decision above into `docs/DECISIONS.md` (D22).
- [x] `schema.py`: `PlayerId`, `Players.near_2/far_2`, `Hit.hitter`, `Hit.hitter_confidence`,
      `CourtPositions.near_2/far_2`; `Summary.per_player` also accepts `PlayerId` keys.
- [x] `Score`: add `first_server_id`, `first_receiver_id`, `server_id` and `receiver_id` (`PlayerId | None`);
      `Rally`: `server_id`, `receiver_id` and a `review` flag for the pose cross-check (T9.6).
- [x] New fields are left out of the JSON when empty; `slot_attr()` helper.
- [x] Migration `1.1 → 1.2`; regenerate `clip_record.schema.json` and `openapi.json`;
      `Health.expectedSchema` in the app.
- [x] Dart models in `app/lib/data/models/clip_record.dart` read the new fields, defaulting to null.

**Tests.** `golden_record.json` (singles, not regenerated) still validates and serializes with
no new keys; a new `golden_record_doubles.json` with 4 players and attributed hits, built by
`make_golden_record.py`, validates in backend and app.

**Acceptance criteria.** Every existing backend and app test passes; the only expected edits
are the version string (`"1.1"` → `"1.2"`) and the regenerated snapshots.

---

<a id="t92"></a>
### T9.2 · Record and label doubles clips

**Owner:** M4 · **Area:** data

**Steps**
- [ ] Record 8–10 consented doubles rallies (setup as in T0.10: elevated, behind the baseline),
      including at least 2 with partners crossing and 2 with front/back rotations.
- [ ] Look for a public, licensed doubles stroke dataset. If none is usable, label our own.
- [x] Extend `scripts/label_clip.py`: per hit, the hitter slot (`near_1` … `far_2`); per rally,
      the server and receiver slots. Every 10th frame, the four player boxes with slot IDs.

**Acceptance criteria.** Labels for ≥ 300 hits and ≥ 40 rallies, stored as in `docs/DATA_FORMAT.md`.

**Risks.** This is the slowest task and blocks evaluation. Start on day 1.

---

<a id="t93"></a>
### T9.3 · Four-player filter and per-side tracker

**Owner:** M2 · **Area:** backend · **Files:** `pose/tracking.py`, `pose/estimator.py`

**Steps**
- [x] `filter_players(max_players=4)` when `court == "doubles"`; keep at most 2 per side, using
      feet projected through the homography (the net line `y = 6.70 m` splits the sides).
- [x] `PlayerTracker` generalised to slots: match detections to the 2 tracks on each side by
      court-plane foot distance. With 2 tracks and ≤ 2 detections per side, try both
      assignments and keep the cheaper one (no SciPy needed).
- [x] Keep the existing hold-and-decay logic per slot so a briefly hidden partner keeps their box.
- [x] Never move a track across the net during a rally.
- [x] `court: singles` takes the old code path unchanged.

**Tests.** `test_pose.py`: four synthetic players with partners crossing paths keep their
slots; a partner hidden for 4 frames keeps their slot; a spectator outside the margin is dropped.

**Risks.** From behind the near baseline the far partners often overlap. Position alone will
swap them when they cross, which is why T9.4 exists.

---

<a id="t94"></a>
### T9.4 · Appearance cue for partner identity

**Owner:** M2 · **Area:** backend

**Steps**
- [x] Per track, keep a running colour histogram of the torso (shoulder-to-hip box from keypoints).
- [x] Assignment cost = court distance + weighted histogram distance; weight set in `pipeline.yaml`.
- [x] After an occlusion (both partners within 0.6 m), re-decide identity by appearance only.

**Tests.** Synthetic crossing where position alone would swap and colour keeps the IDs.

**Acceptance criteria.** On T9.2 clips, ID switches per rally are reported by T9.12.

**Risks.** Teammates in matching kit. Fallback: the user taps each player once at setup
(stored like calibration), and the app labels partners "left/right at serve" instead.

---

<a id="t95"></a>
### T9.5 · Hitter attribution within a side

**Owner:** M5 · **Area:** backend · **Files:** `hits/detector.py`

**Steps**
- [x] Keep side detection as it is (sides still alternate in doubles).
- [x] For each hit, compare the shuttle with both partners' racket-side wrists in a ±3 frame
      window; `hitter` is the closer one, `hitter_confidence` comes from the distance gap.
- [x] If both wrists are within `ambiguous_px` of the shuttle, set `hitter = None`.

**Tests.** Synthetic hits near one partner, near both, and with one partner missing.

**Acceptance criteria.** Hitter accuracy on T9.2 labels reported by T9.12; uncertain hits are
shown as "near team" in the app, not given to a player.

---

<a id="t96"></a>
### T9.6 · Doubles service order and receiver

**Owner:** M3 + M1 · **Area:** backend · **Files:** `referee/match.py`

Rules (BWF, rally scoring): the serving side serves from the right court on an even score and
the left on an odd one. If the serving side wins the rally, the **same server** serves again
from the other court (partners swap courts). If the receiving side wins, they gain the serve
and **neither of their players changes court**; whoever stands in the correct court for their
score serves.

**Steps**
- [x] Match setup takes the first server and first receiver slots (one camera cannot tell).
- [x] From the rally winners, derive each rally's `server_id`, `receiver_id`, and each
      player's service court; fill `Score.server_id` / `receiver_id`.
- [x] Cross-check against pose: if the derived server's feet are not in the expected service
      court at the serve, flag the rally for the user to check instead of changing it.
- [x] Referee corrections and undo re-derive the order (same path as score corrections).

**Tests.** A table-driven test that walks a whole game against a hand-worked sequence,
including game change and the 11-point interval.

---

<a id="t97"></a>
### T9.7 · Strokes in doubles: drive class and confidence

**Owner:** M5 · **Area:** ml

**Steps**
- [ ] Measure the singles classifier on T9.2 doubles hits as it is (baseline).
- [ ] Add a `drive` class. ShuttleSet has drive types that were left out in Phase 3, so they
      can come back for doubles.
- [ ] Fine-tune on the doubles labels, split by rally so no rally is in both train and test.
- [x] Below a confidence threshold, show "stroke unsure" instead of a label. (The app already marks strokes under 50% with "?"; in doubles, form tips are skipped below `feedback.min_stroke_confidence_doubles`.)

**Acceptance criteria.** Macro accuracy before and after fine-tuning reported. Singles accuracy
does not drop (or the doubles model is a separate checkpoint chosen by `court`).

**Risks.** 300 hits is little. If fine-tuning does not help, ship the singles model with the
confidence gate and say so in Limitations.

---

<a id="t98"></a>
### T9.8 · Doubles feedback rules and per-player analytics

**Owner:** M3 · **Area:** backend · **Files:** `feedback/`, `analytics/`, `docs/FEEDBACK_RULES.md`

**Steps**
- [x] Tag each rule `singles`, `doubles` or `both`; skip rules that do not apply. (Every rule applies to both courts, so no tag was needed; the serve tip no longer says "singles".)
- [x] Per-player summaries (hits, strokes, speeds, coverage heatmap) keyed by `PlayerId`.
- [x] Doubles-only insight: formation per rally phase (attack = front/back, defence =
      side-by-side) from the two court positions.

**Tests.** A doubles record gets 4 player summaries; singles summaries are unchanged.

---

<a id="t99"></a>
### T9.9 · Live mode with four players

**Owner:** M1 + M2 · **Area:** backend · **Files:** `stream/perception.py`, live socket

**Steps**
- [x] Use the T9.3 tracker in live perception; send 4 players in frame messages.
- [ ] Measure overlay latency with 4 poses (top-down pose cost grows per person); if it misses
      the 300 ms target, run pose on every other frame for the far side first.
- [x] Live snapshot and resume carry `server_id`, `receiver_id` and slot assignments.

**Tests.** Fake live source with a doubles clip in CI.

---

<a id="t910"></a>
### T9.10 · Court choice in upload (app and API), doubles match setup

**Owner:** M6 + M1 · **Area:** app, backend

**Steps**
- [x] Backend: `JobCreate.court` (`api/models.py`) → `Job` → `jobs.job_config` puts it in
      `config["court"]`; the stage cache key includes it only for doubles, so singles keys stay
      the same; line calls, pose and hits read it before the config default.
- [x] Upload: pass the chosen court through instead of the hard-coded `'singles'`
      (`upload_screen.dart:184`), and send it in `POST /jobs`.
- [x] When Doubles is picked: ask for first server and first receiver (by tapping two players
      on the calibration frame, or by name), and optional names for all four.
- [x] Update text that says "singles" (upload hint, settings About) once doubles ships.

**Tests.** Widget tests: upload sends `court: doubles`; doubles setup sends server and receiver.

---

<a id="t911"></a>
### T9.11 · App: four players in overlays, minimap, stats

**Owner:** M6 + M4 · **Area:** app

**Steps**
- [x] `app_theme.dart`: four player colours, partners as two shades of one team colour.
- [x] Skeletons, minimap dots, timeline hit markers and stats screens show 4 players.
- [x] Minimap draws the doubles side alleys and long service lines (it draws only singles lines today).
- [x] Uncertain hitter shows as the team colour with no player name.
- [x] Scoreboard shows the server and the service court for the serving player.

**Tests.** Golden tests with `golden_record_doubles.json`; singles goldens unchanged.

---

<a id="t912"></a>
### T9.12 · Doubles evaluation scripts and report

**Owner:** M4 · **Area:** data · **Files:** `scripts/eval_doubles.py`, `docs/EVALUATION.md`

**Metrics**
- ID switches per rally and IDF1 against the T9.2 box labels.
- Hitter attribution accuracy, with the rate of `hitter = None`.
- Service order: share of rallies where `server_id` and `receiver_id` match labels.
- Stroke macro accuracy (from T9.7) and line calls on doubles landings (existing script with `court: doubles`).

**Acceptance criteria.** Every number in the docs comes from this script on the committed labels.
No target is promised before the first measurement.

---

<a id="t913"></a>
### T9.13 · Docs: PRD, README, API, data format

**Owner:** M1 · **Area:** docs

**Steps**
- [ ] PRD: move doubles from out of scope to scope with the measured limits. (Moved in PRD v1.3; the measured limits wait for T9.12.)
- [x] README: replace "Singles only" in Limitations with the actual doubles limits; drop
      "Doubles support" from Future work.
- [x] `docs/API.md`, `docs/DATA_FORMAT.md`: schema 1.2 fields.
- [x] `PHASES.md`: add Phase 9 with its milestone and issues (#113–#125, Nov 13).

## Risks across the phase

| Risk | Effect | Fallback |
| --- | --- | --- |
| Partners overlap from one camera | ID swaps, wrong hitter | Appearance cue (T9.4), setup taps, `hitter = None` instead of guessing |
| Too little doubles data | Weak strokes, weak numbers | Confidence gate; report sample sizes next to every metric |
| Live latency with 4 poses | Overlays lag | Lower pose rate on the far side; reduced resolution (existing degrade path) |
| Schema change ripples into the app | Broken singles views | Optional fields only; singles goldens must stay byte-identical |
