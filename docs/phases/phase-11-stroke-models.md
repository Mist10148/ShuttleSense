# Phase 11 — Selectable stroke models

[← Phase 10](phase-10-hardening.md) · [Phase overview](../PHASES.md)

> **Scope (Nov 14).** The stroke classifier was one 1D CNN that nobody had trained: no clips, no
> features and no weights existed, and the Phase 3 gate (Nov 13) had passed. This phase makes the
> classifier a choice between three algorithms, **CNN, LSTM and Random Forest**, picked per job in
> the app, and ships trained weights for all three without the team extracting or labelling
> anything. It also collects the bugs and stale docs found in a review of `main` on Nov 14.
> Milestone "Phase 11 — Selectable stroke models", issues #134–#146.

| | |
| --- | --- |
| **Dates** | Sat Nov 14 – Tue Nov 17, 2026 (before the feature freeze on Nov 18) |
| **Goal** | A user picks CNN, LSTM or Random Forest for a clip or a live session; each has trained weights in the repo and a measured accuracy; the Nov 14 review findings are fixed with tests |
| **Owners** | M1 (backend, API, docs), M5 (models), M6 (app) |
| **Entry criteria** | Phase 10 on `main` |
| **Status** | Done Nov 14: every task below landed with tests (backend 404, app 236). Test macro accuracy on the BST split: 1D CNN 89.5% ± 1.2%, LSTM 88.1% ± 0.6%, Random Forest 82.1% ± 0.3% ([results](../results/strokes.md)). Not done here: a run on a real clip with TrackNetV3 and pose installed, and the device check of the selector, which join the T4.3 and T7.2 checks |
| **Exit gate** | Every task below is ✅; backend `pytest -m "not gpu"` and `ruff`, app `flutter analyze`, `flutter test` and `dart format` pass |

## What the research found (T11.1)

We looked for pre-trained badminton stroke classifiers that take what our pipeline already
produces (COCO-17 keypoints from RTMPose and the shuttle track from TrackNetV3).

