# Phase 4 conversion decision

## Decision

Defer new ONNX/TensorRT conversion work. The roadmap permits it only if TrackNet
remains a material end-to-end bottleneck after lower-risk work. Existing evidence
shows substantial TrackNet work, but does not yet isolate its effect on a controlled
Flutter end-to-end measurement. It also does not prove TrackNet is immaterial. The
experimental TrackNet RTX and GPU-window paths remain disabled.

The low-risk batch-view experiment reduced isolated preparation time, but its raw
heatmaps differed and it was not promoted ([results](watch_phase4_single_batch_experiment.md)).
The setup guide records an earlier 200-frame conversion probe whose TensorRT path was
slower and whose visibility differed on 101 frames. That is a warning about the
prototype, not a current controlled conversion comparison or proof that all ONNX or
TensorRT implementations fail.

## Additional lower-risk screening

On November 20, 2026, `bench_watch_parallel.py` compared the current PyTorch CPU
input window with the experimental CUDA rolling input window on the first 60 normalized
frames of the locally cached re-encoded broadcast section used in the
[batch experiment](watch_phase4_single_batch_experiment.md). It used CUDA, concurrent
player/shuttle inference, JPEG round trips, doubles, the configured candidate filter,
pose batch 8, and approximate previously used source-pixel court corners. The first
10 frames were excluded from timing, but included in output comparison. Other desktop
and GPU processes were active. The script synchronizes the GPU and processes the
baseline first, then the candidate; it does not measure Flutter, file reading, JPEG
encoding/decoding, network or rendering in the reported frame durations.

| Screen | CPU window baseline | GPU rolling window |
| --- | ---: | ---: |
| 50 timed frames, median | 86.0 ms | 81.4 ms |
| 50 timed frames, p95 | 116.6 ms | 99.6 ms |

All 60 per-frame outputs matched, and the derived hits, rallies, line calls and score
matched; the analysis contained zero hits, rallies and line calls. The GPU window was
reported active. Pose diagnostics reported 247 TensorRT RTX nodes, while ONNX Runtime
warned that some nodes were not assigned to preferred providers. The detector's summed
instrumented host time over all 60 frames was 17.39 s in the first run and 2.06 s in
the second. That difference and the fixed run order indicate a serious cold-start or
other order confound; excluding ten frames does not remove it. The timing difference
cannot establish a repeatable speedup, causal improvement, end-to-end impact, or a
promotion decision. The one short unlabeled sample cannot establish accuracy.

Reproduce this screening from `backend/`:

```powershell
.\.venv\Scripts\python.exe scripts/bench_watch_parallel.py --video .cache/phase2_fixed_source.mp4 --frames 60 --device cuda --court doubles --corners 449.686 1011.452 1493.127 1006.201 1218.424 488.875 679.633 483.143 --compare-gpu-window
```

## What remains

Establish a repeated controlled Flutter end-to-end baseline and use a paired,
counterbalanced comparison or carefully described bottleneck intervention to determine
TrackNet's material impact under concurrent processing. Investigate the batch-view
heatmap discrepancy and evaluate low-risk alternatives. If TrackNet remains material,
measure cold export and engine build, warm-up and warm runtime, supported temporal
shapes and operator placement, precision and output differences, process/device memory,
portability and initialization/runtime fallback. Compare labeled shuttle and downstream
events and apply the roadmap's promotion gate. None of these conversion measurements
was completed by this screening.

## Counterbalanced backend intervention — November 20, 2026

The Flutter integration driver was started against an isolated local server but did
not reach its first session; it was stopped without interrupting the already-running
app. The reason for the stall was not established. As a fallback, a new isolated
`TestClient` benchmark exercised the actual Watch WebSocket, including reading,
JPEG work, concurrent perception, analysis and sending frames to an in-process
client. It does not include Flutter, a real network, display, or completed export in
the analysis timing. It uses the same broadcast section and approximate corners as
above. Other machine workloads were active.

The intervention replaced shuttle perception with an empty `Shuttle` inside the
benchmark process. This is deliberately incorrect, changes analysis workload and
results, and is not a candidate optimization or a strict mathematical bound. One
25-frame warm-up session was run in each mode; then six new sessions processed the
first 100 normalized frames in normal, bypass, bypass, normal, bypass, normal order.
Every session saved its partial result and its export finished before the next began.
Per-session processing is from the end of setup through receipt of the last frame;
saved time includes setup and stop/save acknowledgement. Each trial covers the same
four seconds of video and is not independent footage.

