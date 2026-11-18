# ShuttleSense Performance Optimization Roadmap

**Purpose:** A living implementation checklist and handoff for continuing ShuttleSense performance work, including in a new account. Update the checkboxes and evidence links as work is completed.

**Current priority:** Phase 1 — establish and review a real Flutter baseline for **Watch & Analyze → Analyze every frame** before major pipeline changes. This document does not authorize skipping the validation gates below.

## How to use this checklist

- `[x]` means the specific item was implemented or performed and has supporting evidence. It does not mean a whole feature or phase is validated.
- `[ ]` means the work or its required validation is still outstanding. A task that is partially done remains unchecked, with the completed portion noted in its description.
- Complete and review one phase at a time. Record commands, hardware, inputs, results, accuracy checks, and any deviations in the relevant report before checking an item.
- Preserve existing user changes and inspect the current repository and Git status before making edits. Revalidate this checklist against the code when resuming on a new account.
- Keep the existing frame normalization and sampling. “Analyze every frame” means every **normalized** frame; for example, a 50 fps source may become 25 fps. Do not imply every source frame is analyzed.
- Accuracy-sensitive changes—model inputs, precision, candidate selection, or temporal behavior—must remain disabled until evaluated against representative held-out labeled footage. The user selected **gate on labels**. If labels are unavailable, complete non-invasive diagnostics and shadow experiments and document what is missing.

## Current state and handoff

- [x] CUDA concurrency for frame-by-frame shuttle and player/pose perception is implemented and configured with `watch.frame_parallel_perception: auto`; CPU remains sequential. The separate background Watch setting is `watch.parallel_perception`.
- [x] In three prior in-process 45-second runs per mode, median progress increased from 11.24 s of video sequentially to 14.72 s concurrently. The test excluded Flutter display, actual network latency, and upload; it is not a guaranteed app speedup.
- [x] A 120-frame real-model sequential/concurrent comparison reported identical player and shuttle outputs and matching downstream events for the tested segment. Singles and doubles **configurations** used the same doubles recording; actual singles footage, labeled accuracy, and a full match remain unvalidated.
- [x] TensorRT RTX is requested for pose, with provider diagnostics and CUDA fallback. The CUDA detector and TensorRT RTX pose provider were confirmed in the documented diagnostic environment; verify the active providers in each new session.
- [x] Optional FFmpeg/NVENC export support and CPU fallback are present. The CPU `libx264` encoder remains the default because short comparisons did not establish a compelling overall benefit at comparable quality.
- [x] An experimental focused-candidate shortcut exists for background Watch and is off by default. It produced different hit output in one comparison and is not the baseline for frame-by-frame work.
- [x] Phase 1 opt-in server and Flutter diagnostics, benchmark extensions, an offline detector breakdown, and a Flutter log summarizer have been added. Relevant backend and Flutter Watch tests passed during their implementation.
- [x] A warm in-process run completed a previously saved, re-encoded 21-second section in 61.45 s, with 3.52 s export after the save acknowledgement. This is not a full-match or real Flutter result.
- [ ] **Phase 1 is incomplete:** obtain a controlled real Flutter baseline, including repeated sequential and concurrent runs and an overhead comparison. With app access approved, one preliminary instrumented warm-backend Flutter run reached 12.04 s of normalized video at 45.08 s elapsed; it was manually stopped and is not a controlled comparison. See the Phase 1 report.
- [ ] Confirm the user's informal “about 12 seconds” observation: identify the video position and elapsed time, mode, source clip, whether model startup was included, and whether both app and backend were restarted. Do not compare it numerically until confirmed.
- [ ] Acquire representative, consented and labeled singles/doubles footage covering spectators, boundaries, jumps, occlusions, identity crossings, and reacquisition. Record camera movement and calibration; split by recording or match into calibration and held-out evaluation sets.

**Evidence and instructions:**

