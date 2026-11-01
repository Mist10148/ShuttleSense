# Phase 0 — Project setup

[← Phase overview](../PHASES.md) · Next: [Phase 1 — Foundations →](phase-1-foundations.md)

| | |
| --- | --- |
| **Dates** | Thu Oct 29 – Sun Nov 1, 2026 |
| **Goal** | A repo every member can clone, run, test and contribute to, with the team's working agreements in place |
| **Owners** | M1 (lead) for repo work; every member for their own environment |
| **Entry criteria** | PRD v1.0 and README drafts exist |
| **Exit gate** | Every member has (1) passing `pytest` in `backend/`, (2) the app running on their own device, (3) access to the board, Drive and Hugging Face |
| **Milestone** | `Phase 0 — Project setup` (due Nov 1) |

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T0.1](#t01) | Repo structure and single root README | M1 | 3 h | — | ✅ | [#1](https://github.com/Mist10148/ShuttleSense/issues/1) |
| [T0.2](#t02) | Refined PRD and design docs | M1 | 6 h | T0.1 | ✅ | [#2](https://github.com/Mist10148/ShuttleSense/issues/2) |
| [T0.3](#t03) | Backend skeleton with stub stages, API and tests | M1 | 6 h | T0.1 | ✅ | [#3](https://github.com/Mist10148/ShuttleSense/issues/3) |
| [T0.4](#t04) | Flutter skeleton with responsive shell and screens | M1 | 6 h | T0.1 | ✅ | [#4](https://github.com/Mist10148/ShuttleSense/issues/4) |
| [T0.5](#t05) | CI workflows, issue and PR templates | M1 | 2 h | T0.3, T0.4 | ✅ | [#5](https://github.com/Mist10148/ShuttleSense/issues/5) |
| [T0.6](#t06) | GitHub project board, labels, milestones, issues | M1 | 2 h | T0.5 | ⬜ | [#6](https://github.com/Mist10148/ShuttleSense/issues/6) |
| [T0.7](#t07) | Protect `main` | M1 | 0.5 h | T0.5 | ⬜ | [#7](https://github.com/Mist10148/ShuttleSense/issues/7) |
| [T0.8](#t08) | Every member sets up backend + app locally | All | 3 h each | T0.3, T0.4 | ⬜ | [#8](https://github.com/Mist10148/ShuttleSense/issues/8) |
| [T0.9](#t09) | Hugging Face weights repo and Google Drive data folder | M1 | 1 h | — | ⬜ | [#9](https://github.com/Mist10148/ShuttleSense/issues/9) |
| [T0.10](#t010) | Record 2 consented test rallies | M4 | 2 h | — | ⬜ | [#10](https://github.com/Mist10148/ShuttleSense/issues/10) |
| [T0.11](#t011) | Environment check script | M1 | 2 h | T0.3 | ✅ | [#11](https://github.com/Mist10148/ShuttleSense/issues/11) |
| [T0.12](#t012) | Team working agreements | M1 | 1 h | — | ⬜ | [#12](https://github.com/Mist10148/ShuttleSense/issues/12) |

---

<a id="t01"></a>
### T0.1 · Repo structure and single root README

**Owner:** M1 · **Estimate:** 3 h · **Priority:** P1 · **Area:** docs · **Refs:** — · **Depends on:** — · **Blocks:** T0.2, T0.3, T0.4

**Goal.** Monorepo layout with `app/`, `backend/`, `docs/`, `samples/` and exactly one README.

**Steps**
- [x] Create `backend/`, `app/`, `docs/`, `samples/` and gitignored `backend/{data,weights,outputs,storage}/` with `.gitkeep`.
- [x] Extend `.gitignore` for Flutter, datasets, weights, videos (`*.mp4`, `*.pt`, `*.onnx`); re-include `app/lib/` and the Windows runner manifest.
- [x] Add `LICENSE` (MIT) and `.gitattributes` (LF, binary assets).
- [x] Merge the two README drafts into the root `README.md`; delete generated sub-READMEs.

**Outputs.** Repository layout described in the README "Repository structure" section.

**Acceptance criteria.** `git ls-files | grep -i readme` prints only `README.md`.

---

<a id="t02"></a>
### T0.2 · Refined PRD and design docs

**Owner:** M1 · **Estimate:** 6 h · **Priority:** P1 · **Area:** docs · **Refs:** — · **Depends on:** T0.1 · **Blocks:** T1.1, T1.2

**Goal.** Docs that reflect the Flutter client + Python backend split.

**Steps**
- [x] `docs/PRD.md` v1.1: client features C1–C4, NFRs for platforms/network/security, resolved open questions.
- [x] `docs/ARCHITECTURE.md`, `docs/DATA_FORMAT.md`, `docs/API.md`, `docs/TECH_STACK.md`, `docs/SETUP.md`, `CONTRIBUTING.md`.
- [x] Phase plan (this folder).

**Acceptance criteria.** Every PRD feature F1–F17 and C1–C4 maps to at least one task in `docs/phases/`.

---

<a id="t03"></a>
### T0.3 · Backend skeleton with stub stages, API and tests

**Owner:** M1 · **Estimate:** 6 h · **Priority:** P1 · **Area:** backend · **Refs:** NFR Modularity · **Depends on:** T0.1 · **Blocks:** T0.5, T0.8, T1.1, T1.2

**Goal.** A runnable package where every stage exists as `run(record, ctx) -> record` and the API serves the stub pipeline.

**Steps**
- [x] `backend/shuttlesense/schema.py` (ClipRecord v1.0), `stage.py` (`StageContext`, `StageSkipped`), `pipeline.py` (`STAGES`, `plan_stages`, `run_pipeline`), `run.py` (CLI).
- [x] Stage stubs in `io/ tracking/ pose/ court/ hits/ strokes/ feedback/ analytics/ referee/ render/`, with working pure helpers: `interpolate_gaps`, `compute_homography`, `image_to_court`, `direction_changes`, `speeds_kmh`, `build_summary`, `write_exports`, `game_winner`, `map_label`, `joint_angle`.
- [x] `api/` (`main.py`, `routes.py`, `jobs.py`, `storage.py`, `settings.py`, `models.py`).
- [x] Tests: `tests/test_schema.py`, `test_api.py`, `test_court.py`, `test_logic.py`.

**Acceptance criteria.** `ruff check . && ruff format --check . && pytest` pass; `GET /health` responds.

---

<a id="t04"></a>
### T0.4 · Flutter skeleton with responsive shell and screens

**Owner:** M1 · **Estimate:** 6 h · **Priority:** C · **Area:** app · **Refs:** C1–C3 · **Depends on:** T0.1 · **Blocks:** T0.5, T0.8, T1.8

**Goal.** One Flutter app for Android, iOS, Web, Windows with routing, theming, adaptive navigation and screens wired to the API.

**Steps**
- [x] `flutter create --platforms=android,ios,web,windows`; Android `INTERNET` + cleartext, iOS local-network + photo strings.
- [x] `lib/core/` (server config, router, theme, `Breakpoints`, `AdaptiveShell`), `lib/data/` (`ApiClient`, models, providers), `lib/features/*` screens.
- [x] Tests: `test/models_test.dart`, `test/responsive_test.dart`.

**Acceptance criteria.** `flutter analyze` clean, `flutter test` green, `flutter build web` succeeds.

---

<a id="t05"></a>
### T0.5 · CI workflows, issue and PR templates

**Owner:** M1 · **Estimate:** 2 h · **Priority:** P1 · **Area:** infra · **Refs:** — · **Depends on:** T0.3, T0.4 · **Blocks:** T0.6, T0.7

**Steps**
- [x] `.github/workflows/backend-ci.yml`: Python 3.12, base + dev deps, ruff, pytest.
- [x] `.github/workflows/app-ci.yml`: Flutter 3.41.6, format check, analyze, test, web build.
- [x] PR template and task/bug issue templates.

**Acceptance criteria.** Both workflows green on `main`.

---

<a id="t06"></a>
### T0.6 · GitHub project board, labels, milestones, issues

**Owner:** M1 · **Estimate:** 2 h · **Priority:** P1 · **Area:** infra · **Refs:** — · **Depends on:** T0.5 · **Blocks:** —

**Goal.** Every task in `docs/phases/` is a GitHub issue that the team can filter by phase, owner and area.

**Inputs.** The task cards in `docs/phases/*.md`.

**Steps**
- [ ] Create labels: `phase-0` … `phase-7`, `P1`, `P2`, `P3`, `client`, `backend`, `app`, `data`, `ml`, `docs`, `infra`, `owner:M1` … `owner:M6`.
- [ ] Create one milestone per phase with the due dates from [the overview](../PHASES.md#timeline).
- [ ] Create one issue per task card (title `[Tx.y] <title>`, body = card, labels, milestone); close T0.1–T0.5.
- [ ] Grant the board scope once: `gh auth refresh -s project`, then create a Projects board "ShuttleSense build" with columns **Todo / In progress / In review / Done** and add all issues (`gh project item-add`).
- [ ] When teammates share their GitHub usernames, replace `owner:Mx` labels with real assignees.
- [x] Put issue numbers into the phase task tables.

**Outputs.** Labels, 9 milestones (phases 0–8), one issue per task, board. Phases 0–7 are done (issues #1–#96); the Phase 8 milestone, `phase-8` label and T8.x issues are still to create.

**Acceptance criteria.** `gh issue list --state all --limit 200` count equals the number of task cards; every issue has a phase label, owner label and milestone.

---

<a id="t07"></a>
### T0.7 · Protect `main`

**Owner:** M1 · **Estimate:** 0.5 h · **Priority:** P1 · **Area:** infra · **Refs:** — · **Depends on:** T0.5 · **Blocks:** —

**Steps**
- [ ] Settings → Branches → add rule for `main`: require a PR, 1 approving review, status checks `backend / test` and `app / test`, linear history (squash merge only).
- [ ] Settings → General: allow squash merging only; auto-delete head branches.
- [ ] Note: on a private repo with a free plan, branch protection may require GitHub Pro or making the repo public; if unavailable, agree in T0.12 that nobody pushes to `main` directly.

**Acceptance criteria.** `git push origin main` from a member's machine is rejected (or the manual rule is recorded in T0.12).

---

<a id="t08"></a>
### T0.8 · Every member sets up backend + app locally

**Owner:** All (M1–M6) · **Estimate:** 3 h each · **Priority:** P1 · **Area:** infra · **Refs:** — · **Depends on:** T0.3, T0.4 · **Blocks:** Phase 1

**Goal.** No one loses Week 1 to environment problems.

**Steps**
- [ ] Follow [SETUP.md](../SETUP.md) sections 1–3 and 7: clone, venv, `pip install -r requirements/base.txt -r requirements/dev.txt`, `pip install -e .`.
- [ ] Run `python scripts/check_env.py` (T0.11) and fix anything red.
- [ ] `pytest` and `ruff check .` in `backend/`.
- [ ] `flutter doctor`, then `flutter test` and `flutter run` on your own device (phone, Chrome or Windows).
- [ ] Start the backend on one laptop with `--host 0.0.0.0` and connect your phone to it ([SETUP.md §8](../SETUP.md#8-connecting-a-phone-or-tablet-to-the-laptop)).
- [ ] Members with an NVIDIA GPU: install the CUDA build of torch and confirm `torch.cuda.is_available()`.
- [ ] Post a screenshot (connected app + passing tests) in the team chat.

**Acceptance criteria.** Six screenshots posted; problems and fixes added to SETUP.md "Troubleshooting".

---

<a id="t09"></a>
### T0.9 · Hugging Face weights repo and Google Drive data folder

**Owner:** M1 · **Estimate:** 1 h · **Priority:** P1 · **Area:** infra · **Refs:** NFR Reproducibility · **Depends on:** — · **Blocks:** T1.4, T3.1, T3.2

**Steps**
- [ ] Create a Hugging Face organization or user model repo (private) for weights; set its id in `backend/scripts/download_weights.py` (`HF_REPO`).
- [ ] Add every member as a collaborator; each member runs `huggingface-cli login` with a read token.
- [ ] Create a Google Drive shared folder `ShuttleSense/` with `shuttleset/`, `videos/`, `clips/`, `features/`, `samples/`, `labels/`, `results/`; share with the team (Editor).
- [ ] Record both links in [SETUP.md §5–6](../SETUP.md#5-weights) and pin them in the team chat.

**Acceptance criteria.** Every member can open both locations.

---

<a id="t010"></a>
### T0.10 · Record 2 consented test rallies

**Owner:** M4 · **Estimate:** 2 h · **Priority:** P1 · **Area:** data · **Refs:** Data, Ethics · **Depends on:** — · **Blocks:** T1.5, T2.1, T7.1

**Goal.** Real phone footage for every early test.

**Steps**
- [ ] Get written or recorded verbal consent from every person in frame (template in the Drive `samples/` folder).
- [ ] Phone on a tripod, elevated (≥ 2 m if possible) behind one baseline, landscape, 1080p 30 or 60 fps, whole court in frame.
- [ ] Record two rallies of 20–60 s each; one should include a smash and a net exchange.
- [ ] Upload to Drive `samples/` as `rally01.mp4`, `rally02.mp4`; note camera position and fps in `samples/notes.md` on Drive.

**Acceptance criteria.** Two clips on Drive, each fully showing all four court corners.

**Risks.** Gym lighting flicker at 60 fps: prefer 30 fps if flicker is visible.

---

<a id="t011"></a>
### T0.11 · Environment check script

**Owner:** M1 · **Estimate:** 2 h · **Priority:** P2 · **Area:** infra · **Refs:** NFR Reproducibility · **Depends on:** T0.3 · **Blocks:** T0.8

**Goal.** One command that tells a member what is missing.

**Steps**
- [x] Add `backend/scripts/check_env.py` that prints ✓/✗ for: Python ≥ 3.11; packages in `requirements/base.txt` importable at the pinned versions; optional ML packages (`torch`, `onnxruntime`, `rtmlib`) with CUDA availability; `ffmpeg -version`; weights files from `download_weights.FILES`; TrackNetV3 submodule present; free disk space ≥ 20 GB.
- [x] Exit code 0 when the base stack is OK even if optional ML pieces are missing.
- [x] Mention it in SETUP.md §3.

**Tests.** `tests/test_check_env.py::test_runs_and_reports_python` (runs `main()` with a captured stdout and asserts the Python line).

**Acceptance criteria.** Running on a fresh venv with base deps prints no ✗ in the base section.

---

<a id="t012"></a>
### T0.12 · Team working agreements

**Owner:** M1 · **Estimate:** 1 h · **Priority:** P1 · **Area:** docs · **Refs:** — · **Depends on:** — · **Blocks:** —

**Steps**
- [ ] Agree on a daily 10-minute async stand-up in the team chat (yesterday / today / blocked) and a 30-minute sync on Mon, Wed, Fri.
- [ ] Phase gate review at the end of each phase (demo script in each phase file).
- [ ] Review rule: PRs reviewed within 24 h; the lead reviews anything touching `schema.py`, `api/` or `app/lib/data/`.
- [x] Record the agreements in CONTRIBUTING.md under a new "Team rhythm" section.

**Acceptance criteria.** Section merged; first stand-up posted on Nov 2.

---

## Phase gate checklist (Nov 1)

1. Show `gh issue list --milestone "Phase 1 — Foundations"`.
2. Each member shows the app connected to a backend on their device.
3. Confirm Drive and Hugging Face access for all six members.
4. Confirm the two consented test clips are on Drive.
