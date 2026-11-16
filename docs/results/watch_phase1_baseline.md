# Frame-by-frame Watch phase 1 baseline

## Status

Phase 1 is **not complete**: no repeated controlled Flutter client baseline, labeled accuracy
evaluation, or exhaustive resource profile has been recorded.
One preliminary Flutter profile run is recorded below. The in-process measurements below
are diagnostic and cannot replace repeated actual Flutter trials. Do not advance to
accuracy-sensitive optimizations on this evidence.

## Preliminary actual Flutter run — November 16, 2026

With user approval, the Windows profile app loaded the original 565.28-second, 50 fps
Paris 2024 broadcast, selected **Analyze every frame**, and used doubles court calibration.
Automatic court detection failed; the manually placed corners recorded in the saved job
were `[[299.79, 674.30], [995.42, 670.80], [812.28, 325.92], [453.09, 322.10]]`
in the job's normalized coordinate space. Experimental focused player analysis was off.
The app displayed configured detector CUDA and pose TensorRT RTX providers; that display
does not establish graph placement or absence of fallback. The already-running backend
was warm and was not restarted; current configuration requests CUDA concurrency with
`frame_parallel_perception: auto`, but the running process configuration was not separately
verified. The app was built with `WATCH_PROFILE=true`, enabling client logging and server
diagnostics. Other desktop applications were active.

At 45.08 seconds on the client clock, the first completed response had processed 12.04
seconds of normalized video. The run was manually stopped after 426 frames (17.04 seconds
of normalized video); median/p95 client round trip was 137.12/201.84 ms. The saved
acknowledgement arrived at 65.28 seconds and the UI reported session saved at 69.01 seconds;
the 3.72-second difference is an observed interval, not an isolated encoder benchmark.
Median/p95 client handling was 0.98/1.50 ms and post-frame callback delay was 8.02/11.77 ms;
the latter is not a measurement of completed JPEG decode or display. The ignored local raw
log is `backend/.cache/watch_flutter_phase1.log`; saved job `85277c316c68` contains the
record and export. PowerShell 5.1 produced a UTF-16 log; the summarizer now reads it.

This single, instrumented, manually stopped run is not a complete fixed-section test,
does not measure profiler overhead or resource usage, and cannot validate a comparison
between sequential and concurrent modes. It is close to the previously mentioned 12-second
observation but does not establish that observation's conditions. Keep the Phase 1 gate open.

## Focused profiling follow-up — November 16, 2026

A dedicated **offline**, non-recording 35-frame run of `profile_watch_pipeline.py`
used the original Paris clip, the same doubles court (the saved normalized corners scaled
to source pixels), CUDA, concurrent perception, and the requested TensorRT RTX pose
provider. PyTorch/Kineto captured CPU and CUDA activities for the whole process, including
model setup and warmup, not just the 35 measured frames. The local trace is
`backend/.cache/phase1_cuda_trace.json`; the local invocation and trace summarizer are
`.cache/phase1_cuda_trace.py` and `.cache/phase1_trace_summary.py` under `backend`.
This is an intrusive diagnostic trace, not a throughput baseline or an actual Flutter run.

The trace recorded 57,019 kernel events; sampled CUDA activity included 1,036 pageable
host-to-device copies totaling 100.58 ms and 3,169 device-to-pageable-host copies totaling
8.89 ms, plus other copies and memset operations. It also recorded 6,763
`cudaStreamSynchronize` runtime calls totaling 396.77 ms host time. These are aggregate
event durations across initialization and processing, potentially overlapping, and cannot
be added to wall time or attributed to one model without correlating the trace. The offline
provider diagnostics reported detector CUDA and 247 pose nodes assigned to TensorRT RTX;
ONNX Runtime warned that some nodes were not assigned to preferred providers, without
identifying them in that output. This does not establish complete node placement or the
actual Flutter session's fallback state. Nsight Systems was not found on PATH or in the
usual NVIDIA application directory; its absence elsewhere was not established.

A separate offline OpenCV reader split measured three passes of 250 normalized frames on
the same 50 fps source, downsampled to 25 fps at 720p. Across the three passes, median
`cap.read()` times were 4.435–4.513 ms, skipped-frame `cap.grab()` medians were
0.067–0.074 ms, and resize medians were 0.978–1.025 ms. The second and third passes had
`grab()` p95 of 0.088 ms; the first had 0.350 ms. These isolated samples exclude the
thread scheduling and rest of the live app and are not a proof that input reading is
immaterial on other clips. The local measurement script is `.cache/phase1_read_split.py`.

