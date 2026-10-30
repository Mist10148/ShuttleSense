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
| Are line calls right? | Precision / recall for IN and OUT on certain calls; uncertain share; false-call rate on certain calls within 20 cm of a line | Report as measured | Labelled landings: team clips (T7.1 `in_out`, `landing_x_m`, `landing_y_m`) and ShuttleSet `lose_reason` | `results/line_calls.md` |
| Is live fast enough? | Frame sent → frame event back, p50 / p95 | p95 ≤ 300 ms with models on the RTX 4050 | Team clip replayed with `live_replay` | `results/live_latency.md` |
| Do live and offline agree? | Same hits, rallies, line calls and score | Exact | Synthetic rallies (`stream/synthetic.py`) | `tests/test_stream.py::test_offline_live_parity` |

## 2. Data and splits

- **ShuttleSet** (Wang et al., KDD 2023): 44 elite singles matches, 36,484 annotated strokes. 18 stroke types are merged into 6 classes (`docs/DATA_FORMAT.md`). The 4 drive types and "unknown" are excluded, leaving 33,430 strokes.
- **Split by match**, never by stroke, so strokes from one match never appear in two splits: 31 train, 6 val and 7 test matches, stratified by class (`backend/configs/splits.json`). Counts per split are in [results/dataset.md](results/dataset.md).
- **Team phone footage**: 5–10 consented rallies, labelled with `scripts/label_clip.py` (T7.1). It is used for evaluation only, never for training.

## 3. Method

- **Hits:** rule-based, a sharp turn of the shuttle near a wrist. Thresholds are tuned on val matches only (`eval_hits.py --grid`).
- **Strokes:** a 1D CNN over 32-frame windows of pose and shuttle features. Training uses 3 seeds and reports mean ± std. The pose-only ablation uses the same seeds.
- **Phone footage:** processed with the frozen pipeline and calibration.
- **Line calls:** each labelled rally is matched to a predicted rally (start and end within ±1 s, as for rally boundaries). Only certain calls count towards precision and recall; UNCERTAIN calls are the ones the app hands to the user, and their share is reported next to the scores so a low false-call rate cannot hide behind many uncertain calls. The near-line false-call rate uses the labelled landing position when the label has one, otherwise the predicted margin, and the report states which. ShuttleSet labels come from `lose_reason` (out, or landed in); net faults and other reasons are skipped, and the mapping must be checked against the downloaded CSVs before reporting.
- **Live latency:** `scripts/bench_live.py` sends frames one at a time and waits for each frame's event, so the number is the processing path without queueing (network on localhost, JPEG decode, perception, windowed analysis). Events that need look-ahead lag by design: hits by 17 frames (0.57 s at 30 fps) plus at most one 5-frame tick, line calls until the shuttle has rested for 20 frames (0.67 s).

## 4. Results

Most results are to be filled in from the reports in §1. Measured so far (Oct 31, commit noted in each report):

| What | Result | Report |
| --- | --- | --- |
| Live pipeline overhead without models (fake perception, in-process, 600 frames) | p50 10.1 ms, p95 20.7 ms frame → event round trip; server side p95 17.5 ms; 82 fps one at a time | [results/live_latency.md](results/live_latency.md) |
| Offline vs live on synthetic rallies | Identical hits (10), rallies (3), line calls (IN, OUT, UNCERTAIN) and score | `pytest tests/test_stream.py` |
| Live latency with TrackNetV3 and pose on the RTX 4050 | **Not measured**: the weights are not installed yet. Run `scripts/bench_live.py --url ... --video <team clip>` against a server with `stages` both true | – |
| Line-call precision / recall / near-line false calls | **Not measured**: no labelled landings yet | – |

The fake-perception numbers bound everything around the models, not the models: TrackNetV3 on one window and RTMPose per frame come on top. Whether the 300 ms budget holds with them is open until the GPU run.

## 5. Error analysis

- The most confused stroke pairs and why (`results/strokes.md`, `strokes_confusion.png`).
- Where hit detection fails: shuttle out of frame, occlusion by the player, net shots with little direction change.
- Broadcast vs phone gap: camera height and angle, motion blur, frame rate.

## 6. Threats to validity

- ShuttleSet is elite broadcast footage from elevated cameras. Team clips differ in angle, players and lighting.
- The team phone set is small (≥ 100 hits), so its percentages have wide confidence intervals. Report the counts with them.
- The same people labelled and evaluated the team clips. A second labeller checks two clips (T7.1).
- Speed is a 2D court-plane estimate and is not validated against radar.
- Line calls come from one camera at 720p and 30 fps: the landing pixel is projected onto the floor, and near the far baseline one pixel covers several centimetres. Calls near a line are expected to be UNCERTAIN often; the evaluation reports that share instead of hiding it. These are automated calls, not certified officiating.
- Live frames from browsers and Windows webcams arrive as still captures at roughly 5–15 fps, below the 30 fps TrackNetV3 was trained on, so live tracking from those devices is expected to be worse than from uploaded clips. Measure it per device before quoting live accuracy.
