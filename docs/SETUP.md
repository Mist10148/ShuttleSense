# Setup guide

How to get the backend and the app running on each machine. This page also replaces per-folder READMEs: data, weights and sample-clip instructions are all here.

- [1. Prerequisites](#1-prerequisites)
- [2. Clone](#2-clone)
- [3. Backend on a laptop (primary)](#3-backend-on-a-laptop-primary)
- [4. Backend on Google Colab (fallback)](#4-backend-on-google-colab-fallback)
- [5. Weights](#5-weights)
- [6. Datasets](#6-datasets)
- [7. App](#7-app)
- [8. Connecting a phone or tablet to the laptop](#8-connecting-a-phone-or-tablet-to-the-laptop)
- [9. Troubleshooting](#9-troubleshooting)

## 1. Prerequisites

| Tool | Needed for | Install |
| --- | --- | --- |
| Git | everything | <https://git-scm.com> |
| Python 3.11–3.13 | backend | <https://www.python.org/downloads/> (tick "Add to PATH") |
| NVIDIA driver + CUDA-capable GPU | fast backend | Latest Game Ready/Studio driver; PyTorch wheels bundle CUDA |
| ffmpeg | H.264 export | Windows: `winget install Gyan.FFmpeg`; macOS: `brew install ffmpeg`; Colab: preinstalled |
| Flutter 3.41 stable | app | <https://docs.flutter.dev/get-started/install>, then `flutter doctor` |
| Android Studio + SDK | Android builds | From the Flutter install guide; enable USB debugging on the phone |
| Visual Studio 2022, "Desktop development with C++" | Windows builds | Visual Studio Installer |
| Xcode (macOS only) | iOS/iPadOS builds | App Store |
| Chrome or Edge | web builds | — |

## 2. Clone

```bash
git clone --recurse-submodules https://github.com/Mist10148/ShuttleSense.git
cd ShuttleSense
# Already cloned without submodules?
git submodule update --init --recursive
```

## 3. Backend on a laptop (primary)

```bash
cd backend
python -m venv .venv
# Windows (PowerShell):  .venv\Scripts\Activate.ps1
# Windows (Git Bash):    source .venv/Scripts/activate
# macOS / Linux:         source .venv/bin/activate

pip install -r requirements/base.txt -r requirements/dev.txt
pip install -e .
```

Check what is installed and what is missing (✓ / ✗ per item; exit code 0 when the base stack is OK):

```bash
python scripts/check_env.py
```

The base stack runs the stub pipeline, tests and lint. For the real models, first
install the CUDA wheel for the PyTorch version pinned in `requirements/ml.txt`.
Select a CUDA build that supports your OS, Python version and driver. [PyTorch install selector](https://pytorch.org/get-started/locally/)

```bash
pip install torch==2.14.1 --index-url https://download.pytorch.org/whl/<cuda-tag>
pip install -r requirements/ml.txt
pip install --no-deps rtmlib==0.0.16
python -c "import torch; print(torch.__version__, torch.cuda.is_available())"
python -c "import onnxruntime as ort; print(ort.get_available_providers())"
```

On the team's Windows RTX 5070 machine, Python 3.13 with the `cu130` wheel was
verified with PyTorch 2.14.1 and ONNX Runtime 1.31.1. After installing FFmpeg
with WinGet, open a new terminal so its updated PATH is visible. If an existing
terminal cannot find FFmpeg, run
`$env:PATH = "$env:LOCALAPPDATA\Microsoft\WinGet\Links;$env:PATH"` in that
terminal. To use real
models, remove `SHUTTLESENSE_FAKE_PIPELINE` from the backend terminal before
starting the server; demo mode ignores the uploaded footage for analysis.

Use one ONNX Runtime package per environment. RTMLib's dependencies include the
CPU package, which can overwrite the GPU package's Python module. The commands
above use a clean environment with `onnxruntime-gpu` and the base stack's OpenCV.
For CUDA pose, check for `CUDAExecutionProvider`; if it is missing after a prior
RTMLib install, uninstall `onnxruntime` and reinstall the pinned GPU wheel.
Install a matching torchvision wheel separately for the optional Keypoint R-CNN
backend. [ONNX Runtime Python setup](https://onnxruntime.ai/docs/get-started/with-python.html)

Run the server so other devices on the network can reach it:

```bash
uvicorn shuttlesense.api.main:app --host 0.0.0.0 --port 8000
# open http://localhost:8000/docs to try the endpoints
```

Run the pipeline from the command line instead of the API:

```bash
python -m shuttlesense.run --video ../samples/rally01.mp4 --out outputs/rally01
```

Check your work before pushing:

```bash
ruff check . && ruff format --check . && pytest
```

### Backend environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `SHUTTLESENSE_STORAGE_DIR` | `storage` (inside `backend/`) | Uploads and job outputs |
| `SHUTTLESENSE_TOKEN` | unset | Require `Authorization: Bearer <token>`; set it whenever the server is exposed through a tunnel |
| `SHUTTLESENSE_DEVICE` | auto | `cuda` or `cpu` |
| `SHUTTLESENSE_CORS_ORIGINS` | `*` | Comma-separated origins for the web build |
| `SHUTTLESENSE_MAX_UPLOAD_MB` | `1024` | Upload size limit |
| `SHUTTLESENSE_CONFIG` | `configs/pipeline.yaml` | Pipeline config file |
| `SHUTTLESENSE_LIVE_SESSION_TTL_S` | `60` | How long a dropped live session waits for the app to resume before it is saved |
| `SHUTTLESENSE_ANTHROPIC_API_KEY` | unset (falls back to `ANTHROPIC_API_KEY`) | Turns the coach chat on. Keep it in the backend's environment only, never in the app or the repo; see [PRIVACY.md](PRIVACY.md) for what is sent |
| `SHUTTLESENSE_CHAT_MODEL` | `claude-opus-5-5` | Claude model for the coach chat |
| `SHUTTLESENSE_CHAT_EFFORT` | `medium` | `low` to `max`; lower is cheaper and faster |
| `SHUTTLESENSE_CHAT_MAX_MESSAGES` | `20` | Questions allowed per session |
| `SHUTTLESENSE_CHAT_MAX_DIGEST_CHARS` | `24000` | Session data sent per question; longer sessions are summarized per rally |
| `SHUTTLESENSE_FAKE_PIPELINE` | `0` | `1` returns the golden record (`backend/tests/fixtures/golden_record.json`) scaled to each upload instead of running models, so the app shows full results without a GPU. CLI equivalent: `python -m shuttlesense.run --fake ...` |

## 4. Backend on Google Colab (fallback)

1. Open [`backend/notebooks/shuttlesense_colab.ipynb`](../backend/notebooks/shuttlesense_colab.ipynb) in Colab (File > Open notebook > GitHub).
2. Runtime > Change runtime type > **T4 GPU**.
3. Set a token in the first cell (`SHUTTLESENSE_TOKEN = "..."`), then Run all.
4. The last cell prints a `https://<random>.trycloudflare.com` URL. Enter it and the token in the app's connect screen.

The session (and its uploads) disappears when Colab disconnects. Download results before closing the tab.

## 5. Weights

Stroke weights come with the repository. TrackNetV3 and InpaintNet checkpoints are
stored outside Git and verified against hashes from the pinned upstream release.

```bash
cd backend
python scripts/download_weights.py            # all weights
python scripts/download_weights.py --only tracknet
python scripts/download_weights.py --force    # re-download, e.g. after a checksum error
```

If the team Hugging Face repository needs credentials, use the
[pinned TrackNetV3 README](https://github.com/qaz812345/TrackNetV3/blob/6eda442ada1740573f200f836d93edc9a541ee86/README.md)
to download the public checkpoint archive. Copy the two `.pt` files from `ckpts/`
to `backend/weights/tracknet/` and run `python scripts/download_weights.py --only tracknet`.
The script checks each file against its pinned SHA-256. A failed verification reports
the mismatch and preserves any existing checkpoint.

Expected layout after download:

```
backend/weights/
├── tracknet/TrackNet_best.pt
├── tracknet/InpaintNet_best.pt
└── strokes/                     # committed with the repo (D30), not downloaded
    ├── stroke_cnn.pt            # 1D CNN
    ├── stroke_lstm.pt           # LSTM
    └── stroke_rf.npz            # Random Forest (plain NumPy arrays)
```

The three stroke models come with `git clone`; `download_weights.py --only strokes` only checks
them against the pinned checksums and never deletes a file you retrained. Pick the model per
clip in the app's upload options, with `--stroke-model` on the CLI, or set the server default
in `configs/pipeline.yaml` (`stages.strokes.algorithm`). The CNN and LSTM need PyTorch; the
Random Forest runs with the base requirements alone.

RTMLib downloads and caches the YOLOX and RTMPose ONNX files on first use.

## 6. Datasets

Datasets are not committed (`backend/data/` is gitignored) and match videos are never redistributed. Follow ShuttleSet's terms of use. Put each match video in `backend/data/videos/` under the file name given in the `video` column of `data/shuttleset/match_list.csv`.

```bash
cd backend
python scripts/download_shuttleset.py                 # annotations + match list -> data/shuttleset/
python scripts/extract_clips.py --matches 1-22        # Member 3
python scripts/extract_clips.py --matches 23-44       # Member 4
python scripts/extract_features.py                    # -> data/features/*.npz
python scripts/train_stroke_classifier.py --algorithm cnn --seeds 1,2,3 --splits configs/splits.json
python scripts/dataset_stats.py                       # -> docs/results/dataset.md
```

The match split is committed as `configs/splits.json` (D13). Do not run `make_splits.py` without
`--from-annotations` unless you mean to change it: it rewrites that file.

**Retraining the shipped models.** The committed weights were trained on the pre-extracted
ShuttleSet features published with BST (D29), which need no match videos:

```bash
# 1. Download dataset_npy.rar (440 MB) from the Google Drive link in
#    https://github.com/Va6lue/BST-Badminton-Stroke-type-Transformer and extract it
#    into backend/data/bst_download/extracted/ (7-Zip or WinRAR).
python scripts/import_bst_features.py --src data/bst_download/extracted/dataset_npy
python scripts/train_stroke_classifier.py --algorithm cnn  --seeds 1,2,3
python scripts/train_stroke_classifier.py --algorithm lstm --seeds 1,2,3
python scripts/train_stroke_classifier.py --algorithm rf   --seeds 1,2,3   # needs scikit-learn
python scripts/train_stroke_classifier.py --algorithm cnn  --seeds 1,2,3 --pose-only
python scripts/make_figures.py                        # -> docs/results/strokes.md + figures
python scripts/bench_strokes.py --models cnn,lstm,rf  # -> docs/results/stroke_latency.md
```

All of it runs on a CPU: about 2 minutes for the Random Forest, 10 for the CNN and 50 for the
LSTM with three seeds each. After committing new weights, update their SHA-256 values in
`scripts/download_weights.py`.

Evaluation scripts (each writes a table to `docs/results/`; see each script's docstring for its label format): `benchmark.py` (T2.9), `eval_tracking.py` (T2.10), `eval_hits.py` (T3.7), `eval_rallies.py` (T6.7).

Processed `clips/` and `features/` are shared through the team Google Drive folder so not everyone re-runs extraction. Layout is described in [DATA_FORMAT.md](DATA_FORMAT.md#training-data-layout-stroke-classifier).

**Sample clips** for the demo go in `samples/` (gitignored). Only add clips of people who agreed to be recorded.

## 7. App

```bash
cd app
flutter pub get
flutter analyze && flutter test
```

Run on each target:

**Watch & Analyze:** choose this mode after connecting, upload a clip and optionally
calibrate the court. Playback is silent. By default video plays in real time while
analysis processes the watched frames in the background; if it falls behind, it
continues after playback stops. Choose **Analyze every frame** to make playback wait
for each analyzed frame instead. Browser playback requires a supported
video codec; use a compatible MP4 or the frame-by-frame mode if playback fails.
The saved session ends at the last processed frame. Stop early to save a partial
session. Chrome has the existing 512 MB upload
cap; the backend defaults to 1 GB and 10 minutes. Real analysis needs the model
dependencies and weights in sections 3 and 5; fake mode shows synthetic results.
FFmpeg is recommended for browser-compatible saved video exports.

Background Watch runs player and shuttle models concurrently on CUDA by default; CPU
remains sequential. Set `watch.parallel_perception` in `backend/configs/pipeline.yaml`
to `false` to use sequential inference, or `true` to opt in on another device. Changes
require a backend restart. `backend/scripts/bench_watch_parallel.py` compares the modes
on a video; provide calibrated `--corners` to compare player tracking too.

Frame-by-frame Watch uses the separate `watch.frame_parallel_perception` setting:
`false` selects sequential inference, `auto` selects parallel inference on CUDA, and
`true` forces it. Restart the backend after changing the setting. The client displays
configured detector and pose providers when the server supplies the diagnostics.
To measure the real frame-by-frame WebSocket without opening Flutter, use
`python scripts/bench_watch_complete.py --video PATH --court doubles --corners X1 Y1 X2 Y2 X3 Y3 X4 Y4 --seconds 45 --parallel false`
and repeat with `--parallel true`. It uses temporary storage, real models, and one
request per frame; the in-process client excludes network latency and Flutter display,
so also repeat the 45-second checkpoint in the app. Frames are normalized as in Watch.

For opt-in diagnostic timings, add `--profile` to the benchmark. `--resources` samples
`nvidia-smi` once per second and, if installed with `python -m pip install -r
requirements/profiling.txt`, samples the benchmark process CPU percentage and resident
memory. GPU utilization and used VRAM are device-wide snapshots, including other
processes; the sampled maximum is not an exact peak. Process CPU can exceed 100% because
one fully utilized logical core is 100%. `--warmup-frames 30` first runs and saves a
short session in the same server process; without it each invocation starts a new process,
although the disk cache may already be warm. `--seconds 0` runs the complete normalized
clip. The 45-second checkpoint is the first completed response at or after 45 seconds.

For an isolated prefetch experiment, the benchmark accepts `--prefetch-depth 2` (default
`0`). This is confined to the benchmark process; it does not enable prefetching in the
application. The worker only reads and normalizes frames, with at most two queued or
currently decoding frames; analysis and recording still happen on requests. Use identical
inputs and alternate runs with and without the option. This in-process experiment cannot
establish Flutter, real-network, pause/resume or production throughput behavior.

The corresponding frame-by-frame Watch prototype is separately configured with
`watch.frame_prefetch_depth: 2` in `configs/pipeline.yaml`; its default is `0` (off).
Restart the backend after changing it. It prefetches only normalized frames for
**Analyze every frame**, never runs inference on unrequested frames, and discards queued
frames on stop or disconnect. It is experimental until the fixed-section Flutter and
output-alignment comparisons in the performance roadmap pass; it does not change
background or real-time Watch. A blocked video read can delay producer shutdown.

For the actual Windows app, run `flutter run -d windows --profile
--dart-define=WATCH_PROFILE=true` and select **Analyze every frame**. `WATCH_PROFILE`
lines in the Flutter console correlate client request/receive, response handling and
post-frame callbacks with frame indexes and server timing. A Flutter post-frame callback
indicates a UI frame was scheduled, not that JPEG decoding or pixels were displayed.
The profile build also logs image-ready callbacks, actual image-stream codec timings,
and application build/raster frame timings. Codec time includes asynchronous scheduling
and codec creation after the image buffer is made. Raster timing is not physical screen
presentation. Profiling and per-frame logging can change performance.
The backend reports JSON serialization and send-await time for the preceding frame. With
server and client on the same machine, the optional `--same-host` summarizer flag also
reports serialization-start-to-client-receive wall time, including buffering and scheduling;
do not use it across machines without independently synchronized clocks.
The `WATCH_PROFILE` events exclude video pixels and file paths but contain per-session
performance data. The full Flutter console log can include local URLs or other diagnostic
details; keep it local and review it before sharing. Normal runs do not enable this
instrumentation. Compare instrumented
and normal sessions before relying on timing because profiling and console logging can
change performance. Server per-model values are CPU wall intervals which can overlap and
may include asynchronous GPU waits; they are not CUDA-event or per-kernel timings.
Capture the console in PowerShell with `flutter run -d windows --profile
--dart-define=WATCH_PROFILE=true 2>&1 | Tee-Object -FilePath ../backend/.cache/watch_flutter.log`,
then from `backend/` run `python scripts/summarize_watch_flutter.py .cache/watch_flutter.log`.
The summary separates sessions and reports checkpoint, round trips, response handling,
next-request delay, UI callbacks, and save/clock timings. It requires valid complete log
lines; a stopped/paused session is not a complete-video measurement.

The optional **Faster player analysis (experimental)** switch limits pose candidates near
confirmed players between periodic full-candidate refreshes. It uses normal selection if
the court is uncalibrated, a player is unconfirmed or missing, or a nearby detection is not
available. It can still miss players, change hits and other results, or run slower. It is
off by default and requires labelled-footage validation. The saved job records whether it
was selected and available in `watch_focused_analysis`. A status message confirms when it
is enabled; this is not proof that the shortcut was used on every frame. The server-wide
`watch.candidates_per_player` setting also enables this experimental behavior when greater
than zero; use zero to disable it. Restart the backend after changing configuration.

### Measuring analysis and export performance

For a meaningful comparison, use the same clip, court calibration, playback mode and
hardware. Note cold-start and warm-start runs separately. The backend terminal logs
`Watch analysis` after a background session completes: elapsed time includes time waiting
for playback and saving, while frame processing covers frame reading and processing.
The `Render` log breaks export wall time into overlay drawing, writes to the encoder pipe,
and other work such as frame reading and encoder finalization. Pipe time can include
waiting for encoding; it is not a standalone encoder benchmark. These are wall-clock
measurements, not CPU/GPU utilization, and do not include the full client experience.

The standard upload pipeline writes `timings.json` in its job folder; cached stages can
show zero time. Use fresh jobs when comparing full analyses. For Watch profiling and
accuracy comparisons, use the commands below and check real outputs on representative
footage. Monitor GPU compute, video encoding and memory separately in Windows Task Manager
or NVIDIA tools. Compare total time and quality as well as utilization.

### Optional NVIDIA video encoding

The default remains `libx264`. To install the optional portable FFmpeg in the backend
environment, run `python -m pip install -r requirements/ffmpeg.txt` from `backend/`.
The writer prefers FFmpeg on PATH, then `backend/.bin/ffmpeg.exe`, then the portable
`imageio-ffmpeg` binary. To try GPU video encoding, use a build with `h264_nvenc` support. Set
`stages.render.codec` to `h264_nvenc` in `backend/configs/pipeline.yaml` and restart the
backend. Before each export, ShuttleSense probes whether FFmpeg can actually initialize
NVENC; if that probe fails it uses `libx264`. If FFmpeg is absent, it uses the existing
OpenCV `mp4v` fallback, which may not play in browsers. An error after encoding starts is
reported rather than silently replacing a partially written video. The `crf` setting maps
to NVENC's constant-quality target for that encoder; equal values do not guarantee equal
quality or size across encoders. Compare playback, seeking, file size and visual quality
before choosing a setting. Hardware encoding affects export, not model analysis. A short
265-frame saved-session comparison on the RTX 5070 Ti measured roughly 1.6 seconds for
libx264 and 1.7–1.8 seconds for NVENC, so this does not establish a speedup for NVENC;
longer clips, quality, and file size should be compared before changing the default.

Watch can optionally batch per-frame RTMPose detections by setting
`watch.pose_batch_size` (up to 16). It is currently set to 8; set it to 1 for the original sequential path.
Batching is experimental: GPU numerical differences can move keypoints or change
tracking decisions, so compare it against sequential results on representative footage
before using it for analysis. The benchmark script accepts `--compare-batch 8` to compare
sequential and batched detections. Unsupported ONNX models and batching failures fall back
to sequential inference for that session. Restart the backend after changing the setting.

`watch.candidate_filter` is currently set to experimental `filter`. Set it to `shadow`
to count candidates a conservative
court-aware filter would exclude, while still running pose on everyone. The background
Watch status includes `candidate_diagnostics`, including candidates and any excluded
person later tracked in shadow mode. Use `scripts/bench_watch_parallel.py --compare-filter
--compare-batch 8` with `--video`, `--court`, and calibrated singles-reference `--corners`
to compare the two paths. The experimental `filter` setting actually removes candidates;
it can miss players, especially with bad calibration, occlusion, or motion outside the
court. Use it only after validation; `off` restores the prior behavior. The filter is
bypassed when the court is missing or partly outside the image.

To measure the Watch pipeline on a local video, run from `backend`:
`python scripts/profile_watch_pipeline.py --video PATH --device cuda --court doubles
--corners X1 Y1 X2 Y2 X3 Y3 X4 Y4 --frames 80 --record`. The report includes
JPEG, model, far-player recovery, recording and analysis times. Model times overlap
in parallel mode, so do not add them together. Startup and the chosen footage affect
the result. `scripts/bench_watch_track_batch.py --video PATH --device cuda --batch 4`
is a separate cross-frame shuttle batching experiment; it does not enable batching
in Watch. On the tested RTX 5070 Ti it showed no speedup.

Add `--detector-breakdown --pose-breakdown` to the offline profiler to time detector
preprocessing, inference and postprocessing and pose crop preparation, session calls and
postprocessing. These are instrumented host wall times, not CUDA event measurements;
counts include extra recovery calls and can exceed the number of frames.

The optional `watch.decoded_frames: true` bypasses the background worker's internal
JPEG encode/decode. It is currently disabled; the model sees different pixels when enabled,
so validate player and shuttle accuracy on representative footage.
Restart the backend after changing the setting. Set it back to `false` to restore
the JPEG path. The live camera's JPEG input is unchanged.

For an offline comparison, run `profile_watch_pipeline.py` twice with identical
arguments and add `--decoded-frames` to the candidate run. Use `--record`, court
corners, and enough `--frames` to cover the desired duration (45 seconds at the
normalized 25 fps requires 1125 frames). Alternate baseline and candidate at least
three times. The reported processing wall time and fps are an offline measurement;
they do not include the app, actual playback, polling, or final annotated export.
Measure analysis position after 45 wall-clock seconds separately in the app. The
script reports setup and recording close separately, and overlapping model timings
must not be added. GPU contention, warmup and calibration affect the comparison.

Use `scripts/bench_watch_parallel.py --video PATH --device cuda --court doubles
--corners X1 Y1 X2 Y2 X3 Y3 X4 Y4 --frames 1125 --compare-decoded` to compare
perception and downstream events on the same frames. Differences require review
against labeled footage; equal events are not proof of accuracy. This comparison
times perception only, excluding JPEG conversion, so use the profiler for speed.
For a CUDA timeline, NVIDIA Nsight Systems can trace the profiler process; compare
unprofiled runs for timing. Use Flutter profile mode to investigate playback jank,
and measure final video export separately from analysis catch-up.

`scripts/probe_tensorrt_rtx.py` is a standalone provider experiment requiring a
separate compatible ONNX Runtime / TensorRT RTX environment and saved model inputs.
It does not change the application's inference provider. Engine startup, dynamic
batch sizes and end-to-end player tracking still need validation before deployment.

The Watch-only TensorRT RTX experiment uses the same YOLOX and RTMPose models and
keeps their original CUDA sessions for fallback. Install the standalone plugin in a
compatible CUDA 13 environment with `pip install --no-deps
onnxruntime-ep-nv-tensorrt-rtx-cu13==0.5.0`. This is optional; verify ONNX Runtime,
driver and CUDA compatibility for the machine first. In `watch.player_provider`,
`pose` is currently enabled for testing; `detector`, `pose` and `both` request TensorRT RTX
for the indicated models, and `cuda` restores the baseline. Restart the backend after
changing it. The background Watch
status exposes `provider_diagnostics`, including graph assignments and fallback errors.
TensorRT numerical differences require representative tracking validation. On the
tested model and plugin, YOLOX engine creation failed because its TopK exceeds the
provider's limit, so the detector fell back to CUDA; RTMPose ran on TensorRT RTX.
The runtime cache is stored in `backend/.cache/tensorrt_rtx` and is rebuilt if needed.

Compare outputs with `bench_watch_parallel.py --video PATH --device cuda --court doubles
--corners X1 Y1 X2 Y2 X3 Y3 X4 Y4 --frames 120 --compare-provider pose` (or `detector`
or `both`). Check provider diagnostics before interpreting speed or output comparisons;
the script processes JPEG input on both paths. For a recording-enabled 45-second offline
throughput sample, use `profile_watch_pipeline.py --video PATH --device cuda --court
doubles --corners X1 Y1 X2 Y2 X3 Y3 X4 Y4 --frames 1125 --wall-seconds 45 --record`
and repeat with `--player-provider pose`. Setup is timed separately; this does not
reproduce app playback or the full 45-second user experience. Alternate trials, test
cold and warm caches, and validate outputs before enabling the provider in Watch.

The optional `watch.candidate_shadow_margin_m` records an additional tighter court-margin
proposal without changing candidate selection. For example, set it to `1.0` to compare
against the current 2.0 m margin. The status field `candidate_diagnostics.proposal`
counts additional exclusions and tracked exclusions relative to the existing filter;
it does not assess players already excluded by that filter. Set the existing filter to
`shadow` to include those candidates in a separate reference test. This audit does not
replace labeled footage, and no tighter filtering is enabled by the setting. The profiler
also accepts `--shadow-margin 1.0` for the same experiment.
`watch.candidate_shadow_footpoint: true` instead evaluates a proposal based on the
bottom center of each detection box; it does not exclude any candidates. The profiler
accepts `--shadow-footpoint`. Jumping, occlusion, and inaccurate boxes can put a real
player's footpoint outside the court, so shadow counters and labeled footage must be
reviewed before considering any active use.

For an isolated TensorRT detector split experiment install `onnx` separately and run
`python scripts/probe_watch_detector_split.py --video PATH --frames 40`. It splits the
balanced YOLOX model at fixed internal tensor names, runs the network in TensorRT RTX,
and retains CUDA postprocessing. It reports matched box differences and timings; it
does not change Watch. The 40-frame trial showed different boxes and a small isolated
gain, so this detector path is not enabled. The script is specific to the current
balanced YOLOX graph and should not be assumed to support another model version.

To compare TensorRT pose batch sizes, use `--pose-batch-size 8` or `16` with
`profile_watch_pipeline.py`, and `--compare-pose-batch 16` with
`bench_watch_parallel.py`. Engine compilation for previously unseen batch shapes can
make the first run slower; compare cold and warm runs and validate tracking outputs.
`bench_watch_parallel.py --compare-postprocess` tests a vectorized RTMPose decoder
against the current per-person decoder. It is not enabled in Watch: the short test had
identical outputs but did not demonstrate an end-to-end speedup.
`--pose-opt-batch` tests TensorRT's preferred optimization shape separately from the
actual batch size; the configured value remains 4 because a short test with 8 did not
improve throughput. A new shape can incur first-run compilation overhead.

`scripts/probe_watch_tracknet_rtx.py --video PATH --frames 200` exports the current
TrackNet to an experimental ONNX model in `.cache`, then compares the existing CUDA
autocast path against TensorRT RTX on Watch-style inputs and reports latest-heatmap
and detection differences. It requires the optional `onnx` package and does not change
Watch. Treat its inference-only timing as a screening result, not a full pipeline result.
In one 200-frame prototype, the exported TensorRT path was slower and visibility differed
on 101 frames, so it is not enabled and needs further debugging before use.

For an Nsight Systems trace, install NVIDIA Nsight Systems and launch the profiler with
`nsys profile --trace=cuda,nvtx -o watch-trace python scripts/profile_watch_pipeline.py`
followed by the same video, court and frame options and `--nvtx`. Compare timing with
unprofiled runs; tracing can perturb performance. The trace and its CUDA/CPU timeline
must be inspected on the machine where the workload runs.

| Target | Command |
| --- | --- |
| Chrome (web) | `flutter run -d chrome` |
| Windows | `flutter run -d windows` |
| Android phone/tablet (USB or wireless debugging) | `flutter devices` then `flutter run -d <id>` |
| Android emulator | `flutter emulators --launch <name>` then `flutter run` |
| iPhone / iPad (Mac only) | `cd ios && pod install && cd ..` then `flutter run -d <id>` |

Pre-fill the server URL in a build (optional):

```bash
flutter run -d chrome --dart-define=API_BASE_URL=http://192.168.1.20:8000
```

Release builds (Phase 7):

```bash
flutter build apk --release                 # build/app/outputs/flutter-apk/app-release.apk
flutter build windows --release             # build/windows/x64/runner/Release/
flutter build web --release                 # build/web/
flutter build ipa                           # Mac only
```

To test layouts, resize the Windows/Chrome window or use Chrome DevTools device mode: under 600 px wide is the phone layout, 600–1023 px the tablet layout, 1024 px and up the laptop layout.

## 8. Connecting a phone or tablet to the laptop

1. Put the laptop and the phone/tablet on the **same Wi-Fi** (campus networks often isolate clients; a phone hotspot works).
2. Find the laptop's IP: `ipconfig` (Windows, "IPv4 Address") or `ip addr` (Linux/macOS).
3. Allow port 8000 through the Windows firewall once (PowerShell as Administrator):

   ```powershell
   New-NetFirewallRule -DisplayName "ShuttleSense API" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Private
   ```

4. Start the backend with `--host 0.0.0.0`.
5. In the app's connect screen enter `http://<laptop-ip>:8000` and tap **Connect**.

## 9. Troubleshooting

| Symptom | Fix |
| --- | --- |
| App says "Cannot reach server" from a phone but `localhost:8000/docs` works on the laptop | Firewall rule (step 8.3), wrong IP, different Wi-Fi, or client isolation; try a hotspot |
| Web build cannot call the backend | Check `SHUTTLESENSE_CORS_ORIGINS`; an `https://` page cannot call an `http://` server, so use the tunnel URL or serve the web build over `http://` |
| `torch.cuda.is_available()` is `False` | Install the CUDA wheel from the PyTorch index (section 3), update the NVIDIA driver |
| Annotated video does not play in the app | Make sure ffmpeg is installed so the export is H.264 (`ffmpeg -version`) |
| `flutter build windows` fails | Install Visual Studio 2022 "Desktop development with C++"; run `flutter doctor` |
| Colab URL stopped working | The Colab session ended; re-run the notebook and enter the new URL |


## Courtside depth
Use a 1.6 backend and updated app for persistent goals, decision history and interval
controls. Older backends keep their existing controls. Pin a cue or set a personal goal
in Coach; switch to Referee for the timer and decision log. Stop and reopen History to
review goals and moments. No new dependencies or API key are needed. The camera,
perception-weight and physical-device acceptance checks still apply.
