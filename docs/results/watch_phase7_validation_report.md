# Phase 7 integration validation and handoff

## Decision — November 20, 2026

The combined application is **not fully validated for promotion** under the
performance roadmap. The checks below support continued development and the
existing experimental configuration, but do not establish a repeatable combined
Flutter speedup or held-out player, shuttle and event accuracy. No production
inference or encoding defaults were changed as part of this validation.

The current configuration already enables candidate filtering and pose batch size 8;
both remain experimental and lack the held-out accuracy evidence required by the
roadmap. They were restored at the owner's earlier request after a shadow/serial
trial. Do not describe them as newly validated or silently change them as a result of
this report.

## Tests and provider smoke checks

| Check | Result and limit |
| --- | --- |
| Backend Watch, stream, player, pose, tracking, API/schema and rendering suites | 255 passed with one GPU-marked test deselected, then that test was invoked separately and skipped because its required `samples/rally01.mp4` or weights check failed. The sample is absent; real-model checks below use a different local broadcast section. |
| Flutter Watch, court geometry and connection/upload tests | 34 passed in the default Flutter test environment. |
| Flutter static analysis | `flutter analyze --no-pub`: no issues. |
| Chrome Flutter test runner | The Watch/court test run and a single-file retry stalled at loading. A minimal arithmetic-only browser test also stalled at loading; all three attempts were stopped. The cause is not established, and no Chrome test passed. |
| Windows Flutter local export playback | Both sampled H.264 files opened and sought using `media_kit`; the driver printed success and warned about the integration-test plugin, then returned exit code 1. This was not the full streamed Results workflow. [Export report](watch_phase6_export_benchmark.md) |

Three fresh-process, three-frame offline smoke runs used the same re-encoded
21-second broadcast section, approximate prior doubles corners, and the current
model-backed processing path on an RTX 5070 Ti Laptop GPU. Each exited successfully:

| Requested device / player provider | Reported provider | Setup / processing wall |
| --- | --- | ---: |
| CUDA / CUDA | Detector CUDA and pose CUDA | 2.42 / 16.58 s |
| CUDA / pose RTX | Detector CUDA and pose TensorRT RTX, 247 assigned pose nodes | 4.03 / 15.71 s |
| CPU / CUDA selection | Detector CPU and pose CPU | 2.46 / 5.21 s |

Times include substantial first-inference warm-up, use only three frames, and are not
valid speed comparisons. The offline profiler explicitly uses concurrent workers even
for CPU; this checks CPU model execution, not the production CPU-sequential Watch
fallback or a complete Flutter workflow. Provider diagnostics and an ONNX Runtime
assignment warning do not establish all-node placement or every fallback. Driver
616.87 and a 12,227 MiB GPU were present. Logs are local in
`backend/.cache/phase7_*provider.log`.

## Current settings and retained experiments

The relevant current `backend/configs/pipeline.yaml` settings are:

| Area | Current setting and status |
| --- | --- |
| Watch concurrency | `frame_parallel_perception: auto` and background `parallel_perception: auto`; CUDA concurrent, CPU sequential by default. |
| Player path | `player_provider: pose`, `pose_batch_size: 8`, `candidate_filter: filter`; RTX pose with CUDA/CPU fallbacks. Batch/filter remain experimental without held-out promotion evidence. |
| Focused candidate cap | `candidates_per_player: 0`; focused shortcut disabled. |
| Delivery | `frame_prefetch_depth: 0`; decoded-frame bypass is false. |
| TrackNet | `track_provider: pytorch`; GPU window false. RTX conversion and GPU-window alternatives remain disabled. |
| Export | `libx264` default; `h264_nvenc` optional with preflight CPU fallback. |

The retained diagnostic work includes `scripts/profile_watch_pipeline.py`,
`scripts/profile_watch_cuda_trace.py`, `scripts/summarize_watch_cuda_trace.py`,
`scripts/summarize_watch_gpu_timeline.py`, `scripts/bench_watch_coordination.py`,
`scripts/bench_tracknet_single_batch.py`, `scripts/bench_watch_tracknet_ceiling.py`,
`scripts/bench_render_export.py`, associated tests and
`app/integration_test/export_playback_test.dart`. The single-client diagnostic
servers in `scripts/serve_watch_*` are for isolated experiments, not shared or
production serving. Raw traces, outputs and logs in `.cache` may contain local
paths or video and should be reviewed before sharing.