- [Phase 1 audit and baseline](docs/results/watch_phase1_baseline.md)
- [Phase 2 delivery audit and recovered trials](docs/results/watch_phase2_delivery.md)
- [Frame-by-frame concurrency measurements](docs/results/watch_complete_parallel_nov16.md)
- [Earlier Watch, candidate-filter and export experiments](docs/results/watch_performance_nov16.md)
- [Setup and profiling commands](docs/SETUP.md) and [Watch API](docs/API.md)
- [Research context prompt](TEMP_shuttlesense_performance_research_context.md), if still present; it is a temporary reference and may be untracked.

## Phase 1 — Performance baseline and diagnostics

**Objective:** Establish the real frame-by-frame bottlenecks before changing processing behavior.

### Architecture and instrumentation

- [x] Audit the current frame lifecycle, normalization, packet/JPEG handling, parallel model join, stateful tracking, and export path. See the Phase 1 audit above.
- [x] Add opt-in, normalized-frame-correlated backend wall timings for frame normalization, JPEG decode, shuttle and player paths, tracker/recovery, recording, downstream ticks, candidate counts, and available detector/pose aggregates. Existing fields provide read, JPEG preparation, and overall processing timing.
- [x] Add opt-in Flutter `WATCH_PROFILE` events for response/handling, next-request delay, and post-frame callbacks; add a local log summarizer. A post-frame callback does **not** prove image decoding or pixels have completed display.
- [x] Add isolated detector and pose breakdown options to the offline profiler and optional sampled process CPU/RSS and device-wide NVIDIA GPU metrics to the frame-by-frame benchmark. `psutil` is an optional profiling dependency; see `backend/requirements/profiling.txt`.
- [x] Preserve normal behavior when profiling is disabled. Backend profiling is requested explicitly with `profile_diagnostics`; the Flutter instrumentation requires `--dart-define=WATCH_PROFILE=true`.
- [x] Measure actual CUDA kernel execution, graph/node placement, CPU/GPU transfer times, and synchronization with CUDA events or a GPU activity trace in a dedicated profiling run. A 35-frame offline Kineto trace attributed most launches to shuttle, detector and pose; provider assignment recorded 247 TensorRT RTX pose nodes and, in a recreated detector session, 411 CUDA and 4 CPU nodes. Attribution is approximate and actual-session fallback remains a separate gate. See the Phase 1 report.
- [ ] Measure true Flutter JPEG image-decode and display cost, response serialization/transmission, and any `cap.grab`/frame-read split that materially affects the baseline. Read/grab/resize, same-host serialization-to-client delivery, actual image-stream codec decode, image-ready callbacks, and Flutter build/raster durations are documented. OS composition and physical presentation remain unmeasured; raster is not screen scanout and the delivery interval includes scheduling.

### Benchmark and report

- [x] Extend `backend/scripts/bench_watch_complete.py` with optional profiling and resource sampling, same-process warm-up, complete normalized-clip mode, a 45-second checkpoint, median/p95 round trip, and optional JSON output. It uses an in-process TestClient and does **not** measure Flutter display or real network time.
- [x] Run a preliminary server-only profiling-overhead comparison: three alternating pairs over 25 seconds with the then-current resource sampler gave median 8.35 versus 8.01 normalized fps, approximately 4.1% lower with profiling. This is a small noisy test, not a Flutter overhead result.
- [ ] Repeat the overhead comparison using the final resource sampler, which gained system-wide CPU/RAM sampling after that test. Use at least three alternating runs and verify median throughput overhead is no more than 5%; report variance.
- [ ] Run at least three **actual Flutter** sequential and three concurrent trials with the same original clip and calibration. Separate cold and warm starts; record video progress at 45 seconds, full fixed-section analysis, median/p95 latency, normalized fps, model initialization, and annotated export.
- [ ] Compare instrumented and normal Flutter runs, including the effect of console logging. Record process CPU and RAM plus sampled GPU utilization, device-wide memory, clocks, temperature, and power when available; label samples as such and do not claim exact GPU-process peak VRAM from device-wide readings.
- [ ] Inspect the real session's provider activation and fallback state; verify observed GPU graph placement separately from the configured provider when needed.
- [ ] Review confirmed versus suspected bottlenecks and the instrumentation overhead, then update the Phase 1 report with the actual Flutter results and a prioritized next phase.

