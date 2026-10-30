# Phase 5 — P2 analysis

[← Phase 4](phase-4-app-mvp.md) · [Phase overview](../PHASES.md) · Next: [Phase 6 — P3 referee →](phase-6-referee.md)

| | |
| --- | --- |
| **Dates** | Mon Nov 9 – Tue Nov 17, 2026 |
| **Goal** | Court-aware analytics: calibration, court outline, minimap, estimated speed, stroke counter, form feedback and exports, visible in both the video and the app |
| **Owners** | M2 (court, positions, speed, exports), M6 (minimap, tips, re-render UI), M3 (feedback rules), M4 (downloads, chart), M1 (calibration UI, re-render API) |
| **Entry criteria** | Phase 2 exit gate; hits (T3.6) and strokes (T3.10) available or stubbed with the golden record |
| **Exit gate** | With 4 tapped corners, a job produces court outline, minimap positions, speeds (labelled estimated), stroke counts, form tips, and downloadable JSON/CSV that match the app |
| **Milestone** | `Phase 5 — P2 analysis` (due Nov 17) |

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T5.1](#t51) | App calibration screen polish | M1 | 5 h | T4.3 | ⬜ | [#62](https://github.com/Mist10148/ShuttleSense/issues/62) |
| [T5.2](#t52) | Court homography stage and validation | M2 | 3 h | T1.1 | ✅ | [#63](https://github.com/Mist10148/ShuttleSense/issues/63) |
| [T5.3](#t53) | Court outline overlay | M2 | 3 h | T5.2, T2.6 | ⬜ | [#64](https://github.com/Mist10148/ShuttleSense/issues/64) |
| [T5.4](#t54) | Court-plane positions for players and shuttle | M2 | 6 h | T5.2, T2.5 | ⬜ | [#65](https://github.com/Mist10148/ShuttleSense/issues/65) |
| [T5.5](#t55) | App minimap synced to playback | M6 | 4 h | T5.4, T4.6 | ⬜ | [#66](https://github.com/Mist10148/ShuttleSense/issues/66) |
| [T5.6](#t56) | Estimated shuttle speed | M2 | 5 h | T5.4, T3.10 | ⬜ | [#67](https://github.com/Mist10148/ShuttleSense/issues/67) |
| [T5.7](#t57) | Stroke counter and status bar | M2 + M6 | 4 h | T3.6 | ⬜ | [#68](https://github.com/Mist10148/ShuttleSense/issues/68) |
| [T5.8](#t58) | Form feedback rules | M3 | 8 h | T2.5, T3.10 | ⬜ | [#69](https://github.com/Mist10148/ShuttleSense/issues/69) |
| [T5.9](#t59) | Form tips in the app | M6 | 2 h | T5.8, T4.7 | ⬜ | [#70](https://github.com/Mist10148/ShuttleSense/issues/70) |
| [T5.10](#t510) | Summary, JSON and CSV exports | M2 | 3 h | T5.6 | ⬜ | [#71](https://github.com/Mist10148/ShuttleSense/issues/71) |
| [T5.11](#t511) | App downloads and sharing, summary chart | M4 | 5 h | T5.10 | ⬜ | [#72](https://github.com/Mist10148/ShuttleSense/issues/72) |
| [T5.12](#t512) | Re-render with different overlays | M1 + M6 | 5 h | T2.8 | ⬜ | [#73](https://github.com/Mist10148/ShuttleSense/issues/73) |
| [T5.13](#t513) | Speed sanity evaluation | M2 | 3 h | T5.6 | ⬜ | [#74](https://github.com/Mist10148/ShuttleSense/issues/74) |
| [T5.14](#t514) | Minimap overlay in the rendered video | M2 | 3 h | T5.4, T2.6 | ⬜ | [#75](https://github.com/Mist10148/ShuttleSense/issues/75) |

---

<a id="t51"></a>
### T5.1 · App calibration screen polish

**Owner:** M1 · **Estimate:** 5 h · **Priority:** P2 · **Area:** app · **Refs:** F9, FR-9 · **Depends on:** T4.3 · **Blocks:** T5.2 end-to-end

**Inputs.** `features/calibration/calibration_screen.dart` (tap 4 corners, `InteractiveViewer`, `_CornersPainter`).

**Steps**
- [ ] Draggable corner handles after placement (hit-test within 24 dp, update the point on drag).
- [ ] A magnifier loupe while dragging on touch devices (`RawMagnifier`), so corners land precisely.
- [ ] Show a small diagram of which corner is next (near-left, near-right, far-right, far-left).
- [ ] Client-side check that the 4 points form a convex quadrilateral (mirror `court.validate_corners`) before enabling "Start processing".
- [ ] Optional frame scrubber to pick a clearer frame than frame 0 (`GET /videos/{id}/frames/{n}`).
- [ ] Add a `--calibrate` window to the CLI (`run.py`): OpenCV window on frame 0, click 4 corners.

**Tests.** `test/calibration_test.dart`: 4 taps enable the button; crossing order shows an error; drag moves a corner. Pure function `isConvex(points)` unit-tested.

**Acceptance criteria.** Corners placed within ~5 px of the true corners on a phone at 2× zoom.

---

<a id="t52"></a>
### T5.2 · Court homography stage and validation

**Owner:** M2 · **Estimate:** 3 h · **Priority:** P2 · **Area:** backend · **Refs:** F9, FR-9 · **Depends on:** T1.1 · **Blocks:** T5.3, T5.4, T6.2

**Inputs.** Existing `court/homography.py` (`compute_homography`, `validate_corners`, `image_to_court`, `run`).

**Steps**
- [x] Add `court_to_image(h, points_m)` (inverse homography) for drawing.
- [x] Sanity check after computing H: the projected court area should cover 10–95% of the frame; otherwise raise `ValueError("corners look wrong")` → 400 from `POST /jobs`.
- [x] Scale corners if the job was created on a downscaled frame (corners are always in normalized video px — verify against `X-Frame-Width`).
- [x] Store `court_size_m` from config so doubles courts could be added later.

**Tests.** Existing `tests/test_court.py`; add `test_court_to_image_inverts_image_to_court`, `test_tiny_court_rejected`.

**Acceptance criteria.** Round-trip error < 0.5 px on synthetic courts.

---

<a id="t53"></a>
### T5.3 · Court outline overlay

**Owner:** M2 · **Estimate:** 3 h · **Priority:** P2 · **Area:** backend · **Refs:** F9 · **Depends on:** T5.2, T2.6 · **Blocks:** —

**Steps**
- [ ] `court` layer: project all singles court lines (baselines, sidelines, net, short service lines, centre line) from court meters to image with `court_to_image`; draw semi-transparent highlighted lines.
- [ ] Line definitions in `court/lines.py` (meters), shared with the app minimap constants.

**Tests.** `test_render.py::test_court_lines_hit_corners` (projected corner pixels equal the input corners).

**Acceptance criteria.** Outline aligns with real lines within a few pixels on both team clips.

---

<a id="t54"></a>
### T5.4 · Court-plane positions for players and shuttle

**Owner:** M2 · **Estimate:** 6 h · **Priority:** P2 · **Area:** backend · **Refs:** F10, FR-10 · **Depends on:** T5.2, T2.5 · **Blocks:** T5.5, T5.6, T5.14, T6.2

**Steps**
- [ ] In `analytics/stage.py`: player position = midpoint of ankles (keypoints 15, 16) if both have score ≥ 0.3, else bbox bottom-centre; project with `image_to_court`.
- [ ] Shuttle ground position: the shuttle is in the air, so a pixel→plane projection is only valid near the floor. Use it for the minimap only when below a height proxy: (a) within ±3 frames of a landing (P3), or (b) approximate with the projection and clamp to the court ± 1 m. Document the approximation.
- [ ] Clip positions to the court ± 2 m; set `null` when the player is missing.
- [ ] Light smoothing (moving average 5 frames) on positions.
- [ ] Fill `frames[i].court_positions`.

**Tests.** `tests/test_analytics.py::test_player_position_uses_ankles`, `::test_falls_back_to_bbox_bottom`, `::test_positions_null_without_court`.

**Acceptance criteria.** On review, minimap positions match the visible court zones (service box, mid-court, back-court) on both team clips.

---

<a id="t55"></a>
### T5.5 · App minimap synced to playback

**Owner:** M6 · **Estimate:** 4 h · **Priority:** P2 · **Area:** app · **Refs:** F10 · **Depends on:** T5.4, T4.6 · **Blocks:** —

**Inputs.** `features/results/widgets/court_minimap.dart` (`CourtMinimap`, `CourtPainter`).

**Steps**
- [ ] Short fading trail of the last 15 shuttle positions.
- [ ] Draw the hitter's position at each hit as a small marker for the current rally.
- [ ] Optional heatmap toggle (player positions over the whole clip).
- [ ] Repaint efficiently: only when the frame index changes (`shouldRepaint` compares frame numbers).

**Tests.** In `test/scoreboard_test.dart`: painter `shouldRepaint` logic; widget renders with a golden record frame.

**Acceptance criteria.** Dots move smoothly with the video on phone and laptop.

---

<a id="t56"></a>
### T5.6 · Estimated shuttle speed

**Owner:** M2 · **Estimate:** 5 h · **Priority:** P2 · **Area:** backend · **Refs:** F11, FR-11 · **Depends on:** T5.4, T3.10 · **Blocks:** T5.10, T5.13

**Inputs.** `analytics/speed.py::speeds_kmh`.

**Steps**
- [ ] Extend `speeds_kmh` to handle NaN/invisible frames (no speed across gaps > 2 frames).
- [ ] Compute per-frame speed for frames where the shuttle position is valid; fill `frames[i].shuttle_speed_kmh`.
- [ ] Per-hit speed: max smoothed speed in the 5 frames after each hit → `hits[].speed_kmh`.
- [ ] Clip implausible values (> 450 km/h) to null and log.
- [ ] Every display (video, app, exports) labels speed as "estimated".

**Tests.** Existing `test_speed_constant_motion`; add `test_speed_constant_motion_and_none_across_gaps`, `test_hit_speed_is_post_hit_peak`, `test_glitch_frame_does_not_leak_into_neighbours`.

**Acceptance criteria.** On test clips, median smash speed > median drop speed; values in a plausible range (drops 30–90, smashes 100–300 km/h in 2D approximation).

---

<a id="t57"></a>
### T5.7 · Stroke counter and status bar

**Owner:** M2 + M6 · **Estimate:** 4 h · **Priority:** P2 · **Area:** backend · **Refs:** F12, FR-12 · **Depends on:** T3.6 · **Blocks:** T6.5

**Steps**
- [ ] Backend: per-rally stroke count (until P3 rally detection exists, treat the whole clip as one rally); `Rally.stroke_count`.
- [ ] Backend `speed` layer renders a status bar: rally state (if available), current/peak speed "(est.)", stroke count.
- [ ] App: `StatusStrip` already shows these; make the count per rally once `rallies` exist.

**Tests.** `test_analytics.py::test_stroke_count_per_rally`.

**Acceptance criteria.** Count matches a manual count on test rallies (error ≤ 1).

---

<a id="t58"></a>
### T5.8 · Form feedback rules

**Owner:** M3 · **Estimate:** 8 h · **Priority:** P2 · **Area:** backend · **Refs:** F8, FR-8 · **Depends on:** T2.5, T3.10 · **Blocks:** T5.9

**Inputs.** `feedback/rules.py::joint_angle`.

**Steps**
- [ ] Write `docs/FEEDBACK_RULES.md`: for each class, ≥ 2 rules with the measured quantity, threshold, tip text and source (coaching references).
  - smash: contact point above head (wrist y < nose y); elbow angle at contact ≥ 150°.
  - clear: contact above head; full arm extension (shoulder–elbow–wrist ≥ 150°).
  - drop: contact above shoulder; follow-through shorter than smash (wrist travel in next 5 frames).
  - net shot: knee bend on lunge (hip–knee–ankle ≤ 140°); racket arm forward of body.
  - lift: lunge knee bend; wrist below shoulder at contact.
  - serve: contact below waist (singles low serve rule); stable feet before contact.
- [ ] Implement each as `Rule(name, classes, check(keypoints_window) -> (passed, value), tip)` in `feedback/rules.py`; thresholds in `configs/pipeline.yaml stages.feedback`.
- [ ] `run`: for each hit with a stroke, evaluate rules for that class on the hitter's keypoints at the hit frame (±2 frames), fill `hits[].feedback`.
- [ ] Skip rules whose joints have low scores (no tip rather than a wrong tip).
- [ ] Tips are short (≤ 70 chars) and framed as heuristic guidance (Ethics).

**Tests.** `tests/test_feedback.py`: one passing and one failing synthetic pose per rule; low-score joints skip.

**Acceptance criteria.** Each class has ≥ 2 documented and tested rules; tips appear for test clips.

---

<a id="t59"></a>
### T5.9 · Form tips in the app

**Owner:** M6 · **Estimate:** 2 h · **Priority:** P2 · **Area:** app · **Refs:** F8 · **Depends on:** T5.8, T4.7 · **Blocks:** —

**Steps**
- [ ] Parse the full `feedback` list in `Hit` (currently only the first tip is kept) as `List<FeedbackItem>`.
- [ ] Timeline row shows the first failed tip; detail sheet lists all rules with ✓/✗.
- [ ] Disclaimer line in the detail sheet: "Heuristic guidance, not professional coaching."

**Tests.** `models_test.dart` parses all feedback items; `timeline_test.dart` shows the tip.

**Acceptance criteria.** Tips visible on all three layouts.

---

<a id="t510"></a>
### T5.10 · Summary, JSON and CSV exports

**Owner:** M2 · **Estimate:** 3 h · **Priority:** P2 · **Area:** backend · **Refs:** F13, FR-13 · **Depends on:** T5.6 · **Blocks:** T5.11

**Inputs.** `analytics/export.py` (`build_summary`, `write_exports`, `HITS_CSV_COLUMNS`).

**Steps**
- [ ] Add per-rally stats to `summary.json` (stroke count, duration, peak speed).
- [ ] Add a `rallies.csv` export and `GET /jobs/{id}/rallies.csv` (API change → update API.md + `ApiClient`).
- [ ] Use UTF-8 with BOM for CSVs so Excel opens them correctly on Windows.

**Tests.** Existing `test_summary_and_exports`; add `test_csv_opens_with_bom`, `test_summary_matches_record`.

**Acceptance criteria.** Files open in Excel/Google Sheets and values match the app.

---

<a id="t511"></a>
### T5.11 · App downloads and sharing, summary chart

**Owner:** M4 · **Estimate:** 5 h · **Priority:** P2 · **Area:** app · **Refs:** C4, FR-C4 · **Depends on:** T5.10 · **Blocks:** —

**Steps**
- [ ] Mobile: download to temp (`path_provider`) with dio progress, then `share_plus` share sheet.
- [ ] Windows: save dialog (`FilePicker.saveFile`), write file.
- [ ] Web: open the token URL (`launchUrl`) so the browser downloads it (already in results app bar).
- [ ] Stroke distribution bar chart and per-player comparison with `fl_chart` in the summary card.

**Tests.** `test/downloads_test.dart` with a fake downloader; chart renders with the golden record.

**Acceptance criteria.** MP4, JSON and CSV save/open on Android, Windows and Chrome.

---

<a id="t512"></a>
### T5.12 · Re-render with different overlays

**Owner:** M1 + M6 · **Estimate:** 5 h · **Priority:** P2 · **Area:** backend · **Refs:** F7 · **Depends on:** T2.8 · **Blocks:** —

**Steps**
- [ ] Backend: implement `POST /jobs/{id}/render` (done): set job `running`, run only the `render` stage using cached stage outputs (T2.8) and the new overlay list; update `job.overlays`.
- [ ] App: "Overlays" button on results opens the chip sheet; on apply, call render, show progress, reload the player.

**Tests.** `test_api.py::test_rerender_only_runs_render_stage` (fake pipeline counting stage calls).

**Acceptance criteria.** Re-render of a 1-minute clip finishes in < 1 minute on the laptop GPU.

---

<a id="t513"></a>
### T5.13 · Speed sanity evaluation

**Owner:** M2 · **Estimate:** 3 h · **Priority:** P2 · **Area:** ml · **Refs:** F11 · **Depends on:** T5.6 · **Blocks:** T7.3

**Steps**
- [ ] On team clips with calibration, list per-hit speeds by stroke class; box plot in `docs/results/speed.md`.
- [ ] Compare with typical published amateur ranges and explain the 2D underestimate (Limitations).

**Acceptance criteria.** Report merged; smashes rank above drops.

---

<a id="t514"></a>
### T5.14 · Minimap overlay in the rendered video

**Owner:** M2 · **Estimate:** 3 h · **Priority:** P2 · **Area:** backend · **Refs:** F10 · **Depends on:** T5.4, T2.6 · **Blocks:** —

**Steps**
- [ ] `minimap` layer: a top-down court (same geometry as `court/lines.py`) in a corner of the frame with player and shuttle dots, matching the app's colours.
- [ ] Position configurable (`stages.render.minimap_corner`), size 20% of frame height.

**Tests.** `test_render.py::test_minimap_layer_draws_in_corner`.

**Acceptance criteria.** Minimap visible in the annotated MP4 and consistent with the app.

---

## Phase gate checklist (Nov 17)

1. Upload a team clip, calibrate on a phone, process.
2. Show court outline, minimap, speed and stroke count in the video and in the app.
3. Show form tips for at least 3 stroke classes.
4. Download JSON and CSV and open them in a spreadsheet.