## Performance and functional evidence

- In the earlier fixed-section Flutter prefetch comparison, median analysis-to-save
  was 89.911 s without prefetch and 91.719 s with depth 2, so prefetch remains off.
  Each comparison run recorded all 525 normalized frames. This instrumented,
  single-clip experiment is not a combined final-versus-original baseline.
  [Delivery report](watch_phase2_delivery.md)
- A short repeated same-input model-perception comparison had 109.419 ms sequential
  versus 77.027 ms concurrent median-of-trial medians, with equal sampled outputs.
  It excludes Flutter, WebSocket and export, and sampled memory cannot establish
  long-session or process-specific GPU peaks. [Concurrency report](watch_phase5_concurrency_comparison.md)
- The single-window batch view preserved sampled input values and decoded points but
  changed raw heatmaps; it remains experimental. The Flutter artificial shuttle-bypass
  experiment did not show a repeatable benefit, so TrackNet conversion remains
  deferred. [Batch experiment](watch_phase4_single_batch_experiment.md),
  [conversion assessment](watch_phase4_conversion_gate.md)
- On one 525-frame saved section, the initial export benchmark measured median
  2.816 s for x264 and 2.819 s for NVENC. Their measured PSNRs were close but this
  does not establish comparable perceived quality. See the
  [export report](watch_phase6_export_benchmark.md) for size, sampled resources,
  frame/timestamp and playback checks.
- Existing automated tests cover ordered frames, calibration and synthetic player,
  pose, shuttle, hits, analytics, preview, stop/disconnect and partial save behavior.
  They do not independently verify every real-frame annotation, identity, occlusion,
  trajectory, hit/stroke or camera-change case. Real in-flight cancellation and
  long-session memory behavior remain open.

There is no final-versus-baseline table covering all requested metrics. Model
initialization, 45-second progress, full-clip time, normalized fps, median/p95,
CPU/RAM/GPU/VRAM, export, file size, stability and labeled accuracy have not all been
measured on paired, representative, controlled baseline/final runs. No labeled
accuracy or confidence interval is invented from the synthetic and unlabeled tests.

## Platform and data limits

Flutter detected Windows, Chrome and Edge. Windows has the local-player test described
above; full real-device end-to-end validation on Windows and web remains incomplete.
Chrome test startup stalled even for a minimal non-application test, so the observed
problem is not sufficient evidence of a Watch-specific defect. The browser runner
and its environment still need investigation.
No Android or iOS device was detected in this session; iOS and other hardware were not
tested. Nsight Systems was not found in the checked locations. The local test section
is broadcast doubles; the owner deferred phone profiling. We do not have documented
held-out labels and consented short, medium and long singles/doubles sets covering
spectators, occlusions, boundaries and camera changes. Calibration is approximate.

## Reproduction and outstanding gates

From `backend/`, the relevant test selection can be repeated in PowerShell:

```powershell
$tests = Get-ChildItem tests -File -Filter 'test_*.py' | Where-Object { $_.Name -match 'watch|stream|player|pose|tracking|api|schema|render' } | ForEach-Object { $_.FullName }
.\.venv\Scripts\python.exe -m pytest @tests -m 'not gpu' -p no:cacheprovider
.\.venv\Scripts\python.exe -m pytest tests/test_tracking.py -m gpu -q -p no:cacheprovider -rs
```

From `app/`:

```powershell
flutter test --no-pub test/watch_test.dart test/watch_court_geometry_test.dart test/connect_upload_test.dart
flutter analyze --no-pub
```

For real-model smoke tests, use `scripts/profile_watch_pipeline.py` with a local
video, `--frames 3`, the documented court/corners, and combinations `--device cuda
--player-provider cuda`, `--device cuda --player-provider pose`, and `--device cpu
--player-provider cuda`. The other linked reports provide exact benchmark commands.

To complete Phase 7, obtain appropriately split and labeled footage; run at least
three alternating baseline/final trials with fixed calibration on the requested
clip types; verify every normalized frame and real annotations; exercise real
complete/partial sessions, CPU-sequential and provider failures, supported client
platforms and playback; record process-specific memory and the requested full metric
set. Revisit the experimental defaults using the individual promotion gates. The
final completion gate stays open until this evidence exists.
