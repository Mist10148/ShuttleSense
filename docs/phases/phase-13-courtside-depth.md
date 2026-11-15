# Phase 13 — Courtside depth

The expanded scope takes priority over the original November 18 feature freeze.
Release acceptance remains separate from code completion. No v1.0 tag is implied.

| Task | Deliverable | Status |
| --- | --- | --- |
| T13.1 | Reconcile phase work and historical instructions | Implemented · links verified |
| T13.2 | Session/client command deduplication and reconnect recovery | Automated checks passed · physical network interruption pending |
| T13.3 | Persistent referee decision history including undo | Game and undo filters tested · real replay check pending |
| T13.4 | Server-owned, explicitly started interval clock | Implemented · real-world verification pending |
| T13.5 | Persistent practice goals per player filter | Implemented · real-world verification pending |
| T13.6 | Evidence-based post-session recap and exports | Saved player and partner filters tested · real replay and export check pending |
| T13.7 | Courtside layout and accessibility | Checked at three widths in both themes with 200% text · courtside readability pending |
| T13.8 | Correct heuristic claims, contracts and release evidence | Implemented · real-world verification pending |

Statuses distinguish implemented, automated verification complete, real-world
verification pending, and externally blocked. Synthetic tests do not close device gates.

## Verified on Nov 15

- Referee review can filter decisions by game and undo status. Stop waits for
  pending commands. The live client recovered score and call state after a
  WebSocket disconnect in the Windows integration test.
- Coach shows the next cue and goal first. Saved recaps support side and doubles
  partner filters and keep shared evidence visible. Decisions and goals persist
  in sessions without camera frames, with play controls only for valid video
  moments.
- 437 non-GPU backend tests, 274 Flutter tests and both Windows integration
  flows passed. Windows and web release builds succeeded. The Windows flows used
  a generated clip and a substitute camera.
- The 300-frame [fake-perception run](../results/live_latency_courtside_fake.md)
  measured 23.0 ms p95 frame round trip. The [RTX 4050 run with models](../results/live_latency_courtside_model_smoke.md)
  measured 201.4 ms p95 and 7.6 fps sequential throughput on generated video. Both
  pose sessions selected ONNX Runtime's CUDA provider.

## Follow-up review on Nov 15

A code review after the courtside update fixed, with tests:

- **Live protocol:** a decision with a malformed `frame`, `reason` or `rally_index` was
  applied and then failed before its receipt was stored, so a retry applied it twice; it
  is now refused first (`bad_request`). Frames that are not JPEG are refused undecoded.
- **App:** a connection that stays open but silent is resumed after 10 s, and captures are
  skipped while more than 8 frames are unanswered; leaving the live screen sends `stop`,
  so the session is saved at once; the interval clock no longer starts again when its
  panel is rebuilt; Let before the first rally no longer clears the last rally.
- **Backend:** stage cache files are written atomically; a coach question that cannot
  start no longer blocks the job; `serve_colab.py` refuses the placeholder token.
- **Stroke models:** the BST import fault and retraining of D35
  ([results](../results/strokes.md)).

- **Change of ends** (clip record 1.7, D36): the score follows the players by the
  rules, with a setting to turn that off and a change marked by hand in the app, over
  REST and on the live socket. A line-call override after the deciding point of a match
  is refused.

465 non-GPU backend tests and 289 Flutter tests pass. Release builds and the Windows
integration flows were not re-run. None of this closes a device or footage gate.

## Earlier phase acceptance still open

| Phases | Remaining evidence | Dependency |
| --- | --- | --- |
| 0–1 | Team setup/sign-offs, storage, verify the private weight mirror, Colab and device connections | Team, accounts and devices |
| 2–3 | Tracking/hit/pose quality and timing on team clips, own-split training and ablation | Labelled footage |
| 4–5 | Device playback/calibration/accessibility and speed sanity | Devices, artwork review, calibrated clips |
| 6, 8, 12 | Camera alignment, live latency, landings, controls and coach readability | Consented courtside session and labels |
| 9 | ID/hitter accuracy, service order, doubles model evaluation | Labelled doubles rallies |
| 10–11 | Notification/selector checks, three-model real-clip comparison | Devices and perception models |
| 7 | Clean installs, signing, license evidence, demo/rehearsal and final metrics | Release assets, hardware and team |

Everything that needs footage, devices, accounts or a team decision is in one list:
[Left for the owner](../PHASES.md#left-for-the-owner-needs-github-admin-hardware-data-or-the-team).

Phases 10–12 have implemented code; their device checks remain open. Existing issue
titles and unchecked phase steps are acceptance tasks, not instructions to rebuild
features already present. Per-phase cards retain the original acceptance criteria.

## Delivery

Small conventional commits, no co-author trailers, tested fast-forward pushes to main.
Do not force-push or bypass protection. Record commands and actual results;
unavailable data and physical-device checks remain explicitly pending.


## Next courtside session

1. Set up the real backend on the RTX 4050 or Colab T4 with the
   [verified upstream checkpoints](../SETUP.md#5-weights) and
   [CUDA installation steps](../SETUP.md#3-backend-on-a-laptop-primary).
2. Record and label consented singles and doubles rallies with a fixed camera. Include
   close landings, service transitions, a reconnect and two camera heights. Have a
   teammate cross-check a subset of labels for Phase 7.
3. Test both roles on a phone and tablet, then repeat with a Windows webcam. Verify
   calibration, score recovery, timer controls, review, goals, saved moments and chat
   with a configured key. Record device, orientation, model versions and outcome.
4. Run the existing benchmark and evaluation scripts with the labelled footage. Log
   latency, line-call accuracy, tracking and hitter attribution with the tested commit.
5. Close team sign-offs and release gates after the evidence is recorded. That includes
   signing, clean installs, license evidence and demo rehearsal.
