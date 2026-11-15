# Phase 3 — Dataset and stroke classifier

[← Phase 2](phase-2-perception.md) · [Phase overview](../PHASES.md) · Next: [Phase 4 — App MVP →](phase-4-app-mvp.md)

| | |
| --- | --- |
| **Dates** | Tue Nov 3 – Fri Nov 13, 2026 |
| **Goal** | Detect every hit and classify it into 6 stroke classes with a 1D CNN trained from scratch on ShuttleSet, with a pose-only ablation (since Phase 11 also an LSTM and a Random Forest, [D28](../DECISIONS.md)) |
| **Owners** | M3 + M4 (data pipeline, evaluation support), M5 (hits, classifier), M2 (render labels) |
| **Entry criteria** | T1.9 annotations downloaded; T2.2 and T2.5 produce shuttle + pose |
| **Exit gate** | Hit F1 ≥ 0.75 (±3 frames) and stroke macro accuracy ≥ 70% on held-out ShuttleSet matches, or documented gaps; ablation numbers recorded; strokes appear in `record.json`, the video and the app |
| **Milestone** | `Phase 3 — Dataset and classifier` (due Nov 13) |

**Week 1 checkpoint (Fri Nov 6):** baseline classifier trained on ≥ 5 matches (T3.8).

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T3.1](#t31) | Clip extraction, matches 1–22 | M3 | 10 h | T1.9 | ⬜ | [#35](https://github.com/Mist10148/ShuttleSense/issues/35) |
| [T3.2](#t32) | Clip extraction, matches 23–44 | M4 | 10 h | T1.9 | ⬜ | [#36](https://github.com/Mist10148/ShuttleSense/issues/36) |
| [T3.3](#t33) | Final 18 → 6 label mapping | M4 | 3 h | T1.9 | ⬜ | [#37](https://github.com/Mist10148/ShuttleSense/issues/37) |
| [T3.4](#t34) | Match-level train/val/test split | M4 | 2 h | T3.3 | ✅ | [#38](https://github.com/Mist10148/ShuttleSense/issues/38) |
| [T3.5](#t35) | Feature extraction to `.npz` windows | M5 | 10 h | T2.2, T2.5, T3.1, T3.2 | ⬜ | [#39](https://github.com/Mist10148/ShuttleSense/issues/39) |
| [T3.6](#t36) | Rule-based hit detector stage | M5 | 8 h | T2.3, T2.5 | ⬜ | [#40](https://github.com/Mist10148/ShuttleSense/issues/40) |
| [T3.7](#t37) | Hit detection evaluation and tuning | M3 | 5 h | T3.6, T3.4 | ⬜ | [#41](https://github.com/Mist10148/ShuttleSense/issues/41) |
| [T3.8](#t38) | 1D CNN model, data loader, training script | M5 | 10 h | T3.5 | ⬜ | [#42](https://github.com/Mist10148/ShuttleSense/issues/42) |
| [T3.9](#t39) | Full training + pose-only ablation | M5 | 8 h | T3.8 | ⬜ | [#43](https://github.com/Mist10148/ShuttleSense/issues/43) |
| [T3.10](#t310) | Stroke inference stage | M5 | 5 h | T3.9, T2.8 | ⬜ | [#44](https://github.com/Mist10148/ShuttleSense/issues/44) |
| [T3.11](#t311) | Hit marker and stroke label overlays | M2 | 4 h | T3.10, T2.6 | ⬜ | [#45](https://github.com/Mist10148/ShuttleSense/issues/45) |
| [T3.12](#t312) | Confusion matrix and results figures | M4 | 4 h | T3.9 | ✅ | [#46](https://github.com/Mist10148/ShuttleSense/issues/46) |
| [T3.13](#t313) | Dataset statistics and class balance report | M4 | 3 h | T3.3, T3.4 | ⬜ | [#47](https://github.com/Mist10148/ShuttleSense/issues/47) |
| [T3.14](#t314) | Classifier inference latency and fallback | M3 | 2 h | T3.10 | ⬜ | [#48](https://github.com/Mist10148/ShuttleSense/issues/48) |

---

<a id="t31"></a>
### T3.1 · Clip extraction, matches 1–22

**Owner:** M3 · **Estimate:** 10 h · **Priority:** P1 · **Area:** data · **Refs:** F6, Data · **Depends on:** T1.9 · **Blocks:** T3.5

**Goal.** One short clip per annotated stroke for the first half of ShuttleSet.

**Inputs.** `data/shuttleset/` annotations (per-rally CSVs with frame/time of each stroke and its type), match videos in Drive `videos/`.

**Steps**
- [x] Implement `backend/scripts/extract_clips.py` (stub exists): for each match in `--matches`, for each annotated stroke, cut `[hit_frame - pad, hit_frame + pad]` (`--pad-frames 16` default, so 33 frames) from the match video with OpenCV, resized to 720p.
- [x] Name clips `data/clips/<match_id>/<set>_<rally>_<stroke>.mp4` and write `data/clips/<match_id>/index.csv` with `clip, match_id, set, rally, stroke_no, hit_frame_in_clip, player (A/B), shuttleset_type, fps`.
- [x] Skip strokes whose window crosses a rally boundary or the video end; log the count.
- [x] Resume support: skip clips that already exist.
- [ ] Start with 5 matches (needed for the Week 1 baseline), then the rest.
- [ ] Upload to Drive `clips/`.

**Outputs.** Clips + `index.csv` for matches 1–22.

**Tests.** `tests/test_extract_clips.py::test_window_bounds` and `::test_skips_window_crossing_rally_end` (pure function `stroke_windows(annotations, pad, num_frames)`).

**Acceptance criteria.** ≥ 95% of annotated strokes in matches 1–22 have a clip; counts per match posted on the issue.

**Risks.** Video/annotation frame offsets: verify on 10 random clips that the racket contact is at the centre frame; if offset, add a per-match offset table.

---

<a id="t32"></a>
### T3.2 · Clip extraction, matches 23–44

**Owner:** M4 · **Estimate:** 10 h · **Priority:** P1 · **Area:** data · **Refs:** F6, Data · **Depends on:** T1.9 · **Blocks:** T3.5

Same steps, outputs, tests and acceptance criteria as [T3.1](#t31), for matches 23–44, using the same script (no fork). Coordinate with M3 on any script change through one PR.

---

<a id="t33"></a>
### T3.3 · Final 18 → 6 label mapping

**Owner:** M4 · **Estimate:** 3 h · **Priority:** P1 · **Area:** data · **Refs:** F6 · **Depends on:** T1.9 · **Blocks:** T3.4, T3.5, T3.13

**Steps**
- [x] Compare the stroke type names printed by T1.9 with `backend/shuttlesense/strokes/labels.py::SHUTTLESET_TO_CLASS`; fix spelling/translation differences (ShuttleSet labels may be Chinese with English translations). The CSVs are Chinese only: `SHUTTLESET_ZH_TO_EN` (D12).
- [ ] Decide drive-family strokes: keep excluded (default) or merge into `clear`/`lift` by height; record the reason in `docs/DECISIONS.md`.
- [ ] Decide `rush` (net kill) → `net_shot` or `smash`; `push` → `lift` or `net_shot`.
- [x] Update `SHUTTLESET_TO_CLASS` and the table in DATA_FORMAT.md in the same PR.
- [x] Output class counts after mapping. See `docs/results/dataset.md`.

**Tests.** `test_label_mapping_covers_18_types` (exists; update), `test_every_shuttleset_type_in_data_is_mapped` (reads a small sample annotations CSV fixture).

**Acceptance criteria.** Every type in the data maps to a class or is explicitly excluded; table in docs matches code.

---

<a id="t34"></a>
### T3.4 · Match-level train/val/test split

**Owner:** M4 · **Estimate:** 2 h · **Priority:** P1 · **Area:** data · **Refs:** F6, Success metrics · **Depends on:** T3.3 · **Blocks:** T3.7, T3.8

**Steps**
- [x] In `extract_features.py` (or a new `scripts/make_splits.py`), split the 44 matches ≈ 70/15/15 (31/6/7) with seed 42, stratified so each split has a similar class distribution (greedy assignment by class counts).
- [x] Write `data/splits.json` `{"train": [...], "val": [...], "test": [...], "seed": 42}`; commit a copy to `backend/configs/splits.json` (small, no data) so everyone uses the same split. Made from the annotations (`--from-annotations`, D13); proportions within 0.5 pp of the overall.

**Tests.** `tests/test_splits.py::test_no_match_in_two_splits`, `::test_split_is_deterministic`.

**Acceptance criteria.** Splits committed; class proportions per split within ±5 percentage points of the overall.

---

<a id="t35"></a>
### T3.5 · Feature extraction to `.npz` windows

**Owner:** M5 · **Estimate:** 10 h · **Priority:** P1 · **Area:** ml · **Refs:** F6 · **Depends on:** T2.2, T2.5, T3.1, T3.2 · **Blocks:** T3.8

**Goal.** Turn every clip into a fixed-size feature window the CNN can read.

**Steps**
- [x] Put the shared feature code in `backend/shuttlesense/strokes/features.py` so training and inference use the *same* function: `build_window(record_or_arrays, hit_frame, player, T, use_trajectory) -> np.ndarray[T, F]`.
- [x] Per frame: hitter's 17 keypoints (x, y) normalized to the hitter's bbox (centre-subtract, divide by bbox height) → 34 values; keypoint scores optional (+17).
- [x] Shuttle: (x, y) normalized to frame size, visible, dx, dy → 5 values. Missing frames → zeros + visible=0.
- [x] Hitter = the player whose wrist is closest to the shuttle at the hit frame ([D14](../DECISIONS.md)); ShuttleSet's A/B label is not used.
- [x] `extract_features.py`: run tracking + pose on each clip (batch on GPU), build windows (`--window`, 30 frames since Phase 11; `--pose-norm bbox_diag`), save `data/features/<match_id>.npz` with `X [N,T,F]`, `y [N]` (class index in `STROKE_CLASSES` order), `meta` (clip names).
- [ ] Run on Colab across team accounts if needed; upload `.npz` files to Drive `features/`.

**Tests.** `tests/test_features.py::test_window_shape`, `::test_pose_only_drops_shuttle_columns`, `::test_missing_frames_are_zero_with_visible_flag`, `::test_normalization_is_bbox_relative`.

**Acceptance criteria.** `.npz` for all 44 matches; N per match equals clip count minus excluded types.

---

<a id="t36"></a>
### T3.6 · Rule-based hit detector stage

**Owner:** M5 · **Estimate:** 8 h · **Priority:** P1 · **Area:** ml · **Refs:** F5, FR-5 · **Depends on:** T2.3, T2.5 · **Blocks:** T3.7, T3.10, T5.7, T6.1

**Steps**
- [x] In `hits/detector.py::run`: take visible shuttle positions; candidates = `direction_changes(xy, min_angle_deg)` (exists) plus vertical-velocity sign flips from going down to going up near a player.
- [x] For each candidate frame f, distance from shuttle to each player's wrists (keypoints 9, 10, score ≥ 0.3); accept if the minimum ≤ `max_wrist_distance_px` (scale by `height/720`). The hitter is the player with the closest wrist.
- [x] Suppress duplicates: keep one hit per `min_frames_between_hits`, choosing the closest-wrist candidate; consecutive hits must alternate players (singles), otherwise keep the better one.
- [x] Fill `record.hits = [Hit(id, frame, time_s=frame/fps, player)]`.
- [x] Expose `detect_hits(xy, visible, wrists_near, wrists_far, cfg) -> list[(frame, player)]` as a pure function for tests and evaluation.

**Tests** (`tests/test_hits.py`): `test_detects_hit_at_direction_change_near_wrist`, `test_ignores_direction_change_far_from_players`, `test_min_gap_suppresses_duplicates`, `test_hits_alternate_players`.

**Acceptance criteria.** All unit tests pass; hits appear on `rally01.mp4` at visibly correct moments.

---

<a id="t37"></a>
### T3.7 · Hit detection evaluation and tuning

**Owner:** M3 · **Estimate:** 5 h · **Priority:** P1 · **Area:** ml · **Refs:** F5, Success metrics (hit F1 ≥ 0.75) · **Depends on:** T3.6, T3.4 · **Blocks:** T7.3

**Steps**
- [x] `scripts/eval_hits.py`: run perception + `detect_hits` on full rallies of the **test** matches; match predictions to ShuttleSet stroke frames within ±3 frames (greedy one-to-one); report precision, recall, F1, and player-assignment accuracy.
- [ ] Grid-search `min_angle_deg`, `max_wrist_distance_px`, `min_frames_between_hits` on the **val** matches only; write the best values to `configs/pipeline.yaml`.
- [ ] Log every run to `docs/results/hits_tuning.csv`.

**Tests.** `tests/test_eval.py::test_hit_matching_within_tolerance`.

**Acceptance criteria.** Test-set F1 reported; ≥ 0.75 or a written analysis of the main failure types (missed serves, net shots, occlusion).

---

<a id="t38"></a>
### T3.8 · 1D CNN model, data loader, training script

**Owner:** M5 · **Estimate:** 10 h · **Priority:** P1 · **Area:** ml · **Refs:** F6, FR-6 · **Depends on:** T3.5 · **Blocks:** T3.9

**Steps**
- [x] `strokes/dataset.py`: `StrokeDataset(features_dir, match_ids, use_trajectory)` loading `.npz` into memory, returning `(X[F,T] float32, y)`; optional augmentation (small time shift ±2 frames, horizontal flip with left/right joint swap, Gaussian noise).
- [x] Use `strokes/model.py::build_model(in_features)` (exists); tune depth from config.
- [x] Implement `scripts/train_stroke_classifier.py` (stub exists): seeds (`random`, `numpy`, `torch`), AdamW, cross-entropy with inverse-frequency class weights, cosine LR, early stopping on val macro-F1, save best checkpoint with `{state_dict, in_features, classes, config}`.
- [x] Log per-epoch metrics to `outputs/stroke_cnn_metrics.json` and stdout.
- [x] **Week 1 baseline:** train on 5 matches, evaluate on 1, post the number on the issue. *Replaced on
      Nov 14 by the full runs on the BST features ([Phase 11](phase-11-stroke-models.md#t116)).*

**Tests.** `tests/test_strokes.py::test_model_forward_shape` (`@pytest.mark.skipif` no torch), `::test_dataset_reads_npz` (tiny synthetic npz), `::test_flip_swaps_left_right_joints`.

**Acceptance criteria.** Training runs end to end on Colab; baseline number posted by Nov 6.

---

<a id="t39"></a>
### T3.9 · Full training + pose-only ablation

**Owner:** M5 · **Estimate:** 8 h · **Priority:** P1 · **Area:** ml · **Refs:** F6, Success metrics (≥ 70% macro accuracy; ablation) · **Depends on:** T3.8 · **Blocks:** T3.10, T3.12, T7.3

**Steps**
- [x] Train the full model (pose + trajectory) on train, select on val, evaluate once on test; 3 seeds, report mean ± std. *Done on the BST features and split (D29): test macro accuracy 91.2% ± 0.6% (Nov 15, second evaluation after the import fix, D35; 89.5% ± 1.2% on Nov 14).*
- [x] Same with `--pose-only`: 77.5% ± 0.7%.
- [ ] The same two runs on our own clips and `configs/splits.json` (needs T3.1, T3.2 and T3.5).
- [x] Publish the best full checkpoint with its checksum in `download_weights.py`. *Committed under `backend/weights/strokes/` instead of Hugging Face ([D30](../DECISIONS.md)).*
- [x] Write `docs/results/strokes.md` with the results table and training settings.

**Acceptance criteria.** Test macro accuracy and per-class F1 for both variants recorded; best model ≥ 70% or analysis of confusions.

---

<a id="t310"></a>
### T3.10 · Stroke inference stage

**Owner:** M5 · **Estimate:** 5 h · **Priority:** P1 · **Area:** ml · **Refs:** F6, FR-6 · **Depends on:** T3.9, T2.8 · **Blocks:** T3.11, T4.7, T5.6, T5.8

**Steps**
- [x] In `strokes/classify.py::run`: load the checkpoint once (cache per device), build windows with `features.build_window` for each `record.hits` entry, batch inference, softmax.
- [x] Fill `stroke` (argmax), `confidence`, `class_probs`.
- [x] If the checkpoint is missing, raise `StageSkipped("stroke model not installed")` so the job still finishes.

**Tests.** `test_strokes.py::test_classify_fills_fields_with_dummy_model` (monkeypatch the loader with a model returning fixed logits).

**Acceptance criteria.** Strokes appear in `record.json` and the app timeline for `rally01.mp4`.

---

<a id="t311"></a>
### T3.11 · Hit marker and stroke label overlays

**Owner:** M2 · **Estimate:** 4 h · **Priority:** P1 · **Area:** backend · **Refs:** F5, F6 · **Depends on:** T3.10, T2.6 · **Blocks:** —

**Steps**
- [x] Add `hits` layer: "HIT" badge near the hitter's wrist for `marker_duration_s` after each hit, with a short expanding ring.
- [x] Add `strokes` layer: label "Smash 81%" above the hitter's box until the next hit.
- [x] Respect the player colours from `render/style.py`.

**Tests.** `test_render.py::test_hit_marker_visible_only_within_duration`.

**Acceptance criteria.** Markers and labels visible and correctly timed on review.

---

<a id="t312"></a>
### T3.12 · Confusion matrix and results figures

**Owner:** M4 · **Estimate:** 4 h · **Priority:** P2 · **Area:** ml · **Refs:** Metrics · **Depends on:** T3.9 · **Blocks:** T7.9

**Steps**
- [x] Notebook `backend/notebooks/stroke_results.ipynb` (outputs cleared before commit): normalized confusion matrix, per-class F1 bars, ablation comparison, examples of the most confused pairs. Done as `scripts/make_figures.py` instead of a notebook, so the figures regenerate from the metrics files.
- [x] Export PNGs to `docs/results/` (small files only).

**Acceptance criteria.** Figures committed and referenced from `docs/results/strokes.md`.

---

<a id="t313"></a>
### T3.13 · Dataset statistics and class balance report

**Owner:** M4 · **Estimate:** 3 h · **Priority:** P2 · **Area:** data · **Refs:** Data · **Depends on:** T3.3, T3.4 · **Blocks:** T3.8

**Steps**
- [x] Script `scripts/dataset_stats.py`: counts per class, per split, per player; excluded strokes; clip extraction failures.
- [ ] Write `docs/results/dataset.md` with the tables; flag classes with < 500 training samples for M5 (weighting/augmentation). (Partly done: the annotation-level tables are in `docs/results/dataset.md`; the clip-level counts wait for clip extraction, T3.1/T3.2.)

**Acceptance criteria.** Report merged before full training starts.

---

<a id="t314"></a>
### T3.14 · Classifier inference latency and fallback

**Owner:** M3 · **Estimate:** 2 h · **Priority:** P2 · **Area:** ml · **Refs:** NFR Performance · **Depends on:** T3.10 · **Blocks:** —

**Steps**
- [x] Measure the strokes stage on CPU with the trained weights of all three models (`scripts/bench_strokes.py --models cnn,lstm,rf`: [stroke_latency.md](../results/stroke_latency.md)).
- [ ] Measure it on the GPU with trained weights for a 1-minute rally; add to `timings.json`.
- [x] Ensure CPU inference works (map checkpoint to CPU) so laptops without CUDA still classify.

**Acceptance criteria.** Stage takes < 5 s on GPU and < 30 s on CPU for a 1-minute clip.

---

## Phase gate checklist (Nov 13)

1. Show `docs/results/dataset.md` and `docs/results/strokes.md` (full vs pose-only).
2. Show hit F1 on test matches.
3. Process `rally01.mp4` and show stroke labels in the video and in the app timeline.
4. Confirm the checkpoint downloads with `download_weights.py --only strokes`.
