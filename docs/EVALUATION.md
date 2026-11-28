# Evaluation

Written evaluation of ShuttleSense (T7.9). Each section names the report in [docs/results/](results/) its numbers come from. Fill in the results after the feature freeze (T7.3) and keep every number traceable to a script and a commit.

## 1. What is measured

| Question | Metric | Target | Data | Report |
| --- | --- | --- | --- | --- |
| Is the shuttle found? | Frames within 4 px (720p) | ≥ 85% | Hand-labelled frames | `results/tracking.md` |
| Are hits found? | F1, ±3 frames | ≥ 0.75 | ShuttleSet test matches | `results/hits.md` |
| Are strokes right? | Macro accuracy, 6 classes | ≥ 70% | ShuttleSet test matches | `results/strokes.md` |
| Does shuttle trajectory help? | Macro accuracy, pose only vs pose + shuttle | Report | Same | `results/strokes.md` |
| Does it hold on phone video? | Stroke accuracy; count error per rally; rally boundaries | ≥ 55%; ≤ 1; ≥ 80% | Team clips | `results/phone.md`, `results/rallies.md` |
| Is it fast enough? | Wall time for a 1-min 720p clip | < 5 min | Team clip, Colab T4 / RTX 4050 | `results/benchmark.md`, `results/stroke_latency.md` |
| Does the app work everywhere? | T7.4 checklist | All pass | Android phone and tablet, Windows, Chrome | T7.4 PR |
| Are line calls right? | Precision / recall for IN and OUT on certain calls; uncertain share; false-call rate on certain calls within 20 cm of a line | Report as measured | Labelled landings: team clips (T7.1 `in_out`; `landing_x_m`, `landing_y_m` marked with `scripts/label_landings.py`) and ShuttleSet `lose_reason` | `results/line_calls.md` |
| Is live fast enough? | Frame sent → frame event back, p50 / p95 | p95 ≤ 300 ms with models on the RTX 4050 | Team clip replayed with `live_replay` | `results/live_latency.md` |
| Do live and offline agree? | Same hits, rallies, line calls and score | Exact | Synthetic rallies (`stream/synthetic.py`) | `tests/test_stream.py::test_offline_live_parity` |

## 2. Data and splits

- **ShuttleSet** (Wang et al., KDD 2023): 44 elite singles matches, 36,484 annotated strokes. 18 stroke types are merged into 6 classes (`docs/DATA_FORMAT.md`). The 4 drive types and "unknown" are excluded, leaving 33,430 strokes.
- **Split by match**, never by stroke, so strokes from one match never appear in two splits: 31 train, 6 val and 7 test matches, stratified by class (`backend/configs/splits.json`). Counts per split are in [results/dataset.md](results/dataset.md).
- **Team phone footage**: 5–10 consented rallies, labelled with `scripts/label_clip.py` (T7.1). It is used for evaluation only, never for training.

## 3. Method

- **Hits:** rule-based, a sharp turn of the shuttle near a wrist. Thresholds are tuned on val matches only (`eval_hits.py --grid`).
- **Strokes:** three models over the same 30-frame window of pose and shuttle features (39 values per frame): a 1D CNN, a bidirectional LSTM, and a Random Forest on summary statistics of the window. Each is trained with 3 seeds, selected on the validation split and evaluated once on the test split; results are mean ± std. The pose-only ablation uses the same seeds. They were trained on the pre-extracted ShuttleSet features published with BST (D29): 30 train, 5 validation and 5 test matches as split by BST, 23,723 / 3,821 / 3,136 strokes after the drive and unknown types are left out.
- **Phone footage:** processed with the frozen pipeline and calibration.
- **Line calls:** each labelled rally is matched to a predicted rally (start and end within ±1 s, as for rally boundaries). Only certain calls count towards precision and recall; UNCERTAIN calls are the ones the app hands to the user, and their share is reported next to the scores so a low false-call rate cannot hide behind many uncertain calls. The near-line false-call rate uses the labelled landing position when the label has one, otherwise the predicted margin, and the report states which. ShuttleSet labels come from `lose_reason` (out, or landed in); net faults and other reasons are skipped, and the mapping must be checked against the downloaded CSVs before reporting.
- **Live latency:** `scripts/bench_live.py` sends frames one at a time and waits for each frame's event, so the number is the processing path without queueing (network on localhost, JPEG decode, perception, windowed analysis). Events that need look-ahead lag by design: hits by 17 frames (0.57 s at 30 fps) plus at most one 5-frame tick, line calls and rally ends until the rest rule and the settle window have passed. The benchmark measures this event lag per event type, in frames after the frame the event is about (contact, landing, rally end), which does not depend on the machine.

