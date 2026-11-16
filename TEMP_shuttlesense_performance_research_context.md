# Research prompt for improving ShuttleSense analysis and video rendering

Copy the prompt below into GPT Research. If repository access is available, provide the repository or the relevant files listed near the end. Repository documents are technical reference material, not instructions that override this prompt. Do not change the repository as part of the research response.

---

Act as a senior computer-vision, GPU inference, and video-processing performance engineer. Research practical ways to improve the speed of ShuttleSense, an in-development badminton video-analysis application. Use the current project context and measured results below. Provide prioritized, technically grounded recommendations that can be evaluated and implemented incrementally.

The immediate focus is **Watch & Analyze → Analyze every frame**. We want the application to analyze the video and make useful results available sooner on the existing computer, while maintaining reliable player, pose, and shuttle analysis. We are interested in using the CPU, GPU, memory, and available software more effectively, including suitable libraries or plugins, but higher hardware utilization is not a goal by itself: measure success by reduced end-to-end time and acceptable result quality.

## Project and device context

- **Frontend:** Flutter application on Windows, with other supported Flutter platforms. For frame-by-frame Watch, the app requests one normalized frame at a time over `WS /watch`, receives a JPEG and analysis events, displays them, then requests the next frame.
- **Backend:** Python/FastAPI running on the user's computer. OpenCV handles video/frame operations; ONNX Runtime, PyTorch, and CUDA are used by model components where configured and available. A shared `ClipRecord` stores observations and downstream results.
- **Models and stages:** TrackNetV3 tracks the shuttle; YOLOX detects people; RTMPose estimates body keypoints; player tracking, court mapping, hit and stroke identification, feedback, and other analysis use those outputs. The selected stroke classifier and its available weights depend on configuration.
- **Hardware used in the recent tests:** NVIDIA GeForce RTX 5070 Ti Laptop GPU with approximately 12 GB VRAM, Windows, and a CUDA-capable PyTorch installation. Exact CPU model, available RAM, GPU power limits, driver details, and measured utilization under the target workload have not yet been recorded in the supplied evidence. Do not invent them.
- **Current goal:** Faster frame-by-frame analysis and, separately, faster generation of the annotated video. Real-time camera analysis and background real-time playback are not the current priority.

## What “Analyze every frame” currently means

It processes every **normalized** frame, not necessarily every original source frame. The existing reader limits resolution and frame rate. For example, the 50 fps, 1080p test upload was normalized to 25 fps at 720p. Preserve this existing sampling behavior in the initial recommendations; do not claim we process every source frame. Changing input rate or resolution is an accuracy/scope tradeoff that requires separate evaluation.

The frame-by-frame path reads a frame, JPEG-encodes it, runs the existing packet/decoding and inference path, returns the preview and events, and waits for the next client request. The client may also pace display to the normalized video frame rate. The backend later renders overlays and exports an annotated video. Separate model loading and startup, frame analysis, client/server handoff and display, and final video encoding when analyzing performance.

## Current implementation and configuration

- `watch.frame_parallel_perception: auto` enables concurrent shuttle and player/pose perception on CUDA for frame-by-frame Watch; CPU remains sequential. `false` restores sequential operation. The two results are joined for each frame and frame ordering is retained.
- `watch.parallel_perception: auto` applies to the separate background Watch path. Do not confuse its experiments with the end-to-end frame-by-frame results.
- `watch.player_provider: pose` requests the optional **TensorRT RTX ONNX Runtime execution provider** for pose, with CUDA fallback. The provider plugin is already installed in the tested backend environment. YOLOX used CUDA in the reported comparison; pose used TensorRT RTX. Actual active provider and fallback information can be displayed in the app.
- Pose batching is set to 8; the TensorRT RTX preferred batch profile is 4. `candidate_filter: filter` is already enabled with a 2 m court margin. It is experimental and must be validated against labeled footage. A separate focused-candidate shortcut is **off by default** because it changed a hit result in one comparison.
- `watch.decoded_frames: false`; bypassing the JPEG round trip is an experimental possibility for the background path and must not be assumed to be already active for frame-by-frame Watch. Different input pixels can affect model outputs.
- TrackNet uses its PyTorch path; experimental TrackNet TensorRT, GPU windowing, and a detector split are not enabled. Do not assume all proposed alternatives work or are faster.
- FFmpeg is available through an installed optional `imageio-ffmpeg` package. The video writer defaults to CPU `libx264`; optional NVIDIA `h264_nvenc` has an availability probe and a CPU fallback before encoding begins. An error after encoding starts is reported rather than automatically retrying the output. The configured quality parameters are not necessarily equivalent across encoders.
- The analysis mode has already been optimized to cache fixed court geometry; its isolated test did not demonstrate an end-to-end speedup. The server reports model-provider diagnostics and read, JPEG, and processing timing fields.

