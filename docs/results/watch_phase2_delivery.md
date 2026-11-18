# Watch frame delivery: Phase 2 audit

## Status

Phase 2 remains open. The two-frame decoded-frame prefetch prototype exists and is
disabled by default (`watch.frame_prefetch_depth: 0`). Neither the Phase 1 controlled
baseline gate nor the Phase 2 repeated Flutter comparison has been completed. Do not
enable the prototype by default on the evidence below.

## Recovered measurements

The interrupted work left six 20-second, warmup-10-frame, in-process TestClient runs
on the original 50 fps doubles broadcast with the same calibration and concurrent
perception. The sequence of queue depths was 0, 2, 2, 0, 0, 2. The final resource
sampler was enabled, but detailed per-frame profiling was off. Each run started a new
process and warmed a session within it; these are not one continuously warm process.

| Depth | Frames in each run | Normalized fps in each run | Median fps | Frame round-trip p95 (ms) |
| --- | --- | --- | ---: | --- |
| 0 | 150, 157, 150 | 7.49, 7.85, 7.50 | 7.50 | 182.81, 172.59, 181.17 |
| 2 | 157, 183, 177 | 7.82, 9.14, 8.82 | 8.82 | 184.83, 146.99, 156.37 |

The median throughput difference is approximately 17.6%, but the short fixed-time
trials varied substantially and processed different frame counts. They exclude Flutter,
real network delivery and full-section timing, and do not establish the required
end-to-end improvement or p95 gate. Raw results are local, ignored files
`backend/.cache/phase2_prefetch_v2_1.json` through `_6.json`; the local trial script is
`backend/.cache/phase2_prefetch_trials.py`.

The recovered `backend/.cache/phase2_flutter_ab.log` contains one completed
instrumented Windows Flutter session and a second session with no received frames.
The completed session received 525 frames: median/p95 round trip 135.90/200.50 ms,
read 5.15/6.60 ms, server processing 101.75/164.52 ms, client request delay
1.87/2.29 ms, image-stream decode 7.92/9.17 ms, and build/raster medians
0.85/0.69 ms. The 45-second checkpoint was 7.12 seconds of normalized video;
the saved acknowledgement was at 97.09 seconds. Same-host serialization-start to
client receipt was 20.01/36.35 ms, including scheduling, and not pure network time.
The summarizer estimates an ideal 3.06% cycle reduction if all reads overlapped,
under its pacing assumptions. Instrumentation and logging overhead are unknown, and
the effective server configuration is not independently established in this log.
This is diagnostic evidence, not a paired comparison. Reproduce with
`python scripts/summarize_watch_flutter.py .cache/phase2_flutter_ab.log --same-host`
from `backend/`.

The local fixed section has 525 normalized 1280x720 frames at 25 fps. A fresh comparison
with the first 525 normalized frames of the original stored 50 fps source found every
index and pixel identical; its SHA-256 is
`4b96538f112e3d99543ac368437a8592dd60dc1973f7e7d6e6f6de228ba9c132`.
The source is a single broadcast, not representative labeled singles/doubles footage.
Existing Phase 1 measurements describe the read/grab/resize split and the JPEG encode,
decode, client scheduling and image pipeline. The normalized image is JPEG-encoded
before inference, so skipping that conversion would alter model pixels and remains an
accuracy-sensitive experiment, disabled pending labeled evaluation.

## Implementation and checks

The producer bounds queued plus currently decoding frames to two, owns the reader,
and does not run inference or commit frames. Closing it joins the worker and now drains
queued frames, releasing their memory even if the iterator is retained. A blocked source
read can still delay shutdown. The Watch endpoint uses the queue only for complete
frame-by-frame playback and only when configured to depth 2; no wire fields were changed.

On November 18, 2026, the backend prefetch, profiling, Watch, parallel Watch and stream
tests passed (48 tests), including fake-pipeline order, pixel/timestamp/preview parity,
pause by withholding requests, stop, disconnect, failure and partial records. The two
Flutter Watch test files passed (9 tests). These do not establish real-model output or
annotated-video alignment, physical display timing, legacy-client compatibility across
all versions, or a performance win. The first backend test attempt could not access the
system pytest temporary directory in the sandbox; the rerun with access succeeded.

The November 18 follow-up aligned the recording commit with the analysis record. If
analysis fails before adding a frame, the recording does not include it; if it fails
after adding the frame, the corresponding image is recorded before saving. The legacy
`start` and `next` messages (without a playback field) were exercised with prefetch on.
Tests pause by withholding the next request, resume in order, and then stop, disconnect,
or inject failures before processing and before/after the analysis record commit. They
check the saved record, drained queue, saved recording and completed annotated export,
including frame counts and a moving visual marker on each frame. These use a generated
video and fake perception; they do not replace real-model accuracy or performance tests.
The Flutter pause control can have one previously requested frame in flight; it holds
that response and does not request another until playback resumes.

## Remaining work

Complete and review the Phase 1 baseline and overhead checks. Then run at least three
alternating actual Flutter baseline and queue trials on the same fixed section and
calibration, capture fixed-section time and median/p95 latency, and verify partial and
complete annotated-video alignment on representative footage. Record actual provider and
fallback diagnostics and
measurement conditions. Keep prefetch disabled unless the roadmap's 5% median and p95
gates and functional checks pass. Labeled footage is still required before promoting
any change to model inputs or other accuracy-sensitive behavior.