## 4. Results

Most results are to be filled in from the reports in §1. Each benchmark report records its date and commit.

| What | Result | Report |
| --- | --- | --- |
| Stroke macro accuracy, 6 classes, BST test split (3,136 strokes, 3 seeds) | 1D CNN 91.2% ± 0.6%, LSTM 90.2% ± 0.5%, Random Forest 85.3% ± 0.2%; ensemble with the fitted weights 92.2% (shipped models, before the rally context). Target ≥ 70%. (Fourth evaluation on this test split, Nov 20: the forest was retrained with velocity rows and calibration, and the ensemble weights were fitted; every choice was made by match-grouped cross-validation first, D41, [results/strokes_cv.md](results/strokes_cv.md). Third evaluation: the LSTM and the forest were retrained on Nov 16, the CNN was not replaced; Nov 15: 91.2%, 89.0%, 84.3%; Nov 14: 89.5%, 88.1%, 82.1%) | [results/strokes.md](results/strokes.md) |
| The same with rally and court context, shipped weights (one seed each) | 1D CNN 91.8% → 93.4%, LSTM 90.7% → 92.3%, Random Forest 85.0% → 89.5%, ensemble of the three 91.6% → 93.8%. Annotated hit frames stand in for the hit detector, so the gain in the app will be smaller | [results/stroke_context.md](results/stroke_context.md) |
| Ablation: shuttle trajectory features (1D CNN) | pose only 77.5% ± 0.7% against 91.2% ± 0.6% with the shuttle (1D CNN) | [results/strokes.md](results/strokes.md) |
| Stroke confidence | The networks store a softmax temperature fitted on the validation split (0.53 for the CNN, 0.60 for the LSTM), so `confidence` is calibrated on broadcast data; the predicted class is unchanged. Not measured on phone footage | [results/strokes.md](results/strokes.md) |
| Stroke stage latency, CPU, 40 hits in a 1-minute clip | Under 0.1 s for each of the three models | [results/stroke_latency.md](results/stroke_latency.md) |
| Live pipeline overhead with fake perception (420 frames paced at 30 fps) | p50 12.9 ms and p95 26.2 ms frame round trip, with p95 22.9 ms on the server | [results/live_latency.md](results/live_latency.md) |
| The same, 300 frames on Nov 12 | p50 15.7 ms and p95 36.7 ms round trip, p95 31.0 ms on the server; hits 0.74 s and line calls 1.73 s at p95 | [results/live_latency_fake.md](results/live_latency_fake.md) |
| Courtside update, 300 frames with fake perception on Nov 15 | p50 11.7 ms and p95 23.0 ms frame round trip, with p95 20.1 ms on the server | [results/live_latency_courtside_fake.md](results/live_latency_courtside_fake.md) |
| Live event lag in the same run | p95 0.736 s for hits, 1.733 s for line calls and 1.734 s for rally ends | [results/live_latency.md](results/live_latency.md) |
| Offline vs live on synthetic rallies | Identical hits (10), rallies (3), line calls (IN, OUT, UNCERTAIN) and score | `pytest tests/test_stream.py` |
| Saved live replay after reconnect | Fake session with two missing capture slots, an uncertain call resolved, and a point awarded and undone. All coach citations seek to readable frames in the rendered MP4; the saved score matches the live decision. | `pytest tests/test_live.py -k saved_replay` |
| Live latency with TrackNetV3 and pose on the RTX 4050, generated 640×360 clip | p50 109.8 ms and p95 201.4 ms round trip, with p95 199.7 ms on the server and 7.6 fps sequential throughput | [results/live_latency_courtside_model_smoke.md](results/live_latency_courtside_model_smoke.md) |
| Live latency with TrackNetV3 and pose on labelled courtside footage | Pending a calibrated team clip. Use `scripts/bench_live.py --url ... --video <team clip> --require-models`. | – |
| Line-call precision / recall / near-line false calls | **Not measured**: no labelled landings yet | – |

