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
| Stroke macro accuracy, 6 classes, BST test split (3,136 strokes, 3 seeds) | 1D CNN 91.2% ± 0.6%, LSTM 90.2% ± 0.5%, Random Forest 84.7% ± 0.3%. Target ≥ 70%. (third evaluation on this test split: the LSTM and the forest were retrained on Nov 16, the CNN was not replaced; Nov 15: 91.2%, 89.0%, 84.3%; Nov 14: 89.5%, 88.1%, 82.1%) | [results/strokes.md](results/strokes.md) |
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
- What the extra clean-up and the stroke context cost per frame in Watch & Analyze on its target GPU. This pass ran on a CPU without the pose stack.

- Where hit detection fails: shuttle out of frame, occlusion by the player, net shots with little direction change. The stroke models were trained on annotated hit frames; a detected hit a few frames off is covered only by the ±2 to ±4 frame shift used in training.
- Broadcast vs phone gap: camera height and angle, motion blur, frame rate. A clip at another frame rate is now sampled over the same one-second span the models were trained on, which has a unit test but no accuracy measurement.

## 6. Threats to validity

- ShuttleSet is elite broadcast footage from elevated cameras. Team clips differ in angle, players and lighting.
- The team phone set is small (≥ 100 hits), so its percentages have wide confidence intervals. Report the counts with them.
- The same people labelled and evaluated the team clips. A second labeller checks two clips (T7.1).
- Speed is a 2D court-plane estimate and is not validated against radar.
- Line calls come from one camera at 720p and 30 fps: the landing pixel is projected onto the floor, and near the far baseline one pixel covers several centimetres. Calls near a line are expected to be UNCERTAIN often; the evaluation reports that share instead of hiding it. These are automated calls, not certified officiating.
- Live frames from browsers and Windows webcams arrive as still captures at roughly 5–15 fps, below the 30 fps TrackNetV3 was trained on, so live tracking from those devices is expected to be worse than from uploaded clips. Measure it per device before quoting live accuracy.


## Courtside depth verification

Synthetic fixtures exercise duplicate command recovery, interval transitions, goals,
undo history and replay and export persistence. They do not measure tracking quality,
line-call accuracy, coaching impact or real device latency. Use the labelled footage
and device procedures in [Phase 13](phases/phase-13-courtside-depth.md#next-courtside-session)
to collect those measurements. Goal completion is self-reported.