These initial measurements were followed by the model-attributed and client measurements below.

## Model attribution and Flutter response measurements — November 16, 2026

A second 35-frame offline Kineto run used the same source and approximate calibration.
It recorded host timing ranges on the shuttle, detector and pose worker threads and
associated CUDA activities through their launch correlation IDs. The timestamps were
aligned using a host-clock anchor; attribution near a range boundary is approximate and
launches from other threads and initialization remain unattributed. Summed device kernel
event durations were approximately 291.36 ms for shuttle, 269.27 ms for detector and
159.11 ms for pose; 33.86 ms was unattributed. These sums overlap and are neither end-to-end
latencies nor evidence of separate exclusive device occupancy. Pageable host-to-device
copies associated with those paths totaled 48.83, 12.91 and 17.39 ms respectively;
device-to-pageable-host copies totaled 0.98, 3.15 and 0.27 ms. CUDA synchronization
runtime events attributed to those paths totaled 1.65, 140.11 and 163.75 ms host time,
respectively; those waits can include work submitted elsewhere. The capture includes
warmup, is highly instrumented, and excludes Flutter and recording. The trace, ranges,
and analysis script are in the ignored `backend/.cache/phase1_attributed_*` files.

ONNX Runtime's graph-assignment API reported 247 pose nodes assigned to TensorRT RTX for
the constructed pose session. A separately recreated detector session with assignment
recording and the configured CUDA/CPU providers reported 411 CUDA and 4 CPU nodes; this is
not proof that an already-running detector has identical session options or placement.
Names, types and providers are in `backend/.cache/phase1_node_placement.json`. Verify the
real session's activation and fallback separately; the provider review gate remains open.

A Windows Flutter profile run against an isolated backend on the **same machine** analyzed
259 normalized frames from the approved original video, with manual doubles calibration,
diagnostics and console logging enabled, and other applications and backend processes
active. At 45.08 s the cold-start-inclusive clock showed 5.80 s video; do not compare this
single instrumented startup to the earlier warm run as a speed change. Median/p95 were:

| Measurement | Median | p95 | Samples and meaning |
| --- | ---: | ---: | --- |
| Flutter response round trip | 158.28 ms | 247.82 ms | 259 responses; includes server processing and client delivery |
| Server JSON serialization | 0.98 ms | 1.34 ms | 258 responses; reported with the following frame |
| Server send await | 14.05 ms | 16.74 ms | 258 responses; not proof of client receipt |
| Serialization start to client receive | 22.21 ms | 42.51 ms | 259 same-host wall-clock samples; includes serialization, buffering, transmission and callback scheduling |
| Flutter JPEG codec sample | 10.17 ms | 11.32 ms | 13 separate diagnostic decodes of every 20th JPEG; includes async scheduling and codec creation |
| Response to image widget ready | 23.82 ms | 27.89 ms | 259 callbacks; includes scheduling and decoding, not physical display |
| Flutter build / raster | 0.88 / 0.75 ms | 1.80 / 1.19 ms | 653 application UI frames, not exclusively video frames |

The local log is `backend/.cache/watch_flutter_delivery.log`; reproduce the summary with
`python scripts/summarize_watch_flutter.py .cache/watch_flutter_delivery.log --same-host`
from `backend`. The same-host flag is invalid for different machines without independently
verified clock synchronization. The sampled codec performed an additional decode and may
have perturbed that run. Flutter raster timing is not physical presentation or screen
scanout, and the wall-clock delivery interval is not pure network transit. Profiling/logging
overhead and repeat trials have not been validated, so these figures are diagnostic, not
the final baseline.

A subsequent 384-frame actual Flutter run on the original, already-running backend used
an opt-in wrapper around the image stream's own codec, rather than a second decode. The
median/p95 interval from codec creation request through the first decoded image was
7.52/9.25 ms over 384 images. This includes asynchronous scheduling and codec setup but
excludes earlier immutable-buffer creation and later painting/presentation. Response to
image-widget-ready was 23.61/27.47 ms; raster for all 890 observed app frames was
0.66/1.12 ms. The video was normalized to 25 fps, manually calibrated for doubles, and
stopped and saved after 384 frames; at 45.09 s the clock showed 12.00 s of video. The
backend was warm and was not the newly instrumented server used for the delivery run, so
these measurements are not a controlled before/after comparison. Raw local data is in
`backend/.cache/watch_flutter_image_stream.log`. The actual image-stream decode now has
diagnostic evidence; OS composition, physical presentation and scanout remain unmeasured.
Windows Performance Recorder lists a `DesktopComposition` profile, but a requested
`wpr -start DesktopComposition -filemode` returned `0x80070005` (access denied); `wpr
-status` confirmed no recording was started. A future composition trace requires an
administrator-capable recording environment. Even an OS composition trace does not by
itself establish the moment photons appear on the physical display.

