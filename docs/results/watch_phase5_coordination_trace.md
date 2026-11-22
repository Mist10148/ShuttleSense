# Phase 5 frame-path coordination trace

## Scope

On November 20, 2026, a fresh-process PyTorch/Kineto CPU and CUDA activity trace
captured 35 frames of the real model-backed Watch frame-processing code through
`LiveSession` and the parallel shuttle/player worker paths. It is an offline
diagnostic, not the full Flutter-to-WebSocket session: it excludes the client,
network, recording and export. Nsight Systems was not found on PATH or under the
usual NVIDIA installation folder; its absence elsewhere was not established.

The input was the first 35 normalized frames of the re-encoded broadcast section
`.cache/phase2_fixed_source.mp4`, SHA-256
`4b96538f112e3d99543ac368437a8592dd60dc1973f7e7d6e6f6de228ba9c132`.
Source 1920 x 1080 / 50 fps was normalized to 1280 x 720 / 25 fps, with JPEG
round trip and approximate prior doubles court corners. The RTX 5070 Ti Laptop GPU
(12,227 MiB, driver 616.87) ran PyTorch TrackNet, the CUDA detector, and the
requested TensorRT RTX pose provider. Diagnostics listed 247 assigned pose nodes;
warnings about other provider assignments mean actual complete placement and
fallback were not established. Other desktop and GPU processes were active.

The profiler wraps shuttle, player, detector and pose calls. Runtime launches are
matched to the innermost host range on the same thread using correlation IDs and
aligned clocks. Work launched on other threads, asynchronous boundaries, graphs,
setup and activity from other processes may not be attributed. Raw trace and ranges
are local `.cache/phase5_trace.json` and `.cache/phase5_ranges.json` (about 155 MB
and potentially containing diagnostic paths); review before sharing.

## Traced versus untraced

The same source, 35 frames, code path and settings were run untraced, traced, then
untraced, each in a fresh process. Both variants still include the script's host
timing wrappers; the traced one adds Kineto. Processing wall time includes reading,
JPEG and processing, but not model setup or trace export. First-frame model warm-up
is included and dominates the short runs. These are single observations, not a
controlled throughput or profiler-overhead estimate.

| Measure | Untraced before | Traced | Untraced after |
| --- | ---: | ---: | ---: |
| Setup | 3.79 s | 2.44 s | 3.82 s |
| Processing wall | 19.02 s | 19.14 s | 19.32 s |
| Frame wall median / p95 | 89.1 / 152.0 ms | 85.8 / 167.8 ms | 89.3 / 168.8 ms |
| Shuttle wall median | 69.8 ms | 71.1 ms | 75.4 ms |
| Player wall median | 71.0 ms | 73.1 ms | 75.5 ms |

The host timers overlap and include CPU preparation, GPU waits and concurrent work;
they cannot be added. The detector's first-call warm-up dominated the recorded
candidate detection totals (about 16.35–16.52 s in each run). The apparent timing
similarity does not prove negligible tracing overhead under other workloads. Candidate
counts agreed across runs, but this is not output or accuracy validation.

## Trace observations

For a closer look at the measured path, the timeline summary excludes the first
frame and restricts itself to the union of each frame's host shuttle/player call
windows. For the remaining 34 frames, these windows totaled 3,129.97 ms. Shuttle and
player host ranges overlapped for 2,064.99 ms. Attributed GPU shuttle kernels and
attributed detector/pose/player kernels overlapped for 8.17 ms; all observed traced
kernel intervals occupied a union of 790.36 ms. An additional 31.55 ms of kernel
interval union was unattributed. This is approximate attribution, not exclusive GPU
utilization or proof of scheduling behavior on another workload.

The same window calculation found 151 gaps longer than 1 ms between observed traced
kernel intervals, with a largest gap of 60.03 ms; gaps total 2,339.61 ms within
the selected host windows. A gap can contain transfers, CPU preparation, waits,
initialization, unobserved or other-process GPU work, so it does not establish idle
GPU time or its cause. Trace events may overlap and coverage is not complete.

The full capture, including initialization, recorded these summed activity times:

| Approximate owner | Kernels | Pageable host-to-device copies | Device-to-pageable-host copies | CUDA synchronization calls |
| --- | ---: | ---: | ---: | ---: |
| Shuttle | 3,850 / 288.88 ms | 35 / 47.42 ms | 34 / 0.98 ms | 62 / 1.80 ms |
| Detector | 43,993 / 341.26 ms | 35 / 13.58 ms | 2,751 / 2.98 ms | 5,533 / 183.21 ms |
| Pose | 6,072 / 157.81 ms | 67 / 18.33 ms | 2 / 0.02 ms | 68 / 162.97 ms |
| Unattributed | 2,227 / 34.30 ms | 899 / 24.08 ms | 131 / 3.31 ms | 863 / 16.36 ms |

Counts and summed durations are not critical-path wall times and may overlap. The
trace also shows player-path activity outside the narrower model ranges, pinned and
device-to-device copies, and memset operations; the local JSON summary records them.
Across the whole capture it recorded 2,867 `cudaMalloc` calls / 19.75 ms and 2,813
`cudaFree` calls / 35.85 ms, plus asynchronous allocation/free calls. These runtime
events include initialization, may omit allocator activity, and do not measure
peak memory or allocation cost in the uninstrumented run. It recorded 6,763
`cudaStreamSynchronize` calls / 369.03 ms summed host time; those calls can wait for
work from other paths and are not a complete measurement of CPU waits.

## Remaining work and reproduction

The trace task remains open: capture the actual end-to-end frame-by-frame session
with reliable attribution, OS scheduling/wait visibility, memory peaks and
process-specific contention, and compare repeated unprofiled runs with the same
workload. Investigate potential overlap, transfer and allocation improvements only
after those measurements; this diagnostic alone does not justify a production change.

From `backend/`, run the following untraced command before and after the trace. The
trace command uses the same options, preceded by the indicated wrapper arguments:

```powershell
$opts = @('--video', '.cache/phase2_fixed_source.mp4', '--frames', '35', '--device', 'cuda', '--court', 'doubles', '--corners', '449.686', '1011.452', '1493.127', '1006.201', '1218.424', '488.875', '679.633', '483.143', '--player-provider', 'pose')
.\.venv\Scripts\python.exe scripts/profile_watch_pipeline.py @opts
.\.venv\Scripts\python.exe scripts/profile_watch_cuda_trace.py --trace .cache/phase5_trace.json --ranges .cache/phase5_ranges.json @opts
.\.venv\Scripts\python.exe scripts/summarize_watch_cuda_trace.py --trace .cache/phase5_trace.json --ranges .cache/phase5_ranges.json
.\.venv\Scripts\python.exe scripts/summarize_watch_gpu_timeline.py --trace .cache/phase5_trace.json --ranges .cache/phase5_ranges.json --skip-frames 1
```
