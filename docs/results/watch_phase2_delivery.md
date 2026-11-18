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

## Frame transformation and copy audit — November 18, 2026

This audit covers frame-by-frame **Analyze every frame**, with default JPEG input,
TrackNet's Watch preprocessing cache, RTMLib/ONNX Runtime pose and the normal export.
It distinguishes Python-visible operations from copies internal to OpenCV, codecs,
ONNX Runtime, PyTorch, GPU drivers and Flutter, which are not fully observable here.

| Stage | Transformations and allocations | Assessment |
| --- | --- | --- |
| Video input | OpenCV decodes a source frame to BGR; `FrameReader` skips excess source frames and conditionally resizes to normalized dimensions. The optional queue retains up to two decoded/decoding frames. | The default 50 fps sample becomes 25 fps at 1280x720. Normalization resizes only when dimensions differ; this is not a second per-model resize. |
| Watch transport to analysis | `imencode` makes a JPEG buffer; `tobytes()` copies it; concatenating the header and JPEG creates a packet; packet slicing makes another JPEG bytes object. `np.frombuffer` is a view over those bytes; `imdecode` creates a BGR image. Session resize occurs only if decoded dimensions differ. | Avoiding a packet copy could be explored, but needs parity and end-to-end measurements. Bypassing JPEG decode changes the model's pixels. |
| Preview and client | The encoded JPEG is base64-encoded to bytes then ASCII text and included in JSON. Flutter parses JSON, base64-decodes to bytes, and `MemoryImage`/the image codec decodes it for display. | The server inference decode and client preview decode are separate consumers. Profiling wrappers add work only when requested. |
| Shuttle model | Watch resizes each new BGR frame to 512x288 RGB once and retains the overlapping temporal window. It recomputes its initial rolling background median; input construction can resize that median and concatenates/casts/normalizes channels, stacks the batch and transfers it to the device. Heatmaps return to CPU for decoding. | Cache avoids repeatedly resizing each window frame. Channel reversal is a NumPy view, but OpenCV and later operations may allocate. Removing or sharing preprocessing requires exact tensor and temporal parity and measurement. |
| Player and pose models | RTMLib YOLOX conditionally resizes and pads for the detector, then transposes and makes a contiguous float32 input. RTMPose applies a per-person affine crop and normalization; Watch batching makes contiguous float32 crops and stacks them for ONNX Runtime. Recovery can run another detector on a frame slice; tracker shirt-color work copies a contiguous crop and converts BGR to HSV. | Detector and pose require different model inputs; a crop slice may be a view but the model preprocessing allocates. Provider-internal transfers and workspace allocations are not measured by this code audit. |
| Recording and export | The decoded inference image is written to the session's OpenCV MP4 recording. After saving, the recording is decoded again, overlays are drawn, and FFmpeg receives a contiguous BGR byte copy (`tobytes`); the writer resizes only on a dimension mismatch. Some overlay regions explicitly copy pixels. | Export is a separate phase; changing its encoding or drawing needs its own quality and playback checks. |

The background-Watch-only `watch.decoded_frames` option already passes the normalized
BGR array directly into analysis, but defaults to false and does **not** activate for
frame-by-frame `/watch`. It changes input relative to the JPEG-decoded baseline. No
decoded-frame shortcut was enabled, and no transport or model-input optimization was
introduced by this audit.

On the first 100 normalized frames of the locally stored 50 fps doubles broadcast,
`scripts/audit_watch_jpeg.py` found that 63.050% of BGR channel values changed after the
default JPEG encode/decode, with mean absolute error 1.026 and maximum 51 on a 0–255
scale. Median encoded size was 256,568 bytes; isolated median encode/decode wall times
were 2.681/3.480 ms on this machine. This is one contiguous sample, not a measure of
model accuracy or a controlled application benchmark. The script uses OpenCV defaults
and the same default normalization dimensions/FPS; set `--height` and `--max-fps` to
match non-default Watch settings. Reproduce from `backend/` with:

```powershell
.\.venv\Scripts\python.exe scripts/audit_watch_jpeg.py --video PATH --frames 100
```

The earlier warm, in-process 525-frame profile recorded median JPEG encode 2.85 ms,
JPEG decode 3.78 ms and recording 2.84 ms; these nested/overlapping wall timings are
not additive and exclude Flutter. In the separate instrumented Flutter run above,
the client image-stream decode median was 7.92 ms and response handling 0.99 ms.
Different clips, logging, process scheduling and startup conditions prevent a direct
comparison of those two runs. Native allocations and transfer durations need a separate
memory/accelerator trace. A pixel-preserving copy reduction should only be retained
after exact input/output checks and the roadmap's repeated Flutter performance gate;
decoded-frame input additionally requires held-out labeled accuracy evaluation.

## Remaining work

Complete and review the Phase 1 baseline and overhead checks. Then run at least three
alternating actual Flutter baseline and queue trials on the same fixed section and
calibration, capture fixed-section time and median/p95 latency, and verify partial and
complete annotated-video alignment on representative footage. Record actual provider and
fallback diagnostics and
measurement conditions. Keep prefetch disabled unless the roadmap's 5% median and p95
gates and functional checks pass. Labeled footage is still required before promoting
any change to model inputs or other accuracy-sensitive behavior.