## Audited frame lifecycle

1. Flutter sends `start` over `/watch` with source-video court corners; the server opens
   a `FrameReader` using live resolution/fps settings, scales corners to normalized pixels,
   creates the session and model providers, and sends model availability and diagnostics.
2. Flutter requests one frame with `next`. `FrameReader` decodes, samples and downsizes
   the source to normalized BGR `uint8` frames. A 50 fps source commonly becomes 25 fps;
   higher source resolution can be reduced to 720p. The app waits for each result.
3. The server JPEG-encodes the frame, wraps the frame index and video timestamp, and
   decodes the JPEG in the session. This is a lossy pixel conversion before inference.
4. CUDA Watch runs TrackNet and player/pose work concurrently, with a join before ordered
   record updates. TrackNet builds a sliding window of resized RGB frames, runs PyTorch
   on the selected device, decodes heatmaps to shuttle coordinates, and maintains
   temporal state. YOLOX detects people; court-aware candidate filtering runs before
   batched RTMPose; player identity tracking and optional far-player recovery use prior
   observations and court mapping. Pose crops use CPU NumPy arrays and ONNX Runtime
   sessions; input/output transfers and execution-provider placement require tracing.
5. The session writes its recording and updates the shared record, then sends JPEG and
   events. Flutter base64-decodes the preview, schedules an image/UI update, and requests
   the next frame subject to playback pacing. A Flutter post-frame callback is not proof
   of completed image decode or display.
6. On stop/end/disconnect, the processed session is saved and the annotated video is
   rendered separately. The writer uses FFmpeg `libx264` by default, optional NVENC with
   initialization probe, or an OpenCV fallback when FFmpeg is unavailable.

The standard TrackNet window is assembled as channel-first `float32` RGB/background
values scaled by 1/255, converted from a NumPy batch to a Torch tensor and transferred
to the selected device; the CUDA path uses autocast. Its latest output heatmap is copied
back to CPU/NumPy for coordinate decoding, a device-to-host synchronization point.
RTMPose inputs are per-person preprocessed crops stacked as channel-first `float32`
NumPy batches; `session.run` returns model outputs for CPU postprocessing and tracker
updates. The actual ONNX provider graph partition and implicit copies must be established
by a provider trace, not inferred from the requested device. Overlay drawing uses OpenCV
on CPU BGR frames, piped as `bgr24` to FFmpeg for H.264/yuv420p output. Per-frame record
and player-tracker updates remain ordered and stateful across consecutive frames.

| Boundary | Entry point and execution | Available measurement or remaining gap |
| --- | --- | --- |
| Client requests and preview | `WatchScreen.next` and `onMessage`; Dart base64 decode, widget scheduling and image decode | Opt-in Flutter request/receive and post-frame callback timings; callback does not measure completed image decoding or network transit separately. |
| Input and JPEG | `FrameReader.frames`/`_normalize`, `watch_video`, `LiveSession._decode`; OpenCV CPU and JPEG byte buffers | Read, resize, encode and decode wall times; exact I/O and `cap.grab` split is not yet measured. |
| Shuttle | `ModelPerception._shuttle`, `track_windows`, heatmap conversion; Torch CPU preparation and CUDA/PyTorch when available | Per-frame inclusive wall time; precise GPU kernels, allocations and host/device transfers need CUDA/Nsight tracing. |
| People and pose | `ModelPerception._players`, `detect_watch`, YOLOX detector, `_batched_body_pose`/RTMPose | Inclusive detection, selection and pose wall times/candidate counts; isolated profiler can break down detector and pose methods. Provider configuration is not proof of every node's device placement. |
| Tracking and analysis | `CourtPlayerTracker.update`, `FarPlayerRefiner.refine`, `StreamAnalyzer._tick`; ordered stateful operations | Tracker, recovery and tick wall intervals; label-based identity, keypoint, shuttle and hit accuracy is still needed. |
| Save and export | `LiveManager._save`/`_render`, `render_video`, `VideoWriter`; CPU drawing and FFmpeg encoder | Recording and export wall timing and encoder choice; wall time writing to a pipe includes possible encoder backpressure. |

## Existing measurements and limitations