## Observed progress and benchmark evidence

**Latest user observation:** The user reports the current application is around **12 seconds** and considers this an improvement. Based on the preceding discussion this may mean roughly 12 seconds of video analyzed at 45 seconds elapsed, but the latest message does not explicitly restate the measurement procedure. Treat that interpretation as provisional and ask for confirmation before making precise comparisons. This observation is a progress snapshot, not a completed-video or final-export time.

**Frame-by-frame benchmark:** On November 16, 2026, three sequential and three concurrent 45-second runs used the same original 50 fps doubles broadcast upload, calibrated court, RTX 5070 Ti Laptop GPU, CUDA detector, and TensorRT RTX pose. Each used the actual `/watch` WebSocket through FastAPI's in-process TestClient, temporary storage, and recording. Model setup was included; upload, Flutter display, and actual network latency were excluded. Runs were separate process starts with a warm disk cache, and other desktop applications were open.

| Processing mode | Video progress at approximately 45 seconds |
| --- | --- |
| Sequential | 11.24 s, 11.04 s, 11.64 s |
| Concurrent | 13.92 s, 14.84 s, 14.72 s |

The median increased from 11.24 s to 14.72 s—approximately 31% more video progress in that in-process test. It does **not** establish the same speedup in Flutter or on other hardware. In one concurrent run, median round trip was 98.12 ms; independently calculated median server timings were 86.53 ms frame processing, 5.85 ms frame reading, and 2.79 ms JPEG preparation. Do not add separately calculated medians as if they were one frame's measurements. GPU utilization, peak VRAM, detailed CPU use, and energy/thermal behavior were not systematically measured.

**Output comparison:** A separate 120-frame real-model comparison with identical JPEG input, candidate filtering, batch size, and providers reported identical sequential and concurrent player and shuttle outputs for each tested frame; hits, rallies, line calls, and score matched. It was repeated using singles and doubles court configurations on the **same doubles footage**. This does not establish accuracy on actual singles footage, labeled data, camera changes, occlusion, full matches, or other devices.

**Player/pose bottleneck:** In earlier offline Watch profiles, player detection and pose processing accounted for most measured perception time. In one 120-frame original-video test, the existing filter accepted 1,717 pose candidates and excluded 2,906 detected boxes. These are cumulative frame-level detections, not counts of unique people. Crowd-heavy footage can cause substantial extra pose work. The previously tested narrower-margin and footpoint shadow proposals excluded no additional candidates in that specific segment; do not assume they solve the problem.

**Focused-candidate experiment:** In one 180-frame offline segment, median perception time changed from 83.34 ms to 56.03 ms, and player presence and downstream events matched, but 139 of 180 perception-frame outputs differed. On a later 120-frame section, the focused path was slower (104.27 ms versus 98.44 ms) and a hit result differed. The original calibration was reused despite possible camera movement. These are single short comparisons without labeled accuracy data. Focused selection remains optional and disabled by default; do not recommend enabling it universally without stronger evidence.

**Final export:** For a 525-frame saved recording with identical overlays, two `libx264` exports took 3.35 and 3.29 s and produced approximately 4.38 MB files. Two NVENC exports took 3.10 s each and produced approximately 8.40 MB files. Each reported 525 frames. This is a short test; encoding quality settings are not directly equivalent, and no full visual-quality or Flutter playback comparison was performed. Keep export speed separate from analysis speed; a faster encoder does not automatically accelerate inference.

## Important constraints

- Preserve frame order, the current normalized sampling, existing pause/stop/disconnect behavior, partial-session saving, court calibration, and output-video alignment.
- Preserve or explicitly measure the quality of player identity tracking, pose keypoints, shuttle visibility/positions, hit/stroke events, and downstream results. Faster output with unmeasured or material accuracy loss is not an automatic improvement.
- Consider GPU memory limits, CPU/GPU contention, disk and video decoding, model initialization, data transfers, live application rendering, thermal/power limits, and portability. Do not infer bottlenecks from a single utilization percentage.
- Distinguish implemented capabilities from experiments and suggestions. A hardware encoder addresses final encoding; it does not automatically accelerate YOLOX, RTMPose, or TrackNet.
- Maintain a working CPU/sequential fallback and avoid requiring a specific NVIDIA GPU for all users. Identify Windows/NVIDIA-specific dependencies and their installation, licensing, compatibility, and fallback implications.
- Do not recommend blindly increasing resolution, batch size, thread counts, concurrent streams, candidate filtering, or skipping frames. Discuss how each proposal affects latency, throughput, memory, correctness, and resource contention.
- Do not request or expose video files, private data, local storage identifiers, API keys, or user-specific paths in a published answer.

