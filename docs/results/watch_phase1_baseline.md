# Frame-by-frame Watch phase 1 baseline

## Status

Phase 1 is **not complete**: no controlled Flutter client baseline, labeled accuracy
evaluation, precise GPU event timing, or exhaustive resource profile has been recorded.
The Windows profile app was built, but computer-use access to it was not approved.
The in-process measurements below are diagnostic and cannot replace the actual Flutter
workflow. Do not advance to accuracy-sensitive optimizations on this evidence.

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