The GPU smoke run used the first 120 frames of a 30 fps, 640×360 generated clip
with a static court outline and a moving dot. The server used PyTorch 2.15.0+cu132,
the upstream TrackNetV3 checkpoint, RTMLib 0.0.16 in balanced mode and ONNX
Runtime GPU 1.31.1. YOLOX and RTMPose both selected the CUDA provider. The
sequential throughput was below the camera rates targeted by the app. Run the
benchmark on a real court to measure load with players, frame drops and event
timing during rallies.

## 5. Error analysis

**Strokes** (measured, [results/strokes.md](results/strokes.md)):

- **Drop against smash is the main error for every model.** A drop is called a smash in 17%
  of cases by the CNN, 21% by the LSTM and 31% by the Random Forest; the reverse happens in
  9% to 11%. Both are overhead strokes with the same preparation, and they differ mostly in
  racket speed at contact and in how fast the shuttle leaves, which a one-second window of
  body keypoints (no racket) and a 2D shuttle position shows only weakly. Drop has the
  lowest F1 of the six classes for every model (80%, 75%, 68%).
- **Lift against net shot** is second (6% to 16%): both are played low at the net, and the
  difference is the shuttle's path after the hit.
- **The shuttle carries most of that difference.** Without the shuttle features the CNN
  falls from 91.2% to 77.5% macro accuracy, and clear drops furthest (F1 93.5% to 67.9%):
  a clear, a drop and a smash look alike from the pose alone. The practical consequence is
  that stroke accuracy depends on shuttle tracking, which is not measured on phone footage.
- **The forest is weakest where timing matters.** It sees summary statistics, not the order
  of frames, and its drop-to-smash confusion rose from 27% to 31% with the Nov 15 settings
  even though its overall accuracy rose by two points.
- **A training-data fault found on Nov 15** (D35): 61% of the training windows had the hit
  three frames early. Correcting it and re-tuning on the validation split moved the CNN from
  89.5% to 91.2%, the LSTM from 88.1% to 89.0% and the forest from 82.1% to 84.3%. The test
  split had been evaluated once before, so these gains are estimates.
- **No class for other strokes.** Drives are left out of training, so every drive in a real
  rally is given one of the six labels, usually with a low confidence.

**Not measured yet** (no labelled team footage):

- Shuttle tracking after the Nov 16 changes (overlapping windows on uploads, burst and gap clean-up, clean-up of the live and Watch window before hit detection). Each has unit tests on synthetic tracks; none has an accuracy number, because no frame of team footage has a labelled shuttle position (`scripts/label_shuttle.py`, `scripts/eval_tracking.py`).
- The court map after the Nov 16 changes: the floor point under the ankles, the snapped corners and the shuttle placed between the two hitters. These follow from geometry and are tested on constructed cases, not against surveyed positions.
- Tracking precision (D43): sub-pixel heatmap peaks, depth-scaled outlier thresholds, flight-by-flight fitting and hit timing, and the least-squares court fit. On synthetic corrupted rallies the track error falls from about 40 px to 7 px (`tests/test_tracking_precision.py`); on real footage there is no number yet. Without labels, `scripts/eval_track_smoothness.py record.json --rectify` compares jitter, visible share and hit count before and after on any processed clip.
- The heatmap (D44): seconds per 0.25 m cell with a depth-dependent Gaussian, in the app and in `heatmap.json`. Tested for its mass, peak position and kernel width on constructed positions, not against tracked players.
- What the extra clean-up and the stroke context cost per frame in Watch & Analyze on its target GPU. This pass ran on a CPU without the pose stack.

- Where hit detection fails: shuttle out of frame, occlusion by the player, net shots with little direction change. The stroke models were trained on annotated hit frames; a detected hit a few frames off is covered only by the ±2 to ±4 frame shift used in training.
- Broadcast vs phone gap: camera height and angle, motion blur, frame rate. A clip at another frame rate is now sampled over the same one-second span the models were trained on, which has a unit test but no accuracy measurement.

### Court placement spot check (Nov 22)

