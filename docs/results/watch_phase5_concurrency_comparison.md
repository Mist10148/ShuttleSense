# Phase 5 sequential and concurrent perception comparison

## Scope

On November 20, 2026, six isolated model-perception trials used the first 60
normalized frames of `.cache/phase2_fixed_source.mp4`, a 1920 x 1080 / 50 fps
re-encoded broadcast section (SHA-256
`4b96538f112e3d99543ac368437a8592dd60dc1973f7e7d6e6f6de228ba9c132`), normalized
to 1280 x 720 / 25 fps. Each mode used the same frames, JPEG round trip, doubles,
approximate source-pixel corners, candidate filter, pose batch size 8, CUDA detector,
TensorRT RTX pose request, and PyTorch TrackNet. The experiment used an RTX 5070 Ti
Laptop GPU with other desktop processes active. Provider diagnostics reported CUDA
for detector and 247 TensorRT RTX pose nodes; this is not proof of complete graph
placement or absence of runtime fallback.

After one 12-frame warm-up in each mode, the same process ran sequential, concurrent,
concurrent, sequential, concurrent, sequential. Each trial created fresh perception
and tracker state; the process-wide TrackNet model cache and runtime resources could
be reused. Calls were synchronized before and after each measured frame. Timings
exclude video reading, JPEG preparation, setup, analysis replay, Flutter, WebSocket,
recording and export. The synchronization and resource sampling perturb execution.
The six runs reuse the same short section and are not independent footage samples.

## Results

| Trial | Mode | Frame median / p95 (ms) | Sampled process RSS max (GiB) | Sampled device-wide GPU memory max (MiB) |
| ---: | --- | ---: | ---: | ---: |
| 1 | Sequential | 109.419 / 198.950 | 2.92 | 5,625 |
| 2 | Concurrent | 76.565 / 131.162 | 2.96 | 5,633 |
| 3 | Concurrent | 90.084 / 142.179 | 3.35 | 5,685 |
| 4 | Sequential | 110.763 / 199.265 | 2.70 | 5,606 |
| 5 | Concurrent | 77.027 / 134.379 | 3.04 | 5,652 |
| 6 | Sequential | 106.651 / 191.857 | 3.37 | 5,650 |

The median of the three per-trial medians was 109.419 ms sequential and 77.027 ms
concurrent, approximately 29.6% lower for the concurrent path in this isolated
experiment. It is not an end-to-end Flutter speedup or a new promotion decision.
All six produced exactly the same 60 serialized shuttle/player outputs as trial 1;
candidate counts also matched. Replayed hit, rally, line-call and score outputs
matched, but this short section produced zero hits, rallies and line calls. These
checks are parity checks, not labeled accuracy or general correctness evidence.

The resource sampler polls about once per second, so maxima can miss peaks; RSS is
for the benchmark process and includes setup, caches and runtime state from earlier
trials. GPU memory is device-wide and includes other processes. PyTorch's per-trial
peak allocated memory was approximately 280–281 MiB, excluding ONNX Runtime and
other non-PyTorch allocations. Neither measure proves the incremental memory cost,
memory stability across a long session, or behavior on lower-memory GPUs. The data
does not isolate a leak or establish equal memory use.

## Lifetime, errors and cancellation

`tests/test_watch_parallel.py` checks concurrent worker overlap, error propagation
from either worker, waiting for an in-flight frame during shutdown, and independence
of separately constructed worker pools. Existing WebSocket tests
`test_complete_watch_parallelizes_and_cleans_up` exercise stop, disconnect and a
worker failure after three frames, verifying worker close and saved partial-frame
order with fake perception. All seven parallel-worker tests and all three WebSocket
cases passed in this run.

The close test demonstrates that shutdown waits for an active worker; it does not
prove immediate cancellation. GPU inference and `ThreadPoolExecutor.shutdown(wait=True)`
are not preempted by the test. In-flight task cancellation, a real-model disconnect
during inference, repeated real session teardown, and memory after long-running
sessions have not been measured. Do not infer successful cancellation or leak-free
operation from a clean short run.

## Reproduction and remaining work

From `backend/`:

```powershell
.\.venv\Scripts\python.exe scripts/bench_watch_coordination.py --video .cache/phase2_fixed_source.mp4 --frames 60 --warmup 12 --corners 449.686 1011.452 1493.127 1006.201 1218.424 488.875 679.633 483.143
.\.venv\Scripts\python.exe -m pytest tests/test_watch_parallel.py -q -p no:cacheprovider
.\.venv\Scripts\python.exe -m pytest tests/test_watch.py -q -p no:cacheprovider -k complete_watch_parallelizes_and_cleans_up
```

Logs are local in `.cache/phase5_coordination_trials.log`. Establish process-specific
peak and steady memory with longer repeated sessions, actual cancellation during
in-flight work and cleanup, and correctness on additional representative footage.
Use repeated complete Flutter comparisons before claiming an end-to-end improvement.
The checklist item stays open for these gaps; no production scheduling default changed.