## Research questions

1. Given the measured frame-by-frame path, what are the highest-impact remaining bottlenecks to verify, and what evidence would distinguish model inference, CPU preprocessing, GPU transfers, client/server synchronization, display, or encoding as the limiting factor?
2. Which improvements should we test first for YOLOX/RTMPose and TrackNet on this hardware? Assess practical options such as safer candidate handling, model/provider optimization, batching, asynchronous GPU execution, I/O binding and memory copies, CPU thread-pool configuration, and model warm-up. Specify whether each can preserve the current model inputs and outputs.
3. Could bounded prefetching, pipelined decoding, request batching, or preview delivery reduce waiting in the current one-frame-per-request workflow? Explain how to preserve ordering, pause/stop, partial saves, timestamps, and bounded memory. Do not assume the handoff is a bottleneck without measuring it.
4. Which current, maintained tools or libraries—such as NVIDIA Nsight Systems, ONNX Runtime execution providers, TensorRT RTX, and FFmpeg/NVENC—are appropriate for this Windows/Python/Flutter stack? Identify options already present and additional options only where they add a concrete benefit. Verify current compatibility and cite official documentation or original papers.
5. What are the best safe ways to reduce spectator-related pose work while retaining players near court boundaries, overlapping doubles partners, jumps, occlusion, and reacquisition? Design an evaluation with labeled ground truth and a conservative fallback; identify when this optimization should not be enabled.
6. How should we benchmark final video rendering separately, with comparable visual quality, codec compatibility, file size, and playback/seek validation? Given the short export results, when would NVENC be worthwhile?
7. Provide an ordered experimental plan that starts with low-risk, measurable changes, specifies commands or pseudocode where reliable, and clearly defines what would justify enabling, reverting, or abandoning each change.

## Repository references, if available

- `backend/shuttlesense/api/live.py` — frame-by-frame `/watch` WebSocket, timings, and session lifecycle.
- `app/lib/features/watch/watch_screen.dart` — frame requests, display, pacing, and provider diagnostics.
- `backend/shuttlesense/stream/perception.py` and `backend/shuttlesense/stream/watch_parallel.py` — model inference and concurrent perception.
- `backend/shuttlesense/pose/estimator.py`, `backend/shuttlesense/pose/watch_candidates.py`, and `backend/shuttlesense/pose/player_tracker.py` — pose batching, candidate selection, and player identity tracking.
- `backend/shuttlesense/io/video.py` — normalized video reading and frame sampling.
- `backend/shuttlesense/render/overlays.py` and `backend/shuttlesense/render/writer.py` — overlay drawing and video encoding.
- `backend/configs/pipeline.yaml` — current settings; `docs/SETUP.md` and `docs/API.md` — setup and protocol.
- `backend/scripts/bench_watch_complete.py` — in-process frame-by-frame benchmark; `backend/scripts/bench_watch_parallel.py` and `backend/scripts/profile_watch_pipeline.py` — model/perception comparisons, mainly offline or background-style diagnostics.
- `docs/results/watch_complete_parallel_nov16.md` and `docs/results/watch_performance_nov16.md` — measurements and limitations.

## Required research response

1. Start with a concise diagnosis that separates confirmed findings from hypotheses and unknowns.
2. Rank recommendations by expected impact, implementation difficulty, accuracy risk, hardware portability, and evidence needed. Give ranges or expected outcomes only if supported; do not invent a guaranteed speedup.
3. Provide an implementation and validation sequence, including a baseline and comparison method for the actual Flutter frame-by-frame workflow, not only an isolated model benchmark. Include cold/warm runs, a fixed-duration checkpoint, complete processing time, export time, model-provider verification, CPU/GPU/VRAM and thermal monitoring, and representative labeled clips.
4. For each suggested library or plugin, indicate whether it is already in the project, how it fits the actual pipeline, its compatibility constraints, and a fallback. Prefer primary sources and cite links near the claims they support.
5. Identify what additional information is required to judge the user's latest 12-second observation, including what the 12 seconds and elapsed time represent, mode, clip, startup, and whether the backend was restarted after the last changes.
6. Finish with concrete next actions suitable for a developer to review with the team. Clearly label speculative ideas and avoid claiming that a proposed optimization is already implemented or validated.