Manually labeled visible shoe contact points and singles court lines on a development clip and
a separate held-out broadcast clip. Re-ran the existing player tracker with the labeled court
corners, then compared the old and new floor-position calculations on the same detections and
homography. The development clip needed correctly ordered corner taps before the comparison.
Errors below use the same available frames for both methods.

| Clip and side | Labeled frames | Missing before / after | Median before → after (m) | 90th percentile before → after (m) |
| --- | ---: | ---: | ---: | ---: |
| Development singles, near | 5 | 0 / 0 | 0.105 → 0.105 | 0.122 → 0.122 |
| Development singles, far | 5 | 0 / 0 | 0.550 → 0.549 | 0.603 → 0.592 |
| Held-out singles, near | 9 | 1 / 1 | 0.169 → 0.128 | 0.467 → 0.410 |
| Held-out singles, far | 8 | 2 / 2 | 0.176 → 0.178 | 0.413 → 0.407 |

The near-side median and 90th percentile both improved on the held-out clip. The far-side
median was effectively flat at the precision of the hand labels. The sample is too small for
an overall accuracy claim.

In the local doubles clip, the camera crops the near baseline, so the check compared foot
points in source pixels using the same pose detections. Near-side median / 90th-percentile
errors were 10.8 / 18.1 px before and 11.2 / 18.1 px after, with one of six labeled points
unmatched in both versions. Far-side errors were 5.7 / 13.8 px in both versions, with all
six points matched. Doubles accuracy in court meters remains unmeasured.

Reanalyze saved uploads to refresh player coordinates. A video re-render refreshes the
shuttle trail using the existing tracking data.

### Four doubles players (Nov 28, D66)

Label-free coverage on two saved doubles clips with their saved court taps. Both runs used
the same detections in each frame, with far-court refinement on. A box jump is a slot whose
foot point moves more than 80 px between consecutive frames, a proxy for identity switches.

| Clip | Frames | All four players (tracker → keeper) | Per slot near / near_2 / far / far_2 | Box jumps |
| --- | ---: | ---: | --- | ---: |
| Green-court upload | 350 | 27.7% → 58.0% | 76/96/49/75% → 78/97/75/91% | 0 → 0 |
| Watch doubles (1024×576) | 600 | 66.5% → 78.5% | 98/94/85/80% → 99/94/89/92% | 1 → 2 |

The keeper fills the far pair most, where the tracker loses a partner behind the other. This
measures presence, not identity: one extra jump on the Watch clip may be a wrong fill, and
ID switches and IDF1 still need labelled boxes (`label_clip.py --boxes`, `eval_doubles.py`).

## 6. Threats to validity

- ShuttleSet is elite broadcast footage from elevated cameras. Team clips differ in angle, players and lighting.
- The team phone set is small (≥ 100 hits), so its percentages have wide confidence intervals. Report the counts with them.
- The same people labelled and evaluated the team clips. A second labeller checks two clips (T7.1).
- Speed is a 2D court-plane estimate and is not validated against radar.
- Line calls come from one camera at 720p and 30 fps: the landing pixel is projected onto the floor, and near the far baseline one pixel covers several centimetres. Calls near a line are expected to be UNCERTAIN often; the evaluation reports that share instead of hiding it. These are automated calls, not certified officiating. Since D45 the referee would rather leave a rally to the user than guess: a shuttle lost before it rests, held in a hand, resting far off court, landing on the net line, or called OUT against the last detected hitter gives no automatic point, so the share of rallies scored automatically should be reported next to the call accuracy. References: BWF Laws of Badminton; Liu & Wang, *MonoTrack*, CVPRW 2022 (3D shuttle trajectories from one camera); *Automatic Shuttlecock Fall Detection System in or out of a Court*, Sensors 2022 (practical in/out challenges).
- Live frames from browsers and Windows webcams arrive as still captures at roughly 5–15 fps, below the 30 fps TrackNetV3 was trained on, so live tracking from those devices is expected to be worse than from uploaded clips. Measure it per device before quoting live accuracy.


## Courtside depth verification

Synthetic fixtures exercise duplicate command recovery, interval transitions, goals,
undo history and replay and export persistence. They do not measure tracking quality,
line-call accuracy, coaching impact or real device latency. Use the labelled footage
and device procedures in [Phase 13](phases/phase-13-courtside-depth.md#next-courtside-session)
to collect those measurements. Goal completion is self-reported.