The previous three 45-second TestClient runs per mode found median progress of 11.24 s
sequential and 14.72 s concurrent. They included server/model setup, but excluded Flutter,
network, and upload. See `watch_complete_parallel_nov16.md` for every run and parity
limitations. In a new 15-second diagnostic run with real models, 102 normalized frames
(4.08 s video) were processed in 15.05 s including 3.68 s setup. Median server wall
intervals were 67.38 ms for the player path, 39.11 ms for the shuttle path, 25.24 ms for
the detector, and 39.48 ms for pose work. These timers are nested and/or concurrent,
include CPU preparation and waits, and are not additive or CUDA kernel timings.

During that short diagnostic run, sampled device-wide GPU use had a median of 28% and
maximum of 41%; sampled device-wide VRAM usage peaked at 5,369 MiB and included other
applications. The process sampled median CPU was 232% (one logical core = 100%) and
median resident memory about 2.44 GB. The samples are snapshots, not exact peaks or
proof that the GPU was idle. The machine reported an Intel Core Ultra 7 255HX (20 cores,
20 logical processors), approximately 31.7 GiB system RAM, RTX 5070 Ti Laptop GPU with
12,227 MiB VRAM, and NVIDIA driver 616.87. Power limit was not reported.

The diagnostic run confirmed TensorRT RTX assignment for pose and CUDA was configured
for the detector, with CUDA/CPU fallback providers. The existing exact-output comparison
covered 120 frames of one doubles broadcast recording under two court configurations;
it was not representative labeled singles/doubles accuracy validation. The user's
approximately 12-second observation needs confirmation of mode, elapsed time, clip,
whether startup was included, and whether the backend and app had been restarted.

Six alternating warm-session in-process runs with resource sampling and a 25-second
measurement window compared profiling disabled versus enabled. Video progress was
7.80, 8.44 and 8.36 seconds without profiling, and 8.04, 8.00 and 8.60 seconds with
profiling. The median normalized throughput was 8.35 versus 8.01 frames/s, a roughly
4.1% reduction in this small, noisy test. Each run warmed ten frames in the same server
process before measurement. This supports the server-only <=5% overhead gate for this
clip, but does not validate Flutter console-logging overhead, other workloads, actual
network timing, or the device-wide samples as process-specific GPU memory. Raw local
trial output is stored under the ignored `.cache` directory and contains no video pixels.
System-wide CPU and RAM samples were added to the resource sampler after this comparison;
repeat the overhead check if those additional samples are used in the final baseline.

For a completed-section check, one instrumented warm run processed a previously saved,
re-encoded 21-second (525 normalized-frame) recording in 61.45 seconds, including 1.17 s
setup, at 8.54 normalized frames/s. The first response after 45 seconds represented 15.32 s
of video at 45.03 s elapsed. Median/p95 frame round trip was 104.40/163.84 ms, and export
after the saved acknowledgement took 3.52 s. A prior run of the same section took 61.56 s.
These were in-process server tests with no Flutter rendering or network latency; they do
not measure the original nine-minute upload or a representative labeled match.

An isolated 80-frame original-video profile with detector and pose method wrappers measured
8.51 frames/s, 3.55 s total in detector `inference` across 84 calls, 1.54 s total in 1,176
pose-crop calls, and 1.30 s total in 161 pose-session calls. Detector preprocessing and
postprocessing totaled 0.11 s and 0.01 s. The extra detector/crop calls include recovery
work; they should not be interpreted as one call per frame. These are instrumented host
wall intervals, with model warmup and possible overlap/synchronization. They are not GPU
kernel timings and do not establish their contribution to Flutter end-to-end latency.

## Findings and next measurement

- The player/pose path is substantial in the measured workload; its full cost also
  includes candidate selection, preparation, recovery and tracker work. The precise
  split between GPU execution, CPU preparation, data transfers and synchronization
  remains unknown.
- The sampled selection and tracker intervals were small in the short test; this does
  not prove they are negligible for all footage. Compare over longer representative
  clips before deciding whether to optimize them.
- Do not enable focused candidate selection, change model precision or replace TrackNet
  without held-out labeled player, shuttle and event measurements.
- Gather three real Flutter frame-by-frame runs in each sequential/concurrent mode with
  fixed calibration and input, including cold and warm starts, a 45-second checkpoint,
  complete section time, and export time. Compare instrumented versus uninstrumented
  runs with the same resource sampling and verify the profiling overhead is <=5% before
  interpreting fine-grained numbers.
- Use the optional per-frame tracing and `--detector-breakdown`/`--pose-breakdown`
  profiler flags in `docs/SETUP.md`; use Nsight Systems or CUDA events separately to
  investigate actual device execution and transfer timelines. Do not add wall times
  from concurrent or nested spans.
