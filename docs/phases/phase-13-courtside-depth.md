# Phase 13 — Courtside depth

The expanded scope takes priority over the original November 18 feature freeze.
Release acceptance remains separate from code completion. No v1.0 tag is implied.

| Task | Deliverable | Status |
| --- | --- | --- |
| T13.1 | Reconcile phase work and historical instructions | Implemented |
| T13.2 | Session/client command deduplication and reconnect recovery | Planned |
| T13.3 | Persistent referee decision history including undo | Planned |
| T13.4 | Server-owned, explicitly started interval clock | Planned |
| T13.5 | Persistent practice goals per player filter | Planned |
| T13.6 | Evidence-based post-session recap and exports | Planned |
| T13.7 | Courtside layout and accessibility | Planned |
| T13.8 | Correct heuristic claims, contracts and release evidence | Planned |

Statuses distinguish implemented, automated verification complete, real-world
verification pending, and externally blocked. Synthetic tests do not close device gates.

## Earlier phase acceptance still open

| Phases | Remaining evidence | Dependency |
| --- | --- | --- |
| 0–1 | Team setup/sign-offs, storage, model checksums, GPU/Colab and connections | Team, accounts, assets and hardware |
| 2–3 | Tracking/hit/pose quality, timings, own-split training and ablation | Perception weights and labelled footage |
| 4–5 | Device playback/calibration/accessibility and speed sanity | Devices, artwork review, calibrated clips |
| 6, 8, 12 | Camera alignment, live latency, landings, controls and coach readability | Consented courtside session and labels |
| 9 | ID/hitter accuracy, service order, doubles model evaluation | Labelled doubles rallies |
| 10–11 | Notification/selector checks, three-model real-clip comparison | Devices and perception models |
| 7 | Clean installs, signing, license evidence, demo/rehearsal and final metrics | Release assets, hardware and team |

Phases 10–12 have implemented code; their device checks remain open. Existing issue
titles and unchecked phase steps are acceptance tasks, not instructions to rebuild
features already present. Per-phase cards retain the original acceptance criteria.

## Delivery

Small conventional commits, no co-author trailers, tested fast-forward pushes to main.
Do not force-push or bypass protection. Record commands and actual results;
unavailable data and physical-device checks remain explicitly pending.