**Phase 1 completion gate:** Actual pipeline documented; controlled Flutter baseline and provider/fallback checks complete; significant bottlenecks supported by measurements; profiling overhead understood. Do not advance to major pipeline changes until this gate is reviewed.

**Manual profiling reference:** From `app/`, run `flutter run -d windows --profile --dart-define=WATCH_PROFILE=true`; for log capture and summarization, follow [Setup](docs/SETUP.md). The full console can include local diagnostic URLs and other details—keep it local and review it before sharing.

## Phase 2 — Frame processing and delivery

**Objective:** Reduce demonstrated delays between decoding, inference, WebSocket communication, and Flutter preview.

- [ ] Use Phase 1 evidence to determine whether frame reading, client request/response, display, or FPS pacing materially limits end-to-end throughput.
- [x] Prototype an opt-in bounded queue of two decoded frames. Prefetch decoding only; do not analyze or commit unrequested frames. Keep normalized indices and timestamps ordered and bound memory use. The experimental setting remains off; see the [Phase 2 audit](docs/results/watch_phase2_delivery.md).
- [x] Ensure pause/resume does not advance committed analysis. On stop, disconnect, or error, discard prefetched unprocessed frames and save only processed frames; preserve output alignment and older `/watch` clients. A request already in flight when paused may finish; no further requests are sent until resume. See the [Phase 2 audit](docs/results/watch_phase2_delivery.md) for test coverage and limits.
- [x] Measure Flutter image handling, widget rebuilds, and request scheduling before changing preview or pacing. Diagnostic measurements are recorded in the [Phase 1 report](docs/results/watch_phase1_baseline.md) and [Phase 2 audit](docs/results/watch_phase2_delivery.md); preview and pacing remain unchanged.
- [x] Investigate repeated resizing, color conversion, copies, and JPEG encode/decode. The [Phase 2 audit](docs/results/watch_phase2_delivery.md) traces Python-visible operations through models, preview and export and measures JPEG pixel differences. No optimization was enabled; native allocations and the accuracy of decoded-frame input remain unvalidated.
- [ ] Test no missing, duplicate, or reordered frames; pause, resume, stop, disconnect, partial saves, timestamps, preview, and annotated video alignment.
- [ ] Compare at least three alternating actual Flutter runs on identical input. Retain a change only if median fixed-section time improves by at least 5% without worse p95 latency or functional regressions; otherwise revert it or keep it disabled.

**Dependencies:** Phase 1 gate and a demonstrated bottleneck. **Likely areas:** `backend/shuttlesense/api/live.py`, `backend/shuttlesense/io/video.py`, `app/lib/features/watch/watch_screen.dart`, Watch tests, and API documentation.

## Phase 3 — YOLOX and RTMPose

**Objective:** Reduce detection and pose cost while protecting player identities and downstream analysis.

- [ ] Measure detector preprocessing/inference/postprocessing, accepted candidate counts, pose crops, batch inference, postprocessing, tracker updates, and transfer costs on representative footage. Existing host-wall instrumentation is not a CUDA trace.
- [ ] Compare batch sizes 4, 8, and 16 with the same TensorRT RTX profile and CUDA fallback. Record cold compilation, warm runtime, frame latency, candidate counts, VRAM, and actual Flutter end-to-end time.
- [ ] Evaluate court- and track-aware filtering in shadow mode against the current filter. Include players near boundaries, jumping, overlapping partners, occlusion, bystanders, tracking loss, and reacquisition.
- [ ] Keep focused-candidate selection disabled by default. Do not cap people or tighten boundaries solely because they improve an isolated benchmark.
- [ ] Investigate ONNX Runtime I/O binding only if profiling shows significant transfer overhead. Verify provider activation, supported model shapes, errors, diagnostics, and CUDA/CPU fallback.
- [ ] Evaluate held-out labeled player recall, identity switches, pose keypoint error, missing observations, reacquisition failures, hit recall, stroke differences, and court mapping.
- [ ] Promote an experimental change only if repeated end-to-end median time improves by at least 5%, player and hit recall do not decrease, identity-switch and reacquisition-failure counts do not increase, and pose error does not worsen on the held-out set. Report denominators and uncertainty; insufficient labeled data keeps it disabled.

