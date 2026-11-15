# Phase 7 — Freeze, evaluation, release

[← Phase 6](phase-6-referee.md) · [Phase overview](../PHASES.md) · Also: [Phase 8 — Live mode, line calls and coaching](phase-8-live-coach.md)

| | |
| --- | --- |
| **Dates** | Wed Nov 18 (feature freeze) – Fri Nov 20, 2026 (final demo) |
| **Goal** | Measure everything honestly, fix what breaks, ship builds for every platform, and deliver the demo, slides and write-up |
| **Owners** | All; M1 releases, M4 + M5 evaluation, M6 + M3 docs, slides and video |
| **Entry criteria** | Feature freeze declared on Nov 18: only bug fixes, evaluation and docs merge after this point |
| **Exit gate** | GitHub Release `v1.0.0` with APK, Windows zip and web build; README has no TBD; demo delivered with a backup |
| **Milestone** | `Phase 7 — Freeze, evaluation, release` (due Nov 20) |

Labelling (T7.1) can start earlier, as soon as the team clips exist.

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T7.1](#t71) | Record and label team phone footage | M4 | 8 h | T0.10 | ⬜ | [#83](https://github.com/Mist10148/ShuttleSense/issues/83) |
| [T7.2](#t72) | Evaluate on phone footage | M4 + M5 | 5 h | T7.1 | ⬜ | [#84](https://github.com/Mist10148/ShuttleSense/issues/84) |
| [T7.3](#t73) | Final ShuttleSet and system metrics | M5 | 4 h | T3.9, T3.7, T2.10, T2.9 | ⬜ | [#85](https://github.com/Mist10148/ShuttleSense/issues/85) |
| [T7.4](#t74) | End-to-end test on every platform | M1 + M6 | 5 h | freeze | ⬜ | [#86](https://github.com/Mist10148/ShuttleSense/issues/86) |
| [T7.5](#t75) | Bug-fix pass | All | 10 h | T7.4 | ⬜ | [#87](https://github.com/Mist10148/ShuttleSense/issues/87) |
| [T7.6](#t76) | Release builds and GitHub Release | M1 | 4 h | T7.5, T4.10 | ⬜ | [#88](https://github.com/Mist10148/ShuttleSense/issues/88) |
| [T7.7](#t77) | Freeze versions and tag `v1.0.0` | M1 | 1 h | T7.6 | ⬜ | [#89](https://github.com/Mist10148/ShuttleSense/issues/89) |
| [T7.8](#t78) | README final: demo media, results, limitations | M6 | 4 h | T7.2, T7.3 | ⬜ | [#90](https://github.com/Mist10148/ShuttleSense/issues/90) |
| [T7.9](#t79) | Slides and written evaluation | M6 + M3 | 8 h | T7.2, T7.3 | ⬜ | [#91](https://github.com/Mist10148/ShuttleSense/issues/91) |
| [T7.10](#t710) | Backup demo video | M6 | 3 h | T7.5 | ⬜ | [#92](https://github.com/Mist10148/ShuttleSense/issues/92) |
| [T7.11](#t711) | Demo rehearsal with fallback | All | 2 h | T7.10 | ⬜ | [#93](https://github.com/Mist10148/ShuttleSense/issues/93) |
| [T7.12](#t712) | Update docs to what actually shipped | M1 | 2 h | freeze | ⬜ | [#94](https://github.com/Mist10148/ShuttleSense/issues/94) |
| [T7.13](#t713) | License and privacy audit | M1 | 2 h | freeze | ⬜ | [#95](https://github.com/Mist10148/ShuttleSense/issues/95) |
| [T7.14](#t714) | Release checklist | M1 | 1 h | — | ✅ | [#96](https://github.com/Mist10148/ShuttleSense/issues/96) |

---

<a id="t71"></a>
### T7.1 · Record and label team phone footage

**Owner:** M4 · **Estimate:** 8 h · **Priority:** P1 · **Area:** data · **Refs:** Data, Success metrics · **Depends on:** T0.10 · **Blocks:** T6.7, T7.2

**Steps**
- [ ] Record 5–10 consented singles rallies (setup as in T0.10), at least 2 with a different camera height/angle.
- [ ] Label in `labels/<clip>.csv` (Drive): for every hit `time_s, player (near/far), stroke (6 classes)`; for every rally `start_s, end_s, winner, in/out`.
- [x] Use a simple tool: `scripts/label_clip.py` (OpenCV player with keys: space pause, ←/→ frame step, 1–6 stroke class, n/f player, r rally start/end) writing the CSV.
- [ ] Second person (M3) checks 2 clips; disagreements resolved and noted.

**Acceptance criteria.** ≥ 5 labelled clips with ≥ 100 hits total; consent recorded for every person.

---

<a id="t72"></a>
### T7.2 · Evaluate on phone footage

**Owner:** M4 + M5 · **Estimate:** 5 h · **Priority:** P1 · **Area:** ml · **Refs:** Success metrics (phone stroke ≥ 55%, count error ≤ 1, rally ≥ 80%) · **Depends on:** T7.1 · **Blocks:** T7.8, T7.9

**Steps**
- [ ] Process every labelled clip with the frozen pipeline (with calibration).
- [x] `scripts/eval_phone.py`: match predicted hits to labels (±3 frames at 30 fps), stroke accuracy on matched hits, stroke count error per rally, rally boundary accuracy (T6.7), hit F1.
- [ ] Write `docs/results/phone.md`; report even if low, and discuss the broadcast vs phone gap.

**Acceptance criteria.** Numbers in README Evaluation; gap analysis written.

---

<a id="t73"></a>
### T7.3 · Final ShuttleSet and system metrics

**Owner:** M5 · **Estimate:** 4 h · **Priority:** P1 · **Area:** ml · **Refs:** Success metrics · **Depends on:** T3.9, T3.7, T2.10, T2.9 · **Blocks:** T7.8, T7.9

**Steps**
- [ ] Re-run with frozen configs: tracking accuracy (T2.10), hit F1 (T3.7), stroke macro accuracy + ablation (T3.9), processing time (T2.9), speed sanity (T5.13).
- [ ] Fill every TBD in README "Evaluation" with values and the date/commit they were measured on.

**Acceptance criteria.** No TBD left; every number traceable to a script and a commit.

---

<a id="t74"></a>
### T7.4 · End-to-end test on every platform

**Owner:** M1 + M6 · **Estimate:** 5 h · **Priority:** P1 · **Area:** app · **Refs:** All C features, Success metrics (app coverage) · **Depends on:** feature freeze · **Blocks:** T7.5

**Steps.** Run this checklist on **Android phone, Android tablet, Windows, Chrome** (and iOS if possible), with the laptop backend and once with the Colab tunnel. Record pass/fail per cell in the PR.

| # | Check |
| --- | --- |
| 1 | Connect with URL; wrong URL and wrong token show clear errors |
| 2 | Pick and upload a 1-minute clip; cancel and retry |
| 3 | Calibrate (tap, drag, zoom); skip calibration path |
| 4 | Processing progress; cancel; failed job shows error |
| 5 | Results: video plays/seeks/fullscreen; timeline seeks; minimap moves; status strip updates |
| 6 | Form tips visible; low-confidence badge |
| 7 | Scoreboard and correction (committed scope since D17) |
| 8 | Download/share MP4, JSON, CSV |
| 9 | History: open and delete |
| 10 | Rotate device; light and dark theme; 200% text |
| 11 | Mode screen: Upload and Live; Live greyed out on a 1.0 backend |
| 12 | Live: camera permission, calibrate on a still, go live, overlay and latency, Stop saves to History, New session; drop Wi-Fi mid-session and see it resume |
| 13 | Line calls: UNCERTAIN banner, confirm / override (live and on a saved job), score follows |
| 14 | Session summary: top fixes and moment chips seek the video |
| 15 | Coach chat with a key (answer, citations, question limit) and without one (disabled with a reason) |

**Acceptance criteria.** Checklist completed; every failure has an issue labelled `bug` + `phase-7`.

---

<a id="t75"></a>
### T7.5 · Bug-fix pass

**Owner:** All · **Estimate:** 10 h (shared) · **Priority:** P1 · **Area:** infra · **Refs:** — · **Depends on:** T7.4 · **Blocks:** T7.6, T7.10

**Steps**
- [ ] Triage T7.4 bugs: P1 (blocks the demo flow) fixed now; others documented in Limitations.
- [ ] Each fix gets a regression test where possible.
- [ ] Re-run the failed checklist cells.

**Acceptance criteria.** No open P1 bugs.

---

<a id="t76"></a>
### T7.6 · Release builds and GitHub Release

**Owner:** M1 · **Estimate:** 4 h · **Priority:** P1 · **Area:** infra · **Refs:** NFR Platforms · **Depends on:** T7.5, T4.10 · **Blocks:** T7.7

**Steps**
- [ ] `flutter build apk --release` (signed), `flutter build windows --release` (zip `build/windows/x64/runner/Release/`), `flutter build web --release` (zip `build/web/`).
- [x] Optional: GitHub Actions `release.yml` on tag push that builds web + APK and attaches them.
- [ ] Create GitHub Release `v1.0.0` with the three artifacts, install notes (link to SETUP.md), known limitations and the evaluation summary.
- [ ] Install the APK on a clean phone and the Windows zip on another laptop to verify.

**Acceptance criteria.** Release page with three artifacts; each installs and connects on a clean device.

---

<a id="t77"></a>
### T7.7 · Freeze versions and tag `v1.0.0`

**Owner:** M1 · **Estimate:** 1 h · **Priority:** P1 · **Area:** infra · **Refs:** NFR Reproducibility · **Depends on:** T7.6 · **Blocks:** —

**Steps**
- [ ] Confirm `requirements/*.txt` pins match the laptop and Colab environments (`pip freeze` diff); `pubspec.lock` committed; TrackNetV3 submodule hash recorded.
- [ ] Bump `backend/pyproject.toml` and `shuttlesense/__init__.py` to `1.0.0`, `app/pubspec.yaml` to `1.0.0+1`.
- [ ] `git tag -a v1.0.0 -m "ShuttleSense 1.0.0"` and push.

**Acceptance criteria.** Tag on `main`; versions consistent across backend, app and `/health`.

---

<a id="t78"></a>
### T7.8 · README final: demo media, results, limitations

**Owner:** M6 · **Estimate:** 4 h · **Priority:** P1 · **Area:** docs · **Refs:** Docs · **Depends on:** T7.2, T7.3 · **Blocks:** —

**Steps**
- [ ] Demo GIF (≤ 10 MB) of the annotated video; screenshots of phone and laptop layouts in `docs/media/`.
- [ ] Replace the Demo placeholder; fill feature checkboxes with what shipped.
- [ ] Update Limitations with findings from T7.2 and open bugs.
- [x] Check every link in README. (Relative links checked by script on Nov 14, T10.7; recheck after the final edit.)

**Acceptance criteria.** README has no placeholders or TBD.

---

<a id="t79"></a>
### T7.9 · Slides and written evaluation

**Owner:** M6 + M3 · **Estimate:** 8 h · **Priority:** P1 · **Area:** docs · **Refs:** Goals (written evaluation) · **Depends on:** T7.2, T7.3 · **Blocks:** T7.11

**Steps**
- [ ] Slides: problem, reference demo, system architecture, dataset, models, results (ShuttleSet vs phone), ablation, live demo, limitations, future work, team.
- [ ] Written evaluation (`docs/EVALUATION.md` or the course's required format): method, datasets and splits, metrics, results tables, error analysis, threats to validity.
- [ ] Share with the team by Nov 19 for review.

**Acceptance criteria.** Both reviewed by at least two members by Nov 19 evening.

---

<a id="t710"></a>
### T7.10 · Backup demo video

**Owner:** M6 · **Estimate:** 3 h · **Priority:** P1 · **Area:** docs · **Refs:** Demo · **Depends on:** T7.5 · **Blocks:** T7.11

**Steps**
- [ ] Screen-record the full flow on a phone (connect, upload, calibrate, process, results) and on the laptop (results layout), 2–3 minutes total, with captions.
- [ ] Store on Drive and locally on the demo laptop (offline copy).

**Acceptance criteria.** Video plays offline on the demo laptop.

---

<a id="t711"></a>
### T7.11 · Demo rehearsal with fallback

**Owner:** All · **Estimate:** 2 h · **Priority:** P1 · **Area:** infra · **Refs:** Demo · **Depends on:** T7.10 · **Blocks:** —

**Steps**
- [ ] Rehearse on Nov 19 with the real network setup (phone hotspot as a fallback for venue Wi-Fi).
- [ ] Pre-process the demo clips so results open instantly; keep one clip to process live.
- [ ] Fallback order: laptop backend → Colab tunnel (notebook pre-started) → pre-processed results in History → backup video.
- [ ] Assign speaking parts and a 10-minute timing.

**Acceptance criteria.** Full rehearsal done within time; every fallback tested once.

---

<a id="t712"></a>
### T7.12 · Update docs to what actually shipped

**Owner:** M1 · **Estimate:** 2 h · **Priority:** P2 · **Area:** docs · **Refs:** — · **Depends on:** feature freeze · **Blocks:** —

**Steps**
- [ ] Move unfinished features to Future work in README and PRD.
- [ ] Flip every task status in `docs/phases/` and close or re-label GitHub issues (`wontfix` / `future`).
- [ ] Update `docs/DECISIONS.md` with late decisions. (D23–D27 added Nov 14; add any made after the freeze.)

**Acceptance criteria.** Docs and the issue tracker agree with the release.

---

<a id="t713"></a>
### T7.13 · License and privacy audit

**Owner:** M1 · **Estimate:** 2 h · **Priority:** P1 · **Area:** docs · **Refs:** NFR Licensing, NFR Privacy, Ethics · **Depends on:** feature freeze · **Blocks:** T7.6

**Steps**
- [x] List every Python and Dart dependency with its license (`pip-licenses`, `flutter pub deps` + pub.dev); confirm none is AGPL/GPL-incompatible with MIT; add a "Third-party licenses" table to TECH_STACK.md.
- [x] Confirm no videos, faces of non-consenting people, datasets or weights are committed (`git ls-files` scan for media extensions).
- [x] Confirm the backend deletes uploads on `DELETE`: `backend/tests/test_api.py::test_full_round_trip`, `test_video_deleted_during_its_job_is_removed_when_the_job_stops` and `test_storage_sweeps_leftovers_of_interrupted_deletes` (Nov 12).
- [ ] Wipe the demo server's storage after the demo.
- [x] Inspect package metadata in the isolated Windows GPU smoke environment. [ML runtime license evidence](../TECH_STACK.md#windows-ml-runtime-evidence)
- [ ] Finish the audit for the team release environment and obtain the bundled media_kit libmpv/FFmpeg corresponding source materials. See the T10.8 notes in [TECH_STACK.md](../TECH_STACK.md).

**Acceptance criteria.** Audit table merged; no media in the repo.

---

<a id="t714"></a>
### T7.14 · Release checklist

**Owner:** M1 · **Estimate:** 1 h · **Priority:** P2 · **Area:** docs · **Refs:** — · **Depends on:** — · **Blocks:** T7.6

**Steps**
- [x] Add `docs/RELEASE.md`: version bump locations, build commands per platform, signing, smoke test per artifact, release notes template, tagging.

**Acceptance criteria.** T7.6 and T7.7 are executed by following `docs/RELEASE.md` step by step.

---

## Final demo checklist (Nov 20)

1. Backend running on the laptop; Colab notebook started as standby; hotspot ready.
2. App installed on the demo phone and tablet; Windows build on the laptop.
3. Pre-processed clips in History; one fresh clip ready to upload live.
4. Backup video and slides available offline.
