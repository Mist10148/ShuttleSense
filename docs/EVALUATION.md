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

## 2. Data and splits

- **ShuttleSet** (Wang et al., KDD 2023): 44 elite singles matches, 36,484 annotated strokes. 18 stroke types are merged into 6 classes (`docs/DATA_FORMAT.md`). The 4 drive types and "unknown" are excluded, leaving 33,430 strokes.
- **Split by match**, never by stroke, so strokes from one match never appear in two splits: 31 train, 6 val and 7 test matches, stratified by class (`backend/configs/splits.json`). Counts per split are in [results/dataset.md](results/dataset.md).
- **Team phone footage**: 5–10 consented rallies, labelled with `scripts/label_clip.py` (T7.1). It is used for evaluation only, never for training.

## 3. Method

- **Hits:** rule-based, a sharp turn of the shuttle near a wrist. Thresholds are tuned on val matches only (`eval_hits.py --grid`).
- **Strokes:** a 1D CNN over 32-frame windows of pose and shuttle features. Training uses 3 seeds and reports mean ± std. The pose-only ablation uses the same seeds.
- **Phone footage:** processed with the frozen pipeline and calibration.

## 4. Results

To be filled in from the reports in §1.

## 5. Error analysis

- The most confused stroke pairs and why (`results/strokes.md`, `strokes_confusion.png`).
- Where hit detection fails: shuttle out of frame, occlusion by the player, net shots with little direction change.
- Broadcast vs phone gap: camera height and angle, motion blur, frame rate.

## 6. Threats to validity

- ShuttleSet is elite broadcast footage from elevated cameras. Team clips differ in angle, players and lighting.
- The team phone set is small (≥ 100 hits), so its percentages have wide confidence intervals. Report the counts with them.
- The same people labelled and evaluated the team clips. A second labeller checks two clips (T7.1).
- Speed is a 2D court-plane estimate and is not validated against radar.