**Dependencies:** Phase 1 and labeled footage for promotion. **Likely areas:** `backend/shuttlesense/pose/`, `backend/shuttlesense/stream/perception.py`, provider and profiler scripts, pose/Watch tests.

## Phase 4 — TrackNetV3

**Objective:** Optimize shuttle inference only if measured as a meaningful end-to-end bottleneck.

- [ ] Audit temporal window construction, resized-input caching, initialization, inference mode, tensor allocation, CPU/GPU copies, heatmap decoding, and coordinate conversion.
- [ ] Test low-risk buffer/copy improvements against the current PyTorch path, preserving inputs, temporal ordering, and output semantics.
- [ ] Consider ONNX or TensorRT conversion only after lower-risk work and only if TrackNet remains material. Measure build/warm-up time, temporal shapes, operator support, precision, memory, portability, and fallback. Existing TrackNet RTX and GPU-window paths are experimental and disabled.
- [ ] Evaluate held-out shuttle recall, coordinate error, visibility, trajectory continuity, occlusion, and effects on hits and strokes.
- [ ] Enable a replacement only with at least 5% repeatable end-to-end median improvement and no decrease in shuttle/hit recall or worsening of coordinate and trajectory/visibility errors. Keep PyTorch fallback.
- [ ] If TrackNet is not limiting, document the evidence and defer invasive optimization.

**Dependencies:** Phase 1 profiling; labels for behavior-changing promotion. **Likely areas:** `backend/shuttlesense/tracking/`, `backend/shuttlesense/stream/perception.py`, TrackNet scripts and tests.

## Phase 5 — CPU and GPU coordination

**Objective:** Address demonstrated scheduling, allocation, transfer, or initialization bottlenecks.

- [ ] Capture an opt-in Nsight Systems or equivalent trace of the actual frame-by-frame path, then compare with unprofiled timings. Examine GPU model overlap, transfers, synchronization, kernel gaps, CPU waits, allocations, initialization, and contention.
- [ ] Compare sequential and concurrent perception with identical input and providers, including correctness, memory, session lifetime, errors, and cancellation. Do not interpret GPU utilization alone as efficiency.
- [ ] If evidence supports it, test bounded ONNX Runtime, OpenCV, and PyTorch thread settings individually. Avoid global thread changes and oversubscription without measurements.
- [ ] Evaluate session warm-up, safe reuse, tensor-buffer reuse, and host/device copy reduction only where identified as costly. Check memory ownership, session isolation, and cleanup.
- [ ] Measure process CPU/RAM and sampled GPU/VRAM behavior; test sequential and CPU fallbacks and record lower-memory device limitations where hardware is available.
- [ ] Retain a change only with at least 5% repeatable end-to-end median improvement and no output, stability, or memory-exhaustion regression. Document unavailable profiler or hardware rather than claiming validation.

**Dependencies:** Phase 1; may proceed alongside the chosen measured bottleneck after its review. **Likely areas:** `backend/shuttlesense/stream/`, provider configuration, profiler scripts, concurrency tests.

## Phase 6 — Annotated-video rendering and export

**Objective:** Reduce final export time without reducing playback compatibility or obscuring quality tradeoffs.

- [ ] Separately measure source-frame read, CPU overlay drawing, encoder-pipe backpressure, encoder initialization, and finalization.
- [ ] Compare `libx264` and `h264_nvenc` on the same saved records, source frames, and overlays over short and longer recordings. Measure total time, output size, comparable visual quality against a reference, playback/seek, CPU/GPU use, and memory.
- [ ] Validate frame count, timestamps, no missing frames/overlays, player/shuttle annotation alignment, and playback in Flutter and a common player.
- [ ] Preserve `libx264` as default and NVENC as optional until repeated results demonstrate at least 5% median export improvement at comparable quality and compatible output. Retain CPU fallback and report failures that occur after encoding starts.
- [ ] Document benchmark conditions and rejected or retained encoder settings. Existing 525-frame comparisons used non-equivalent quality settings and do not establish a default change.

