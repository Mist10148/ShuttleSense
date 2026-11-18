# Watch YOLOX and RTMPose profiling

## Status and scope

The first Phase 3 measurement item is **partially complete**. We measured detector,
candidate, pose, tracker and GPU-copy activity on three short real-model sections from
two public broadcast recordings, including an actual singles match and doubles play.
These are not representative consented/labeled phone recordings or a held-out test set;
they do not establish player recall, identity accuracy, reacquisition or safety of a
filter. The Phase 1 controlled-baseline gate is also still open. No inference settings,
model inputs or candidate-selection behavior were changed.

Measurements were collected November 18, 2026 on an RTX 5070 Ti Laptop GPU (12,227 MiB,
driver 616.87), 20 logical CPU cores, 31.67 GiB RAM, PyTorch 2.14.1+cu130, OpenCV
5.0.0 and ONNX Runtime 1.31.1. Other desktop processes were active. Each offline run
started a fresh process; initialization was outside the frame timing, but model and
background warm-up occurred during the measured frames. Each used the current pipeline
config, concurrent shuttle/player inference, JPEG round trip, no video recording, pose
batch limit 8 and the existing `candidate_filter: filter` with no focused cap. This is
not a real Flutter or end-to-end throughput benchmark.

The doubles source was the locally stored Paris 2024 broadcast, 50 fps normalized to
25 fps at 1280x720, SHA-256
`d6b5447902e08d2e61dc3bd4c0cc4b38071302b97fb68e58f50a3487e2e02f24`.
The two 160-normalized-frame samples start at indices 0 and 1200. They use the same
prior approximate source-pixel court corners: `(449.686,1011.452)`,
`(1493.127,1006.201)`, `(1218.424,488.875)`, `(679.633,483.143)`.
The singles source was a separate Dakar 2026 broadcast, 25 fps normalized to 25 fps
at 1280x720, SHA-256
`69f5dc66b23804506ab8efdf31fcd3b02f283574e6ddb0a8d0894f667a291024`.
Its 160-frame sample starts at normalized index 250; the source-pixel corners
`(408,1012)`, `(1660,1012)`, `(1460,500)`, `(572,500)` were estimated from a
thumbnail and are not validated court calibration. Each run resets tracking and
background history at its starting index. Camera geometry and scene changes within a
recording may make the fixed corners inaccurate.

## Host wall measurements

Each cell is **number of calls / median ms / p95 ms**. Calls can include additional
far-player recovery detector/pose passes, so they are not all one per video frame.
`pose_run` measures the ONNX Runtime session call for a batch; crop and postprocessing
are per crop in these runs. Times overlap across concurrent model paths, can include
GPU waits or transfers, and nested totals must not be summed as end-to-end latency.

| Operation | Doubles start 0 | Doubles start 1200 | Singles start 250 |
| --- | ---: | ---: | ---: |
| Detector preprocessing | 196 / 1.5 / 2.0 | 172 / 1.4 / 2.0 | 172 / 1.5 / 2.2 |
| Detector inference call | 196 / 31.8 / 42.7 | 172 / 32.3 / 44.3 | 172 / 32.3 / 41.9 |
| Detector postprocessing | 196 / 0.1 / 0.1 | 172 / 0.1 / 0.1 | 172 / 0.1 / 0.1 |
| Pose crop/preprocess | 2630 / 1.5 / 2.1 | 2182 / 1.5 / 2.2 | 3761 / 1.5 / 2.0 |
| Pose batch session call | 374 / 6.5 / 8.8 | 337 / 6.5 / 10.7 | 517 / 6.1 / 9.1 |
| Pose postprocess | 2630 / 0.0 / 0.2 | 2182 / 0.0 / 0.2 | 3761 / 0.0 / 0.2 |
| Tracker update | 160 / 1.0 / 1.8 | 160 / 0.9 / 1.7 | 160 / 1.2 / 2.1 |
| Entire player path | 160 / 84.8 / 143.8 | 160 / 79.1 / 123.5 | 160 / 101.3 / 189.5 |
| Frame processing | 160 / 93.0 / 159.2 | 160 / 88.4 / 135.2 | 160 / 108.1 / 195.4 |