| Candidate | What it is | Verdict |
| --- | --- | --- |
| [BST](https://github.com/Va6lue/BST-Badminton-Stroke-type-Transformer) (Badminton Stroke-type Transformer, MIT) | Transformer over both players' joints and bones, court positions and the shuttle; released weights; about 0.82 accuracy on 25 ShuttleSet classes | The only solid pre-trained model. It is not one of the three algorithms and needs inputs we do not build (bones, both players, court-normalised positions). Kept as future work |
| BST's pre-extracted ShuttleSet features (same repo, `dataset_npy.rar`, 440 MB) | RTMPose COCO-17 joints for both players and TrackNetV3 shuttle positions, 30 frames per stroke, with train / val / test splits and 25 labels | **Used.** Same pose and shuttle sources as our pipeline, so all three models can be trained on a CPU in minutes |
| TemPose | Skeleton + shuttle transformer | No official weights |
| VideoBadminton benchmark | RGB video models, 18 classes | No released checkpoints; RGB input |
| Hugging Face badminton models (VideoMAE fine-tunes, JVC, several undocumented `.pt` / `.keras` files) | RGB or MediaPipe input | Wrong input, undocumented classes, non-commercial licences, or pickled files that run code on load |
| LSTM or Random Forest stroke classifiers with weights | — | **None found** for COCO keypoints. Published LSTM and Random Forest results use small private datasets |
| Generic skeleton backbones (ST-GCN++, PoseC3D on NTU) | Action recognition | No stroke classes; useless without training |

So there is no LSTM or Random Forest to download. The three models are trained here, once, on
the public BST features, and the weight files are committed so the team does not train anything
([D28–D31](../DECISIONS.md)).

What the literature says about the three: on ShuttleSet, skeleton-only models reach about 0.77
accuracy on 25 classes and adding the shuttle trajectory lifts that to 0.82–0.83 (BST paper), which
supports our pose + shuttle features. Recurrent models and 1D CNNs perform alike on windows this
short. Random Forests need hand-made summary features (joint statistics, wrist and elbow speed,
joint angles, shuttle direction and speed before and after the hit) and usually trail the
sequence models by a few points, but they need no GPU or PyTorch at all.

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T11.1](#t111) | Research and decisions | M1 | 3 h | — | ✅ | [#134](https://github.com/Mist10148/ShuttleSense/issues/134) |
| [T11.2](#t112) | Import the BST ShuttleSet features | M5 | 4 h | T11.1 | ✅ | [#135](https://github.com/Mist10148/ShuttleSense/issues/135) |
| [T11.3](#t113) | Stroke model registry | M5 + M1 | 4 h | T3.10 | ✅ | [#136](https://github.com/Mist10148/ShuttleSense/issues/136) |
| [T11.4](#t114) | LSTM model and training | M5 | 3 h | T11.3 | ✅ | [#137](https://github.com/Mist10148/ShuttleSense/issues/137) |
| [T11.5](#t115) | Random Forest model and training | M5 | 4 h | T11.3 | ✅ | [#138](https://github.com/Mist10148/ShuttleSense/issues/138) |
| [T11.6](#t116) | Train all three, weights and comparison | M5 | 4 h | T11.2, T11.4, T11.5 | ✅ | [#139](https://github.com/Mist10148/ShuttleSense/issues/139) |
| [T11.7](#t117) | API: stroke model per job | M1 | 4 h | T11.3 | ✅ | [#140](https://github.com/Mist10148/ShuttleSense/issues/140) |
| [T11.8](#t118) | App: stroke model selector | M6 | 4 h | T11.7 | ✅ | [#141](https://github.com/Mist10148/ShuttleSense/issues/141) |
| [T11.9](#t119) | CLI `--stroke-model` | M1 | 1 h | T11.3 | ✅ | [#142](https://github.com/Mist10148/ShuttleSense/issues/142) |
| [T11.10](#t1110) | Live job fixes | M1 | 3 h | — | ✅ | [#143](https://github.com/Mist10148/ShuttleSense/issues/143) |
| [T11.11](#t1111) | API fixes | M1 | 4 h | — | ✅ | [#144](https://github.com/Mist10148/ShuttleSense/issues/144) |
| [T11.12](#t1112) | Windows re-render and test notifier | M1 + M6 | 2 h | — | ✅ | [#145](https://github.com/Mist10148/ShuttleSense/issues/145) |
| [T11.13](#t1113) | Docs sweep and link check | M1 | 3 h | — | ✅ | [#146](https://github.com/Mist10148/ShuttleSense/issues/146) |

---

<a id="t111"></a>
### T11.1 · Research and decisions

**Owner:** M1 · **Area:** docs, ml · **Priority:** P1 · **Refs:** F6, FR-6

**Goal.** Find out which pre-trained stroke models exist for the three algorithms and decide how
to get weights without team training.

**Steps**
- [x] Survey released weights and feature sets (table above).
- [x] DECISIONS: D28 (three selectable models), D29 (train on the BST features), D30 (weights in
      the repo), D31 (scikit-learn).
- [x] TECH_STACK: scikit-learn and the BST feature set, with licences.

**Acceptance criteria.** The decisions and their alternatives are recorded.

---

<a id="t112"></a>
### T11.2 · Import the BST ShuttleSet features

**Owner:** M5 · **Area:** ml, data · **Priority:** P1 · **Refs:** F6, T3.5, D29 · **Blocks:** T11.6

**Goal.** Turn the BST feature files into our training layout, so the existing dataset loader and
training script work unchanged.

**Inputs.** `dataset_npy.rar` (per split: `J_only.npy` `[N, 30, 2, 17, 2]`, `shuttle.npy`
`[N, 30, 2]`, `videos_len.npy`, `labels.npy` with 25 classes: unknown, then 12 types for the top
player, then the same 12 for the bottom player), `strokes/labels.py`, `strokes/features.py`.

**Steps**
- [x] `scripts/import_bst_features.py`: read one split folder with `allow_pickle=False`; map the 12
      merged types through `labels.map_label` (drives and unknown are left out, D12); take the
      hitter's joints from the label's Top / Bottom half; build the same 39 values per frame as
      `build_window` (34 pose values, then shuttle `x, y, visible, dx, dy`); write
      `data/features/bst_<split>.npz` with `X`, `y` and `meta`, and a splits file.
- [x] `strokes/features.py`: a `pose_norm` option. `bbox_height` is today's rule; `bbox_diag`
      divides by the box diagonal as the BST files do. One shared function derives the shuttle's
      `visible`, `dx` and `dy`, used by the importer and by inference.
- [x] The checkpoint stores `pose_norm` and `window_frames` (30), and inference reads them.

**Outputs.** `data/features/bst_{train,val,test}.npz` (not in git; 23,723, 3,821 and 3,136
windows), `configs/splits_bst.json`.

**Tests.** A small synthetic BST folder imports to the expected shapes, labels and hitter; the
importer's features equal `build_window` on the same data.

**Acceptance criteria.** The tests pass; the import of the real archive reports the class counts
per split.

**Risks.** The archive is a RAR on Google Drive. Fallback: the script takes a folder that was
extracted by hand.

---

<a id="t113"></a>
### T11.3 · Stroke model registry

**Owner:** M5 + M1 · **Area:** ml, backend · **Priority:** P1 · **Refs:** F6, FR-6, D28 · **Blocks:** T11.7

**Goal.** `stages.strokes.algorithm` chooses `cnn`, `lstm` or `rf`. Each has its own weights file
and reports itself as installed or not.

**Steps**
- [x] `strokes/registry.py`: the algorithm names, labels, weights keys (`weights`, `weights_lstm`,
      `weights_rf`) and required packages.
- [x] `strokes/classify.py`: load by algorithm; one `predict_proba` for all three; a missing file
      or package skips the stage with a message that names the model.
- [x] `configs/pipeline.yaml`: `algorithm: cnn` and one weights path per algorithm, inside
      `stages.strokes` so the stage cache notices a change.
- [x] `pipeline.py`: the strokes stage is available when the chosen algorithm is; a list of
      installed stroke models for `/health`.

**Tests.** Classify with each algorithm on the golden record; a missing weights file skips with
the right message; an unknown algorithm is refused.

**Acceptance criteria.** The tests pass and the CNN path behaves as before.

---

<a id="t114"></a>
### T11.4 · LSTM model and training

**Owner:** M5 · **Area:** ml · **Priority:** P1 · **Refs:** F6, D28

**Steps**
- [x] `strokes/model.py`: a bidirectional LSTM over the window, mean and last-step pooling,
      dropout and a linear layer.
- [x] `scripts/train_stroke_classifier.py --algorithm lstm` with `configs/stroke_lstm.yaml`; same
      loss, schedule, early stopping, seeds and checkpoint format as the CNN.

**Tests.** Forward shape; a short training run on synthetic data saves a checkpoint that
`classify` loads.

**Acceptance criteria.** The tests pass.

---

<a id="t115"></a>
### T11.5 · Random Forest model and training

**Owner:** M5 · **Area:** ml · **Priority:** P1 · **Refs:** F6, D28, D31

**Steps**
- [x] `strokes/rf.py`: summary features of a window (per-value mean, standard deviation, minimum,
      maximum and the value at the hit; wrist and elbow speed; elbow, shoulder and knee angles at
      the hit; shuttle direction and speed before and after the hit; how many frames the shuttle
      is visible).
- [x] `--algorithm rf` with `configs/stroke_rf.yaml`: scikit-learn `RandomForestClassifier`, class
      weights, depth and leaf size limited so the saved file stays small.
- [x] `Forest`: copy the trained trees into plain arrays, save them as `.npz` and predict with
      NumPy. No pickled model: loading the file cannot run code, and the server does not need
      scikit-learn.

**Tests.** Feature shape and no NaN on empty windows; the NumPy forest gives scikit-learn's
probabilities; train, save, load and classify round trip.

**Acceptance criteria.** The tests pass with scikit-learn installed in CI.

---

<a id="t116"></a>
### T11.6 · Train all three, weights and comparison

**Owner:** M5 · **Area:** ml · **Priority:** P1 · **Refs:** F6, T3.8, T3.9, T3.12, T3.14, D29, D30

**Steps**
- [x] Train CNN, LSTM and Random Forest on the BST train split with 3 seeds each; pick each
      model's best seed on the validation split.
- [x] Commit `weights/strokes/stroke_cnn.pt`, `stroke_lstm.pt` and `stroke_rf.npz`, with their
      SHA-256 values.
- [x] `scripts/make_figures.py`: a three-model table (accuracy, macro accuracy, macro F1, per-class
      F1), confusion matrices and a comparison chart in `docs/results/strokes.md`.
- [x] `scripts/bench_strokes.py`: CPU latency for each model.

**Acceptance criteria.** Each model's test-split numbers are in `docs/results/strokes.md`. The
PRD target is macro accuracy ≥ 70%; a model that misses it is reported as such.

**Result (Nov 14).** 1D CNN 89.5% ± 1.2%, LSTM 88.1% ± 0.6%, Random Forest 82.1% ± 0.3%; all three pass the target. Ablation: pose only 77.1% ± 0.1% against 89.5% ± 1.2% with the shuttle (1D CNN). The forest was
cut from 200 trees of depth 18 (13 MB) to 150 of depth 14 (6 MB) for about one point of
validation F1. CPU latency for a 1-minute clip is under 0.1 s for each model
([stroke_latency.md](../results/stroke_latency.md)).

**Risks.** The split is BST's, not `configs/splits.json`, so the numbers are not the T3.9 numbers;
T3.9 on our own clips stays open.

---

<a id="t117"></a>
### T11.7 · API: stroke model per job

**Owner:** M1 · **Area:** backend · **Priority:** P1 · **Refs:** FR-6, D28 · **Blocks:** T11.8

**Steps**
- [x] `POST /jobs` and the live `start` message take `stroke_model` (`cnn`, `lstm`, `rf`; default
      `cnn`); the job echoes it; a bad value is `422` / `bad_request`.
- [x] `JobManager.job_config` writes it to `stages.strokes.algorithm`.
- [x] `GET /health` lists `stroke_models`, the ones installed on this server.
- [x] Clip record 1.4: optional `stroke_model`, the model that labelled the hits.
- [x] API.md, DATA_FORMAT.md, `openapi.json` and the schema snapshot.

**Tests.** Create a job with each value; a bad value; the config override; `/health`; a re-render
with another model re-runs the strokes stage.

**Acceptance criteria.** The tests pass; old `job.json` files and 1.3 records still load.

---

<a id="t118"></a>
### T11.8 · App: stroke model selector

**Owner:** M6 · **Area:** app · **Priority:** C · **Refs:** C-upload, C-live

**Steps**
- [x] Upload options: a three-way "Stroke model" choice (CNN, LSTM, Random Forest), remembered
      between sessions; a model the server does not have is disabled with "Not installed on this
      server".
- [x] `JobOptions`, `Job.fromJson`, `createJob`, the live start message and retry carry it.
- [x] Results show which model labelled the strokes.

**Tests.** The selector sends the chosen value; a missing model is disabled; an old server
(no `stroke_models`) hides the choice.

**Acceptance criteria.** `flutter analyze`, `flutter test` and `dart format` pass. The device
check joins the T4.3 checks.

---

<a id="t119"></a>
### T11.9 · CLI `--stroke-model`

**Owner:** M1 · **Area:** backend · **Refs:** FR-6

**Steps**
- [x] `shuttlesense --stroke-model cnn|lstm|rf`, written to the same config key.

**Tests.** The flag reaches the stage config.

---

<a id="t1110"></a>
### T11.10 · Live job fixes

**Owner:** M1 · **Area:** backend · **Priority:** P3 · **Refs:** T8.6, D24

**Steps**
- [x] A server restart while a saved live session renders left a job marked done that the app
      could not open: on startup, set the job's outputs from the files on disk, and mark a live
      job with no video as failed with "render interrupted".
- [x] Deleting a live job during its render now stops the render, and its id no longer stays in
      the cancelled set.

**Tests.** One per step in `tests/test_live.py` / `tests/test_api.py`.

---

<a id="t1111"></a>
### T11.11 · API fixes

**Owner:** M1 · **Area:** backend · **Priority:** P3

**Steps**
- [x] Coach chat: the question limit is checked again once the answer slot is taken, so two
      requests at the limit cannot both pass, and the second sees the first one's answer.
- [x] `POST /jobs/{id}/score/award`: a negative frame is `422` and a frame past the clip is `400`.
- [x] The access log no longer shows the `token` query value (a filter on uvicorn's loggers;
      tested on constructed log records, not against a running server).
- [x] Per-job locks are removed when the job is deleted.

**Tests.** One per step.

---

<a id="t1112"></a>
### T11.12 · Windows re-render and test notifier

**Owner:** M1 + M6 · **Area:** backend, app

**Steps**
- [x] `atomic.py`: replacing the annotated video waits up to 15 s when a player still has the old
      file open on Windows; a player that holds it longer still fails the render.
- [x] App tests use a fake job notifier, so the real notifications plugin is not called.

**Tests.** A replace that fails several times and then succeeds; the processing-screen tests print
no plugin error.

---

<a id="t1113"></a>
### T11.13 · Docs sweep and link check

**Owner:** M1 · **Area:** docs

**Steps**
- [x] README, SETUP, ARCHITECTURE, PRD, EVALUATION and `docs/results/README.md` describe the three
      models, how to pick one and how to retrain them.
- [x] Stale lines: the hitter rule in T3.5 (D14); the form-feedback owner; Phase 10 owners; the
      order of the decision log; superseded text in Phase 8; `Phase: 0–11` in the issue template;
      the `make_splits.py` command in SETUP; the training command in README and SETUP; 5 or 10
      early matches; the polling interval; commit scopes in CONTRIBUTING; issue links in Phase 9.
- [x] `scripts/check_links.py`: every relative Markdown link and anchor resolves; run in CI.

**Acceptance criteria.** The link check passes; no doc contradicts the code on these points.

## Gate checklist

- [ ] A real clip analysed three times, once per model, gives three records whose `stroke_model`
      differs and whose perception stages came from the cache. *Open: needs TrackNetV3 and pose
      weights on the server. Checked so far: each model classifies the golden record, a fake-pipeline
      job per model stores its `stroke_model`, and only the strokes cache key changes.*
- [x] `/health` lists the three models with the committed weights installed.
- [x] `docs/results/strokes.md` has the three-model table.
- [x] Backend and app checks pass.

## Risks across the phase

| Risk | Effect | Fallback |
| --- | --- | --- |
| The BST features differ from our own pipeline's output (broadcast footage, another pose build) | Lower accuracy on phone clips | The phone-footage evaluation (T7.2) measures it; retrain on our own clips when T3.1–T3.5 are done, with the same script |
| The archive cannot be downloaded or extracted | No weights | The code, selector and training script still ship; models without weights are disabled in the app |
| A pickled model runs code when loaded | Unsafe weights | Torch checkpoints load with `weights_only=True`; the forest is plain arrays loaded with `allow_pickle=False` |
| Weights in git grow the repo | Slow clones | The three files are small; larger weights stay on Hugging Face (D4) |
