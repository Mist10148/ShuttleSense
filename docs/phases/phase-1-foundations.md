# Phase 1 — Foundations

[← Phase 0](phase-0-setup.md) · [Phase overview](../PHASES.md) · Next: [Phase 2 — P1 perception →](phase-2-perception.md)

| | |
| --- | --- |
| **Dates** | Mon Nov 2 – Tue Nov 3, 2026 |
| **Goal** | Freeze the two contracts (clip record, API) and prove that the pretrained perception models run on the team's hardware |
| **Owners** | M1 (contracts, environments), M2 (TrackNetV3), M5 (pose spike), M6 (app connectivity), M3 (ShuttleSet download) |
| **Entry criteria** | Phase 0 exit gate passed |
| **Exit gate** | Tags `schema-v1.0` and `api-v1.0` exist; TrackNetV3 and the chosen pose model each produce output on `rally01.mp4`; the app reaches `/health` from all four platform types |
| **Milestone** | `Phase 1 — Foundations` (due Nov 3) |

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T1.1](#t11) | Freeze clip record v1.0 | M1 + all | 4 h | T0.3 | ⬜ | [#13](https://github.com/Mist10148/ShuttleSense/issues/13) |
| [T1.2](#t12) | Freeze API contract v1.0 | M1 + M6 | 3 h | T0.3, T0.4 | ⬜ | [#14](https://github.com/Mist10148/ShuttleSense/issues/14) |
| [T1.3](#t13) | Add TrackNetV3 as a pinned git submodule | M2 | 2 h | — | ⬜ | [#15](https://github.com/Mist10148/ShuttleSense/issues/15) |
| [T1.4](#t14) | Weights download with checksums | M2 | 3 h | T1.3, T0.9 | ⬜ | [#16](https://github.com/Mist10148/ShuttleSense/issues/16) |
| [T1.5](#t15) | Pose model spike: rtmlib vs Keypoint R-CNN | M5 | 6 h | T0.10 | ⬜ | [#17](https://github.com/Mist10148/ShuttleSense/issues/17) |
| [T1.6](#t16) | Install and pin the ML stack on laptop and Colab | M1 | 4 h | — | ⬜ | [#18](https://github.com/Mist10148/ShuttleSense/issues/18) |
| [T1.7](#t17) | Colab backend reachable through a tunnel | M1 | 3 h | T0.3, T1.6 | ⬜ | [#19](https://github.com/Mist10148/ShuttleSense/issues/19) |
| [T1.8](#t18) | App connects on Android, tablet, Windows, Chrome | M6 | 4 h | T0.4 | ⬜ | [#20](https://github.com/Mist10148/ShuttleSense/issues/20) |
| [T1.9](#t19) | Download ShuttleSet annotations and match list | M3 | 5 h | — | ⬜ | [#21](https://github.com/Mist10148/ShuttleSense/issues/21) |
| [T1.10](#t110) | Test fixture clip and golden record | M1 | 3 h | T1.1 | ✅ | [#22](https://github.com/Mist10148/ShuttleSense/issues/22) |
| [T1.11](#t111) | Decision log | M1 | 1 h | — | ✅ | [#23](https://github.com/Mist10148/ShuttleSense/issues/23) |

---

<a id="t11"></a>
### T1.1 · Freeze clip record v1.0

**Owner:** M1 + all · **Estimate:** 4 h · **Priority:** P1 · **Area:** backend · **Refs:** NFR Modularity · **Depends on:** T0.3 · **Blocks:** T1.10, T2.1, T2.4, T3.6, T5.2, every stage task

**Goal.** Everyone agrees on the exact shape of the shared record so stages can be built in parallel without breaking each other.

**Inputs.** [DATA_FORMAT.md](../DATA_FORMAT.md), `backend/shuttlesense/schema.py`, `app/lib/data/models/clip_record.dart`.

**Steps**
- [ ] 30-minute review meeting: each stage owner confirms the fields their stage fills (table in [ARCHITECTURE.md §2](../ARCHITECTURE.md#stage-ownership)) and the fields they read.
- [ ] Decide open details and record them in DATA_FORMAT.md: keypoint score threshold for "missing" joints, whether `frames[]` holds every frame or only processed ones after fps normalization (proposal: every normalized frame), court corner order (already defined).
- [ ] Apply agreed changes to `schema.py` and to the Dart mirror `clip_record.dart` in one PR.
- [ ] Add `tests/test_schema.py::test_json_schema_snapshot` that dumps `ClipRecord.model_json_schema()` and compares it to `backend/tests/fixtures/clip_record.schema.json`, so accidental schema changes fail CI.
- [ ] Merge, then tag: `git tag schema-v1.0 && git push origin schema-v1.0`.

**Outputs.** Frozen `schema.py`, schema snapshot file, tag `schema-v1.0`.

**Tests.** `test_json_schema_snapshot`; existing `test_example_from_docs_round_trips`; `app/test/models_test.dart` still passes.

**Acceptance criteria.** All six members approved the PR; CI green; tag pushed.

**Risks.** Later changes are inevitable: follow the change policy in DATA_FORMAT.md (bump `schema_version`, update snapshot, Dart models, doc and tests together).

---

<a id="t12"></a>
### T1.2 · Freeze API contract v1.0

**Owner:** M1 + M6 · **Estimate:** 3 h · **Priority:** P1 · **Area:** backend · **Refs:** C1–C4 · **Depends on:** T0.3, T0.4 · **Blocks:** T4.1–T4.8

**Goal.** The app team can build every screen against a contract that will not move.

**Steps**
- [ ] Walk through [API.md](../API.md) with M6 endpoint by endpoint against `ApiClient` in `app/lib/data/api_client.dart`; list mismatches.
- [ ] Decide on `GET /health.stages` semantics (only stages whose dependencies and weights are installed) and implement it in `routes.py::health` using a new `pipeline.available_stages()` that tries the lazy imports and checks weight files.
- [ ] Export the OpenAPI document: `python -c "import json; from shuttlesense.api.main import app; print(json.dumps(app.openapi(), indent=2))" > docs/openapi.json`.
- [ ] Add `tests/test_api.py::test_openapi_snapshot` comparing `app.openapi()` with `docs/openapi.json`.
- [ ] Merge and tag `api-v1.0`.

**Outputs.** `docs/openapi.json`, snapshot test, `available_stages()`, tag `api-v1.0`.

**Tests.** `test_openapi_snapshot`; `test_health` updated to accept a subset of stages.

**Acceptance criteria.** No mismatch left between API.md, `routes.py` and `api_client.dart`; tag pushed.

---

<a id="t13"></a>
### T1.3 · Add TrackNetV3 as a pinned git submodule

**Owner:** M2 · **Estimate:** 2 h · **Priority:** P1 · **Area:** ml · **Refs:** F2 · **Depends on:** — · **Blocks:** T1.4, T2.2

**Steps**
- [ ] `git submodule add https://github.com/qaz812345/TrackNetV3 backend/third_party/TrackNetV3`.
- [ ] Check out the latest tagged/stable commit; record the commit hash and the upstream license (MIT) in TECH_STACK.md.
- [ ] Read the upstream `predict.py` and note: expected input size, sequence length, how `TrackNet` and `InpaintNet` are constructed, the output CSV format. Write these notes as a module docstring in `backend/shuttlesense/tracking/tracknet.py`.
- [ ] Make it importable without modifying upstream code: in `tracknet.py`, add `_tracknet_path()` that inserts `backend/third_party/TrackNetV3` into `sys.path` lazily.
- [ ] Update `actions/checkout` in both workflows with `submodules: recursive` (backend CI only needs the code, not weights).

**Outputs.** Submodule at a pinned commit; integration notes.

**Acceptance criteria.** Fresh `git clone --recurse-submodules` contains the TrackNetV3 sources; `git submodule status` shows the pinned hash.

---

<a id="t14"></a>
### T1.4 · Weights download with checksums

**Owner:** M2 · **Estimate:** 3 h · **Priority:** P1 · **Area:** ml · **Refs:** F2, NFR Reproducibility · **Depends on:** T1.3, T0.9 · **Blocks:** T2.2

**Steps**
- [ ] Download TrackNetV3's released checkpoints (`TrackNet_best.pt`, `InpaintNet_best.pt`) from the upstream README links.
- [ ] Upload them to the team Hugging Face repo under `tracknet/`; compute SHA-256 for each.
- [ ] In `backend/scripts/download_weights.py`, add a `CHECKSUMS = {path: sha256}` dict and verify after each download (delete and fail on mismatch).
- [ ] Add `--force` to re-download.
- [ ] Document the expected layout in SETUP.md §5 (already listed) and the source/licence of the weights in TECH_STACK.md.

**Tests.** `tests/test_download_weights.py::test_checksum_mismatch_raises` using a temp file and a monkeypatched `hf_hub_download`.

**Acceptance criteria.** On a fresh clone, `python scripts/download_weights.py --only tracknet` produces both files with matching checksums.

---

<a id="t15"></a>
### T1.5 · Pose model spike: rtmlib vs Keypoint R-CNN

**Owner:** M5 · **Estimate:** 6 h · **Priority:** P1 · **Area:** ml · **Refs:** F3, F4 · **Depends on:** T0.10 · **Blocks:** T2.4, T2.5

**Goal.** Choose the pose backend with numbers, not guesses.

**Inputs.** `samples/rally01.mp4`, `rally02.mp4`; laptop RTX 4050; Colab T4.

**Steps**
- [ ] Create `backend/notebooks/pose_spike.ipynb` (kept in repo; outputs cleared before commit).
- [ ] rtmlib: `from rtmlib import Body; body = Body(mode="balanced", backend="onnxruntime", device="cuda")`; run on every frame of both clips; collect boxes, keypoints, scores and time per frame.
- [ ] torchvision: `keypointrcnn_resnet50_fpn(weights="DEFAULT")` in eval mode on CUDA, same clips, same metrics.
- [ ] For each: fps on RTX 4050 and T4; % of frames where both players are detected; visual check of 30 random frames (far player is the hard case); behaviour with motion blur during smashes.
- [ ] Also try rtmlib `mode="performance"` if the far player is often missed.
- [ ] Write the decision with a results table in TECH_STACK.md ("Pose spike results") and set `configs/pipeline.yaml stages.pose.backend` and `mode`. Both backends already run in the pipeline (`rtmlib`, `keypoint_rcnn`), so the switch is that one config line.

**Outputs.** Notebook, results table, config default.

**Acceptance criteria.** The chosen model detects both players in ≥ 90% of frames on both clips and runs ≥ 10 fps on the T4 (so pose fits in the 5-minute budget for a 1-minute clip).

**Risks.** If neither reaches 90% for the far player: run pose on an upscaled crop of the far half of the court (note for T2.4).

---

<a id="t16"></a>
### T1.6 · Install and pin the ML stack on laptop and Colab

**Owner:** M1 · **Estimate:** 4 h · **Priority:** P1 · **Area:** infra · **Refs:** NFR Reproducibility · **Depends on:** — · **Blocks:** T1.7, T2.2

**Steps**
- [ ] Laptop (Windows, RTX 4050): install the CUDA torch wheel per [SETUP.md §3](../SETUP.md#3-backend-on-a-laptop-primary), then `pip install -r requirements/ml.txt`.
- [ ] Colab: run the notebook's install cell; note Colab's preinstalled torch/CUDA versions.
- [ ] Fix any pins in `requirements/ml.txt` that fail on either platform (`onnxruntime-gpu` must match the CUDA major version that torch uses).
- [ ] Verify: `python -c "import torch, onnxruntime as ort, rtmlib; print(torch.cuda.is_available(), ort.get_available_providers())"` shows CUDA on both.
- [ ] Record the working combination (Python, torch, CUDA, onnxruntime) in TECH_STACK.md.

**Acceptance criteria.** The verify command prints `True` and includes `CUDAExecutionProvider` on both machines.

---

<a id="t17"></a>
### T1.7 · Colab backend reachable through a tunnel

**Owner:** M1 · **Estimate:** 3 h · **Priority:** P1 · **Area:** infra · **Refs:** C1, NFR Security · **Depends on:** T0.3, T1.6 · **Blocks:** T7.11

**Steps**
- [ ] Run `backend/notebooks/shuttlesense_colab.ipynb` end to end on a T4; fix install or path problems.
- [ ] Confirm `scripts/serve_colab.py` prints the `trycloudflare.com` URL; if the regex misses (cloudflared output changes), update it.
- [ ] From a phone on **mobile data** (not Wi-Fi): connect the app with the URL and token, upload `rally01.mp4`, see the stub job finish.
- [ ] Confirm requests without the token get 401.

**Acceptance criteria.** Full stub flow works from a phone on mobile data through the tunnel; 401 without token.

---

<a id="t18"></a>
### T1.8 · App connects on Android, tablet, Windows, Chrome

**Owner:** M6 · **Estimate:** 4 h · **Priority:** C · **Area:** app · **Refs:** C1, FR-C1 · **Depends on:** T0.4 · **Blocks:** Phase 4

**Steps**
- [ ] Backend on the laptop with `--host 0.0.0.0`, firewall rule from [SETUP.md §8](../SETUP.md#8-connecting-a-phone-or-tablet-to-the-laptop).
- [ ] Android phone: `flutter run -d <id>`; connect with `http://<laptop-ip>:8000`.
- [ ] Android tablet or a tablet emulator (Pixel Tablet AVD).
- [ ] Windows: `flutter run -d windows` (needs Visual Studio C++ workload).
- [ ] Chrome: `flutter run -d chrome`; confirm CORS works.
- [ ] iOS/iPad only if a Mac is available; otherwise mark as not tested.
- [ ] Upload a clip and finish a stub job on each.

**Outputs.** Screenshot per platform in the PR; any platform fixes (manifest, permissions).

**Acceptance criteria.** Connected + stub job done on Android phone, tablet, Windows and Chrome.

---

<a id="t19"></a>
### T1.9 · Download ShuttleSet annotations and match list

**Owner:** M3 · **Estimate:** 5 h · **Priority:** P1 · **Area:** data · **Refs:** Data, F6 · **Depends on:** — · **Blocks:** T3.1, T3.2, T3.3

**Steps**
- [ ] Locate the official ShuttleSet release (KDD 2023 paper, arXiv 2306.04948) and its repository; confirm the URL in `backend/scripts/download_shuttleset.py` (`SHUTTLESET_REPO`) and the license/terms.
- [x] Implement `download_shuttleset.py`: fetch only the ShuttleSet folder (GitHub API + raw files; git cannot check the repo out on Windows) into `backend/data/shuttleset/`.
- [x] Write `data/shuttleset/match_list.csv`: `match_id, video, video_url, players, duration_min, num_rallies, num_strokes` (`video` is the file name `extract_clips.py` looks for in `data/videos/`).
- [x] Print the set of distinct stroke type names found in the annotations (input for T3.3) and the per-type counts (19 types, 36,484 strokes on 2026-10-30).
- [ ] Upload the annotations folder to Drive `shuttleset/`.

**Outputs.** Working script, `match_list.csv`, stroke-type count table posted on the issue.

**Acceptance criteria.** 44 matches listed; stroke counts total ≈ 36,492 (the released CSVs hold 36,484).

**Risks.** Match videos are on YouTube and not redistributable: only download for research use, keep them in Drive `videos/` (team only), never in the repo.

---

<a id="t110"></a>
### T1.10 · Test fixture clip and golden record

**Owner:** M1 · **Estimate:** 3 h · **Priority:** P2 · **Area:** backend · **Refs:** NFR Reproducibility · **Depends on:** T1.1 · **Blocks:** T2.8, T4.5

**Goal.** Stage owners and the app can test against a realistic record without a GPU.

**Steps**
- [x] Add `backend/tests/fixtures/golden_record.json`: a hand-written 60-frame record with shuttle positions, two players with 17 keypoints, 3 hits with strokes, court corners, positions and speeds (values plausible, not real).
- [x] Add `tests/test_schema.py::test_golden_record_valid`.
- [x] Add a `--fake` flag to `shuttlesense.run` and an env var `SHUTTLESENSE_FAKE_PIPELINE=1` for the API that returns the golden record (scaled to the uploaded clip's frame count) so the app can show non-empty results.
- [x] Copy the same JSON to `app/test/fixtures/golden_record.json` and parse it in `models_test.dart`.

**Tests.** `test_golden_record_valid`, `test_api.py::test_fake_pipeline_returns_hits`, `models_test.dart: parses golden record`.

**Acceptance criteria.** With the fake pipeline on, the app's results screen shows 3 timeline rows and minimap dots.

---

<a id="t111"></a>
### T1.11 · Decision log

**Owner:** M1 · **Estimate:** 1 h · **Priority:** P2 · **Area:** docs · **Refs:** — · **Depends on:** — · **Blocks:** —

**Steps**
- [x] Create `docs/DECISIONS.md` with a table: date, decision, alternatives, reason, owner.
- [x] Seed it with: Flutter client + FastAPI backend; rtmlib vs YOLO (license); polling vs WebSockets; HF Hub + Drive; schema v1.0 freeze; pose spike result (T1.5).
- [x] Link it from README "Documentation".

**Acceptance criteria.** File merged with ≥ 6 entries.

---

## Phase gate checklist (Nov 3)

1. `git tag -l "schema-v*" "api-v*"` shows both tags.
2. Run TrackNetV3 upstream `predict.py` on `rally01.mp4` and show the CSV (proves weights + env; wrapper comes in T2.2).
3. Show the pose spike results table and the chosen backend.
4. Show the app connected on Android, tablet, Windows and Chrome (screenshots).
5. Show `match_list.csv` with 44 rows.