The full first/second doubles and singles runs took 19.47, 17.59 and 21.43 seconds
respectively, including reading, JPEG work and processing but excluding model setup and
export. Candidate selection recorded respectively 6,133 / 5,105 / 5,253 detected
boxes, 2,339 / 2,088 / 3,490 eligible and 3,794 / 3,017 / 1,763 excluded over
160 main-path selections each; no candidate-filter fallback was reported. These are
detector boxes, not labeled players, and `tracked_excluded` is not an accuracy metric
for active filtering. Extra recovery crops explain why crop totals exceed eligible
main-path boxes. Detection, selection and pose stage totals were 6.499 / 0.101 /
7.079 s, 6.539 / 0.079 / 6.737 s and 6.465 / 0.080 / 10.072 s, respectively.

Observed pose batch-size call counts were `{1:20, 2:7, 5:12, 6:38, 7:68, 8:229}`,
`{1:24, 2:16, 3:7, 4:11, 5:25, 6:35, 7:26, 8:193}`, and
`{1:3, 2:2, 3:3, 4:24, 5:33, 6:48, 7:36, 8:368}`. These are the sizes observed
at session calls, including recovery, not a comparison of configured batch limits.
Each run reported the detector's active provider as CUDA and pose as TensorRT RTX
with 247 assigned pose nodes; the diagnostics also list CUDA/CPU fallbacks. The active
detector graph's per-node placement and actual fallback during every call were not
independently established.

## CUDA activity trace

A separate intrusive PyTorch/Kineto activity trace captured 35 doubles frames starting
at index 0 using the same CUDA and pose settings. Model-call thread/time ranges were
matched approximately to CUDA runtime launch correlation IDs. The trace includes setup,
and activity not attributable to those ranges remains unattributed. Summed activity
durations may overlap, are not end-to-end cost, and cannot be directly compared to or
added to host-call wall timers. Cross-thread launches, asynchronous activity, graph
execution and timestamp alignment limit attribution; this is not proof of complete
ONNX Runtime transfer accounting or exact current-session graph placement.

| Approximate owner | GPU kernel events / summed ms | Pageable host-to-device copies / ms | Device-to-pageable-host copies / ms | CPU synchronization calls / summed ms |
| --- | ---: | ---: | ---: | ---: |
| Detector inference | 44,475 / 270.01 | 35 / 14.19 | 2,801 / 3.05 | 5,629 / 116.23 |
| Pose session | 6,072 / 165.23 | 67 / 18.80 | 3 / 0.03 | 69 / 185.09 |
| Shuttle path | 3,850 / 301.83 | 35 / 48.65 | 35 / 0.97 | 70 / 1.58 |
| Unattributed | 2,227 / 34.29 | 899 / 28.71 | 130 / 3.24 | Not assigned |

The trace additionally includes detector pinned-memory copies, device-to-device copies
and GPU memset events; the local summary records their counts and durations. There is
also player-path activity outside the narrower detector and pose ranges. The short,
instrumented trace includes warm-up and cannot show whether I/O binding would improve
Flutter throughput. The raw local trace and ranges are
`backend/.cache/phase3_attributed_trace.json` and `phase3_attributed_ranges.json`;
they may contain local diagnostic paths and should be reviewed before sharing.

## Reproduction and remaining work

From `backend/`, run the host profiler for the desired source, start index and court:

```powershell
.\.venv\Scripts\python.exe scripts/profile_watch_pipeline.py --video PATH --frames 160 --start-frame 0 --device cuda --court doubles --corners X1 Y1 X2 Y2 X3 Y3 X4 Y4 --player-provider pose --pose-breakdown --detector-breakdown
```

For a new trace, use `scripts/profile_watch_cuda_trace.py --trace TRACE.json --ranges
RANGES.json` followed by the same video/court options (use a short frame count), then
`scripts/summarize_watch_cuda_trace.py --trace TRACE.json --ranges RANGES.json`. The
captured trace above used the prior local script's anchor name; summarize that trace
with `--anchor phase1_clock_anchor`. The capture and summary scripts were smoke-tested
with five real-model frames. Traces are large and perturb runtime.

Complete this checklist item only after measuring footage representative of intended
use, including consented phone singles and doubles, difficult boundaries, occlusions,
crossings and reacquisition, with documented calibration and sufficient samples. Measure
transfer/placement in the actual session or explicitly account for unassigned activity.
Labeled held-out data remains required before enabling accuracy-sensitive changes.