| Trial | Mode | Processing (s) | Setup to saved (s) | Frame round-trip median / p95 (ms) |
| ---: | --- | ---: | ---: | ---: |
| 1 | Normal | 11.626 | 12.815 | 102.328 / 167.087 |
| 2 | Bypass | 12.452 | 13.777 | 99.599 / 176.855 |
| 3 | Bypass | 10.917 | 12.326 | 97.151 / 154.327 |
| 4 | Normal | 12.531 | 13.915 | 107.587 / 174.726 |
| 5 | Bypass | 10.748 | 12.238 | 93.486 / 156.832 |
| 6 | Normal | 11.924 | 13.339 | 103.341 / 168.930 |

The median processing duration was 11.924 s normal and 10.917 s bypass, an 8.4%
reduction in this small backend-only sample. The first pair went in the opposite
direction and run-to-run variation is substantial. Bypassing TrackNet also changes
downstream work, so this difference cannot be assigned solely to inference. It is
evidence that TrackNet may matter, not proof of a repeatable Flutter speedup or of
the achievable benefit of conversion. The conditional conversion gate remains open.

Reproduce the diagnostic in a dedicated process with isolated storage:

```powershell
.\.venv\Scripts\python.exe scripts/bench_watch_tracknet_ceiling.py --video .cache/phase2_fixed_source.mp4 --storage .cache/phase4_websocket_ceiling_storage --frames 100 --warmup 25 --corners 449.686 1011.452 1493.127 1006.201 1218.424 488.875 679.633 483.143
```

## Flutter Windows intervention — November 20, 2026

A further Windows Flutter profile test used the same 21-second source, approximate
court corners and isolated backend. The existing integration harness drove the real
Watch screen with `WATCH_PROFILE=true`; a local-only wrapper selected normal TrackNet
or the same artificial empty-shuttle intervention. This alters the results and
downstream work, and is not an optimization or a strict mathematical upper bound.
The backend used the current pipeline configuration and CUDA; the normal app and
other desktop processes were also open. Instrumented app logs, profiling and the
test harness add overhead. Each run was checked to receive indices 0–524 in order.
The source is the same re-encoded broadcast section identified above, not a collection
of independent clips.

| Trial | Mode | Analysis to saved (s) | Frame round-trip median / p95 (ms) |
| ---: | --- | ---: | ---: |
| 1 | Normal | 80.634 | 139.48 / 205.05 |
| 2 | Bypass | 77.019 | 133.57 / 188.23 |
| 3 | Normal | 89.106 | 153.81 / 212.44 |
| 4 | Bypass | 102.518 | 178.54 / 275.31 |
| 5 | Normal | 90.939 | 153.94 / 219.26 |
| 6 | Bypass | 93.034 | 163.56 / 246.22 |

Analysis-to-saved medians were 89.106 s normal and 93.034 s bypass, approximately
4.4% slower with the bypass. Pair 1 favored bypass while pairs 2 and 3 favored
normal. This noisy intervention does not demonstrate a repeatable Flutter benefit
from eliminating shuttle inference, nor does it prove TrackNet is immaterial across
other clips or hardware. Since the bypass changes outputs, these timings cannot be
used to promote it or establish shuttle or hit accuracy.

A 25-frame normal warm-up preceded trials 1–5. After trial 5 the log showed all
525 frames, the saved acknowledgement and `Session saved`, but the harness did not
emit its final trial marker or advance; the benchmark runner was stopped. Trial 6
was run after another 25-frame warm-up in a separate Flutter process against the
same backend. The restarted driver printed `All tests passed` and an
`integration_test` plugin warning, but returned exit code 1. These interruptions,
the non-counterbalanced AB ordering, single clip, and competing workloads further
limit interpretation. The raw logs are local, under
`backend/.cache/phase4_ceiling_flutter.log` and `phase4_ceiling_flutter_tail.log`.

The initial Flutter stall described above was resolved by allowing access to the
Flutter SDK cache outside the workspace. The isolated benchmark server is
`scripts/serve_watch_tracknet_ceiling.py`; it must be used with one client and
separate storage. Its test-only global bypass must never be used for normal serving.
No inference setting was changed. On this evidence, defer the conversion measurements
until a repeatable controlled end-to-end bottleneck is established; the roadmap item
remains open.
