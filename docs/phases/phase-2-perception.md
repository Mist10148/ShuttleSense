# Phase 2 — P1 perception

[← Phase 1](phase-1-foundations.md) · [Phase overview](../PHASES.md) · Next: [Phase 3 — Dataset and classifier →](phase-3-classifier.md)

| | |
| --- | --- |
| **Dates** | Mon Nov 2 – Fri Nov 6, 2026 (overlaps Phase 1 once contracts are frozen) |
| **Goal** | For any clip, produce a `record.json` with shuttle positions and both players' boxes and skeletons, plus an annotated MP4 with trail, boxes and skeletons |
| **Owners** | M1 (io, pipeline, export), M2 (tracking, render), M5 (pose), M3 (quality check) |
| **Entry criteria** | T1.1 schema frozen; T1.3/T1.4 TrackNetV3 + weights; T1.5 pose backend chosen; T1.6 ML stack installed |
| **Exit gate** | `python -m shuttlesense.run --video rally01.mp4 --out out/` fills `frames[].shuttle` and `frames[].players` and writes a playable `annotated.mp4`; 1-minute 720p clip processed in < 5 min on the T4 or RTX 4050 |
| **Milestone** | `Phase 2 — P1 perception` (due Nov 6) |

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T2.1](#t21) | Video io: normalize, frame iterator, limits | M1 | 6 h | T1.1 | ⬜ | [#24](https://github.com/Mist10148/ShuttleSense/issues/24) |
| [T2.2](#t22) | TrackNetV3 wrapper stage | M2 | 10 h | T1.3, T1.4, T2.1 | ⬜ | [#25](https://github.com/Mist10148/ShuttleSense/issues/25) |
| [T2.3](#t23) | Trajectory rectification and gap filling | M2 | 5 h | T2.2 | ⬜ | [#26](https://github.com/Mist10148/ShuttleSense/issues/26) |
| [T2.4](#t24) | Player detection and near/far IDs | M5 | 8 h | T1.5, T2.1 | ⬜ | [#27](https://github.com/Mist10148/ShuttleSense/issues/27) |
| [T2.5](#t25) | Keypoints per player with smoothing | M5 | 5 h | T2.4 | ⬜ | [#28](https://github.com/Mist10148/ShuttleSense/issues/28) |
| [T2.6](#t26) | Overlay renderer: trail, boxes, skeletons | M2 | 8 h | T2.2, T2.5 | ⬜ | [#29](https://github.com/Mist10148/ShuttleSense/issues/29) |
| [T2.7](#t27) | H.264 export via ffmpeg | M1 | 4 h | T2.6 | ⬜ | [#30](https://github.com/Mist10148/ShuttleSense/issues/30) |
| [T2.8](#t28) | Real pipeline wiring: progress and stage cache | M1 | 6 h | T2.1 | ✅ | [#31](https://github.com/Mist10148/ShuttleSense/issues/31) |
| [T2.9](#t29) | Processing-time benchmark | M1 | 3 h | T2.8 | ⬜ | [#32](https://github.com/Mist10148/ShuttleSense/issues/32) |
| [T2.10](#t210) | Shuttle tracking accuracy evaluation | M2 | 5 h | T2.3 | ⬜ | [#33](https://github.com/Mist10148/ShuttleSense/issues/33) |
| [T2.11](#t211) | Player ID and pose quality check on team clips | M3 | 3 h | T2.5 | ⬜ | [#34](https://github.com/Mist10148/ShuttleSense/issues/34) |

---

<a id="t21"></a>
### T2.1 · Video io: normalize, frame iterator, limits

**Owner:** M1 · **Estimate:** 6 h · **Priority:** P1 · **Area:** backend · **Refs:** F1, FR-1 · **Depends on:** T1.1 · **Blocks:** T2.2, T2.4, T2.8

**Goal.** Every later stage reads the same normalized frames through one API.

**Inputs.** Uploaded MP4/MOV/AVI; `configs/pipeline.yaml stages.io` (`target_height`, `max_fps`, `max_duration_s`).

**Steps**
- [ ] In `backend/shuttlesense/io/video.py` add `class FrameReader` with `__init__(path, target_height, max_fps)`, `__len__`, `__iter__` yielding `(index, frame_bgr)`, `read(index)`, `batch(start, size)`, and properties `fps`, `width`, `height` *after* normalization.
- [ ] Normalization: resize so height = `target_height` (keep aspect, even width); if source fps > `max_fps`, keep every k-th frame where `k = round(src_fps / max_fps)` and set `fps = src_fps / k`.
- [ ] `probe()` already exists: use it; reject clips longer than `max_duration_s` with a `ValueError("clip longer than 5 minutes")`.
- [ ] Rewrite `io.run` to fill metadata from the reader (normalized values) and create `frames[]`; store the reader on the context for later stages: add `ctx.reader: FrameReader | None` to `StageContext` in `stage.py`.
- [ ] API: `POST /videos` returns 400 for clips over the limit (reuse `probe`).
- [ ] Handle phone rotation metadata: if `cv2.CAP_PROP_ORIENTATION_META` is non-zero, rotate frames accordingly.

**Outputs.** `FrameReader`, `ctx.reader`, normalized record metadata.

**Tests** (`tests/test_io.py`)
- `test_probe_reads_metadata` (uses the `tiny_video` fixture)
- `test_reader_downsamples_60_to_30fps` (generate a 60 fps clip in the test)
- `test_reader_resizes_to_target_height`
- `test_rejects_clip_over_limit` (monkeypatch `max_duration_s` small)

**Acceptance criteria.** A 1080p60 phone clip and a 720p25 broadcast clip both produce a record with height 720 and fps ≤ 30; frame count matches `len(reader)`.

**Risks.** OpenCV frame counts can be wrong for VFR phone videos: count by iterating once if `CAP_PROP_FRAME_COUNT` disagrees with duration × fps by > 2%.

---

<a id="t22"></a>
### T2.2 · TrackNetV3 wrapper stage

**Owner:** M2 · **Estimate:** 10 h · **Priority:** P1 · **Area:** ml · **Refs:** F2, FR-2 · **Depends on:** T1.3, T1.4, T2.1 · **Blocks:** T2.3, T2.6, T3.5, T3.6

**Goal.** `tracking.run` fills `frames[i].shuttle = {x, y, visible}` for every frame.

**Inputs.** `ctx.reader`; `weights/tracknet/TrackNet_best.pt`; `configs/pipeline.yaml stages.tracking` (`batch_size`, weights paths).

**Steps**
- [ ] In `tracking/tracknet.py`, add `load_models(device) -> (tracknet, inpaintnet)` that adds the submodule to `sys.path` (lazy), builds the models as upstream `predict.py` does and loads checkpoints with `map_location=device`. Cache loaded models in a module-level dict keyed by device so the API worker loads them once.
- [ ] Implement sliding-window inference: build input sequences of the length TrackNetV3 expects (see notes from T1.3) from `ctx.reader.batch(...)`, resized to the network input size; include the background/median frame if the upstream model needs it.
- [ ] Convert heatmaps to coordinates (upstream threshold + largest connected component), scale back to normalized video pixels.
- [ ] Call `ctx.progress(done / total)` at least every batch.
- [ ] Write `frames[i].shuttle` and `ctx.out_dir / "tracking.csv"` with columns `frame,visible,x,y` (same as upstream).
- [ ] Use `torch.inference_mode()` and `torch.autocast("cuda")` when on CUDA; free GPU memory at the end (`torch.cuda.empty_cache()`).
- [ ] CPU fallback works (slowly) for short clips.

**Outputs.** Filled shuttle field, `tracking.csv`.

**Tests**
- `tests/test_tracking.py::test_heatmap_to_xy_picks_peak` (pure function on a synthetic heatmap; extract the post-processing into `heatmap_to_xy(heatmap, threshold)`).
- `test_tracking.py::test_scale_back_to_video_pixels`.
- GPU smoke test marked `@pytest.mark.gpu` (skipped in CI) running on `samples/rally01.mp4` if present.

**Acceptance criteria.** On `rally01.mp4` and one broadcast clip, the overlay (T2.6) trail follows the shuttle on visual review of 3 rallies; `tracking.csv` matches upstream `predict.py` output within 2 px on ≥ 95% of frames.

**Risks.** Upstream code assumes 512×288 input and specific folder layouts: wrap, don't fork. If wrapping is impossible, vendor the two model classes into `tracking/models.py` with the MIT header.

---

<a id="t23"></a>
### T2.3 · Trajectory rectification and gap filling

**Owner:** M2 · **Estimate:** 5 h · **Priority:** P1 · **Area:** ml · **Refs:** F2 · **Depends on:** T2.2 · **Blocks:** T2.10, T3.6

**Steps**
- [ ] Run InpaintNet on the TrackNet output as upstream does (trajectory rectification), behind config flag `stages.tracking.use_inpaintnet: true`.
- [ ] Then call the existing `tracking.interpolate_gaps(xy, visible, max_gap=stages.tracking.max_gap_frames)`.
- [ ] Remove isolated detections: a visible frame whose neighbours within ±2 frames are all invisible and that is > 80 px from the last visible point is set invisible (config `outlier_px`).
- [ ] Mark interpolated frames (keep `visible=1`) but add a debug column `source` (`net`, `inpaint`, `interp`) in `tracking.csv` only.

**Tests**
- Existing `test_interpolate_fills_short_gap_only`.
- `test_tracking.py::test_outlier_removed`, `test_long_gap_not_filled`.

**Acceptance criteria.** On smash-heavy clips, missing frames drop measurably vs T2.2 alone (report % visible before/after in the PR).

---

<a id="t24"></a>
### T2.4 · Player detection and near/far IDs

**Owner:** M5 · **Estimate:** 8 h · **Priority:** P1 · **Area:** ml · **Refs:** F3, FR-3 · **Depends on:** T1.5, T2.1 · **Blocks:** T2.5, T2.6

**Goal.** Exactly two players per frame, with IDs that never swap during a rally.

**Inputs.** `ctx.reader`; chosen backend from T1.5 (`stages.pose.backend`, `mode`, `min_person_score`).

**Steps**
- [ ] In `pose/estimator.py`, add `load_detector(backend, mode, device)` (lazy rtmlib/torchvision import, cached per device).
- [ ] Per frame: detect people, drop boxes below `min_person_score`.
- [ ] Filter to players: if `record.court` exists, keep people whose foot point (bottom-centre of bbox) projects inside the court expanded by 1.5 m (`court.image_to_court`); otherwise keep the two largest boxes whose feet are in the lower 90% of the frame (removes umpires/spectators in the stands).
- [ ] Assign sides with the existing `assign_sides` on the first frame; afterwards track by nearest previous bbox centre (Hungarian on IoU/centre distance via `scipy.optimize.linear_sum_assignment`), so IDs stay stable through crossings at the net.
- [ ] If only one player is detected, keep the previous box for up to `stages.pose.hold_frames` (add to config, default 5) and lower its score.
- [ ] Write `frames[i].players.near/far = Player(bbox, score)`.

**Tests** (`tests/test_pose.py`)
- `test_assign_sides_by_feet_position` (exists)
- `test_tracking_keeps_ids_when_players_cross` (synthetic boxes moving past each other)
- `test_filters_people_outside_court` (with a synthetic homography)
- `test_hold_missing_player_for_n_frames`

**Acceptance criteria.** On both team clips and one broadcast clip, near/far IDs never swap within a rally (visual check of the overlay); both players present in ≥ 95% of frames.

---

<a id="t25"></a>
### T2.5 · Keypoints per player with smoothing

**Owner:** M5 · **Estimate:** 5 h · **Priority:** P1 · **Area:** ml · **Refs:** F4, FR-4 · **Depends on:** T2.4 · **Blocks:** T2.6, T3.5, T3.6, T5.4, T5.8

**Steps**
- [ ] Get 17 COCO keypoints for each kept box (rtmlib returns keypoints with boxes; for Keypoint R-CNN take them from the same output).
- [ ] Store as `[[x, y, score] × 17]` in normalized video pixels.
- [ ] Temporal smoothing per joint with a centred moving average over `stages.pose.smoothing_window` frames, ignoring joints with score < 0.3 (config `min_keypoint_score`); do not smooth across frames where the player was missing.
- [ ] Report progress per frame batch.

**Tests**
- `test_pose.py::test_smoothing_reduces_jitter` (noisy synthetic sequence → lower variance)
- `test_pose.py::test_low_score_joints_not_smoothed_into_good_ones`

**Acceptance criteria.** Skeletons drawn by T2.6 sit on both players with no visible flicker on review; keypoint arrays always length 17.

---

<a id="t26"></a>
### T2.6 · Overlay renderer: trail, boxes, skeletons

**Owner:** M2 · **Estimate:** 8 h · **Priority:** P1 · **Area:** backend · **Refs:** F2–F4, F7 · **Depends on:** T2.2, T2.5 · **Blocks:** T2.7, T3.11, T5.3, T6.6

**Goal.** A layer system that later tasks extend without touching each other's code.

**Steps**
- [ ] In `render/overlays.py`, define `Layer = Callable[[np.ndarray, ClipRecord, int, RenderState], None]` and a registry `LAYERS: dict[str, Layer]` keyed by the names in `OVERLAYS`.
- [ ] Implement `draw_trail` (last `stages.tracking.trail_length` visible positions, fading alpha and radius), `draw_boxes` (player colour, label "Near"/"Far"), `draw_pose` (COCO skeleton edges, joints with score ≥ 0.3).
- [ ] Use the same player colours as the app: near `#1565C0`, far `#E65100`, shuttle `#C6A700` (constants in `render/style.py`).
- [ ] `run()`: iterate `ctx.reader`, apply the layers in `ctx.overlays` order, hand frames to the writer (T2.7). Progress per frame.
- [ ] Unknown/unimplemented layer names are ignored with a log line (so `hits`, `court`, … can be added later).

**Tests** (`tests/test_render.py`)
- `test_trail_draws_only_visible_points` (draw on a black frame, count non-zero pixels near expected points)
- `test_layers_respect_overlay_selection`

**Acceptance criteria.** Annotated video shows trail, boxes and skeletons on `rally01.mp4`; disabling an overlay in the job request removes it.

---

<a id="t27"></a>
### T2.7 · H.264 export via ffmpeg

**Owner:** M1 · **Estimate:** 4 h · **Priority:** P1 · **Area:** backend · **Refs:** F7, FR-7 · **Depends on:** T2.6 · **Blocks:** T4.6

**Steps**
- [ ] `render/writer.py`: `VideoWriter(path, fps, size)` that pipes raw BGR frames into `ffmpeg -f rawvideo -pix_fmt bgr24 -s WxH -r FPS -i - -c:v libx264 -pix_fmt yuv420p -crf {crf} -movflags +faststart out.mp4` via `subprocess.Popen`.
- [ ] Fallback when `shutil.which("ffmpeg")` is None: OpenCV `mp4v` writer and a warning in the job (`record` unchanged; add `warnings` to the Job model later if needed).
- [ ] Keep the original audio? No (out of scope); document.
- [ ] Ensure `annotated.mp4` lands in `ctx.out_dir` so `JobManager` marks `outputs.video = true`.

**Tests**
- `tests/test_render.py::test_writer_produces_playable_mp4` (skipped if ffmpeg missing; read back with `cv2.VideoCapture`, check frame count).

**Acceptance criteria.** Output plays in VLC, Chrome (`<video>`), and in the app on Android and Windows; seeking works (range requests).

---

<a id="t28"></a>
### T2.8 · Real pipeline wiring: progress and stage cache

**Owner:** M1 · **Estimate:** 6 h · **Priority:** P1 · **Area:** backend · **Refs:** NFR Modularity · **Depends on:** T2.1 · **Blocks:** T2.9, T5.12

**Steps**
- [ ] In `pipeline.run_pipeline`, after each stage write `out_dir/cache/<stage>.json` containing only the fields that stage owns (per the ownership table); on start, if a cache file exists and its `config_hash` matches, load it and skip the stage (status `done`, progress 1).
- [ ] `config_hash` = SHA-1 of the stage's config block + video file size + schema version.
- [ ] Weight overall job progress by expected stage cost (config `stages.<name>.weight`, defaults: tracking 4, pose 4, render 2, others 0.2) in `JobManager._on_event`.
- [ ] Load models once per worker: keep the model caches from T2.2/T2.4 alive between jobs.
- [ ] Log per-stage wall time to `out_dir/timings.json`.

**Tests**
- `test_pipeline.py::test_cached_stage_is_skipped` (fake stage counting calls)
- `test_pipeline.py::test_config_change_invalidates_cache`
- `test_api.py::test_progress_is_monotonic` (stub stages with sleeps)

**Acceptance criteria.** Re-running the same job with only overlays changed skips tracking and pose; `/jobs/{id}.progress` never decreases.

---

<a id="t29"></a>
### T2.9 · Processing-time benchmark

**Owner:** M1 · **Estimate:** 3 h · **Priority:** P1 · **Area:** infra · **Refs:** NFR Performance · **Depends on:** T2.8 · **Blocks:** T7.3

**Steps**
- [ ] Add `backend/scripts/benchmark.py --video X --runs 3` that runs the pipeline and prints `timings.json` aggregated (median per stage, total, fps).
- [ ] Run on a 1-minute 720p clip on the RTX 4050 and the Colab T4.
- [ ] Add a "Processing time" table to README "Evaluation".
- [ ] If over 5 minutes: try TrackNet batch size, rtmlib `lightweight` mode, half precision, and skipping pose on frames far from any hit (document trade-offs).

**Acceptance criteria.** Table merged; total < 5 min on at least one target, or a written plan with measured options.

---

<a id="t210"></a>
### T2.10 · Shuttle tracking accuracy evaluation

**Owner:** M2 · **Estimate:** 5 h · **Priority:** P1 · **Area:** ml · **Refs:** Success metrics (shuttle detection ≥ 85% within 4 px) · **Depends on:** T2.3 · **Blocks:** T7.3

**Steps**
- [ ] Get labelled test clips: the TrackNet test split (from the Shuttlecock Trajectory Dataset release) or ShuttleSet clips with shuttle labels if available; otherwise hand-label 300 frames of `rally01.mp4` with a tiny OpenCV click tool (`scripts/label_shuttle.py`).
- [ ] `scripts/eval_tracking.py --pred tracking.csv --gt labels.csv`: accuracy = % of visible GT frames with prediction within 4 px (scaled to 720p), plus precision/recall of visibility.
- [ ] Report results for raw TrackNet vs + InpaintNet vs + interpolation.

**Tests.** `tests/test_eval.py::test_tracking_accuracy_metric` on synthetic CSVs.

**Acceptance criteria.** Metric table in the PR and README; target ≥ 85% (report honestly if lower, especially on phone footage).

---

<a id="t211"></a>
### T2.11 · Player ID and pose quality check on team clips

**Owner:** M3 · **Estimate:** 3 h · **Priority:** P2 · **Area:** ml · **Refs:** FR-3, FR-4 · **Depends on:** T2.5 · **Blocks:** —

**Steps**
- [ ] Run the full perception pipeline on both team clips and one broadcast clip.
- [ ] Count ID swaps, frames with a missing player, frames where the far player's wrists have score < 0.3.
- [ ] Post 6 annotated stills (good and bad) and the counts on the issue; open follow-up bugs for systematic failures.

**Acceptance criteria.** Counts reported; zero ID swaps within rallies or a bug filed.

---

## Phase gate checklist (Nov 6)

1. Run `python -m shuttlesense.run --video samples/rally01.mp4 --out out/rally01` live; open `annotated.mp4`.
2. Show `record.json` frame entries with `shuttle` and both `players` filled.
3. Show the benchmark table (T2.9) and tracking accuracy (T2.10).
4. Upload the same clip from the app and show the job finishing with a playable video.