**Dependencies:** Phase 1 measurement and representative saved sessions. **Likely areas:** `backend/shuttlesense/render/`, rendering tests, setup and results documentation.

## Phase 7 — Integration and final validation

**Objective:** Validate the combined application and report which changes are suitable for normal use.

- [ ] Test complete short, medium, and longer consented clips containing actual singles and doubles, spectators, occlusions, boundaries, and camera changes where supported. Use fixed calibration and settings and at least three alternating baseline/candidate runs.
- [ ] Run backend Watch, stream, player-tracking, pose, tracking, API/schema, and rendering tests; run Flutter Watch tests and static analysis. Investigate failures rather than suppressing them.
- [ ] Verify every normalized frame, court calibration, player identity, pose, shuttle, hits/strokes, analytics, preview, pause/resume, stop/disconnect, partial saves, export, playback, and seek.
- [ ] Exercise CUDA with and without TensorRT RTX and CPU-only fallback. Test other supported platforms where available; explicitly list unavailable hardware and untested configurations.
- [ ] Compare baseline and final model initialization, progress at 45 seconds, total fixed-section/full-clip time, normalized fps, median/p95 latency, sampled CPU/RAM/GPU/VRAM, export time, output size, labeled accuracy, and stability.
- [ ] Produce a final implementation report: changes and files, defaults, optional flags, rejected/deferred experiments, reproducible commands, performance and accuracy evidence, compatibility/fallbacks, known limitations, and future work.

**Final completion gate:** Every retained optimization passes its individual performance and accuracy checks; the combined Flutter workflow shows a repeatable improvement without functional regressions. Do not present estimates or synthetic-only results as real-world validation.

## Recommended execution order

1. [ ] Complete and review **Phase 1**, especially real Flutter measurements and labeled-data availability.
2. [ ] Select the demonstrated bottleneck from **Phases 2, 3, and 5**; implement and validate one small change at a time.
3. [ ] Perform **Phase 4** only if TrackNet is materially limiting end-to-end time.
4. [ ] Evaluate **Phase 6** independently for the final video, then complete **Phase 7** for all retained changes.

## Progress notes

| Date | Phase | Work or decision | Evidence / next step |
| --- | --- | --- | --- |
| 2026-11-16 | Prior work | Enabled CUDA concurrency for frame-by-frame Watch after in-process comparisons. | [Concurrency measurements](docs/results/watch_complete_parallel_nov16.md); actual Flutter and labeled validation remain open. |
| 2026-11-16 | Phase 1 | Added opt-in diagnostics, local benchmark/resource sampling and Flutter log summarization; ran preliminary server-only and completed-section tests. | [Phase 1 baseline](docs/results/watch_phase1_baseline.md); actual Flutter access was not approved and the phase gate remains open. |
| 2026-11-16 | Phase 1 | Collected one preliminary instrumented Flutter run and fixed UTF-16 PowerShell log reading. | [Phase 1 baseline](docs/results/watch_phase1_baseline.md); repeated controlled trials and overhead checks remain open. |
| 2026-11-16 | Phase 1 | Captured a short offline CUDA activity trace and measured the reader's read/grab/resize split. | [Phase 1 baseline](docs/results/watch_phase1_baseline.md); GPU attribution, client decode/display and response transmission remain open. |
| 2026-11-16 | Phase 1 | Attributed a dedicated CUDA trace by model and recorded provider assignments; measured actual Flutter image-stream decode, frame timing and same-host response delivery. | [Phase 1 baseline](docs/results/watch_phase1_baseline.md); physical presentation, repeated baseline runs and overhead remain open. |
| 2026-11-18 | Phase 2 | Recovered prior prefetch trials and one completed Flutter diagnostic; fixed release of queued frames on close and reran backend and Flutter Watch tests. | [Phase 2 audit](docs/results/watch_phase2_delivery.md); Phase 1 gate, repeated Flutter comparisons and annotated-video alignment remain open. |
| 2026-11-18 | Phase 2 | Audited frame transformations and copies, and measured pixel differences from the existing JPEG round trip. | [Phase 2 audit](docs/results/watch_phase2_delivery.md); no new optimization enabled, and decoded-frame accuracy remains unvalidated. |
