# Phase 6 annotated export benchmark

## Decision and scope

Keep `libx264` as the default and `h264_nvenc` optional. This limited experiment
did not show a repeatable 5% export improvement at established comparable visual
quality. It tested libx264 CRF 23 and NVENC CQ 28; those numbers use different
encoder controls and must not be treated as equivalent by definition. Neither
setting was changed in production.

On November 20, 2026, the benchmark used one saved doubles Watch record
(`phase2_current_config_storage/jobs/02e44853f6f7/record.json`, SHA-256
`798ae41400bf2f16f6e84f8dd8043bc1b1e8c3dd7643bfbbba0ff00d0278d59f`) and its
saved 1280 x 720, 25 fps source recording (SHA-256
`efdf99bb2d3c09e94f1f92d439097f07e0de5450c371f7954ccebd50f7521dd6`). The same
record, source frames, overlay order and renderer were used for every export. The
short section is the first 120 frames and the longer section is all 525; they are
overlapping sections of one recording, not independent footage. The 525-frame x264
output's SHA-256 matched the pre-existing saved annotated MP4 exactly.

The machine used FFmpeg 9.0.2, an RTX 5070 Ti Laptop GPU, driver 616.87, and
other desktop processes were active. Each codec/length was run twice; codec runs
were grouped rather than counterbalanced. A dedicated script uses the production
`VideoWriter` and `draw_frame`, with default render configuration. CPU and GPU
sampling is sparse and perturbs short runs. The timing is export-only: validation,
quality decoding, upload and Flutter playback are excluded.

## Timings and quality

| Frames | Codec / setting | Total export runs (s) | Output bytes | PSNR versus drawn reference (dB) |
| ---: | --- | --- | ---: | ---: |
| 120 | libx264 / CRF 23 | 0.774, 0.754 | 868,391 | 34.622 |
| 120 | NVENC / CQ 28 | 1.005, 1.019 | 775,517 | 34.306 |
| 525 | libx264 / CRF 23 | 2.814, 2.818 | 4,428,792 | 34.214 |
| 525 | NVENC / CQ 28 | 2.799, 2.839 | 4,540,936 | 34.025 |

PSNR is computed over all decoded BGR samples against freshly drawn, uncompressed
reference frames, using aggregate squared error; conversion to yuv420p is included
in that error. The two long outputs differ by 0.189 dB on this metric, but PSNR
alone does not establish equivalent perceived quality or preservation of small
overlays. No blind visual quality review or representative-clip study was done.
The longer-run medians are approximately 2.816 s and 2.819 s, effectively tied in
this small and non-counterbalanced sample. The short NVENC runs were slower.

| 525-frame stage, mean of two runs | libx264 (s) | NVENC (s) |
| --- | ---: | ---: |
| Writer context entry | 0.007 | 0.220 |
| Source iterator `next` | 1.065 | 1.020 |
| Overlay drawing | 0.856 | 0.682 |
| Writer calls | 0.749 | 0.821 |
| Writer exit | 0.130 | 0.068 |

Entry includes process launch and, for NVENC, the existing one-frame availability
probe; FFmpeg initializes asynchronously, so this is **not** a complete encoder
initialization measurement. Writer calls include conversion to contiguous bytes,
pipe submission, and any blocking; they do **not** isolate pipe backpressure. Exit
includes input close, encoder flush/reap and atomic replacement. Iterator timing
includes source reading and normalization. The stage timings are host wall intervals,
affected by scheduling and overlapped encoder work; do not interpret the drawing
difference as a codec effect. Total also includes loop and sampler overhead.

For 525 frames, sampled parent RSS maxima were about 158–159 MiB; sampled child
maxima were approximately 403 MiB for x264 and 235 MiB for NVENC. The child group
also includes helper processes, and a 0.2-second poll can miss peaks. Sampled child
CPU maxima were roughly 511–523% and 194–199%, respectively, where 100% is one
logical CPU. Sampled device-wide VRAM maxima were 4,441–4,445 MiB and 4,635–4,640
MiB, respectively; they include unrelated processes and are not process VRAM or
proof of the encoder's allocation. These measurements do not establish peak memory
or GPU efficiency.

## Frame, playback and fallback checks

`ffprobe` reported H.264/yuv420p at 25 fps and exactly 120 or 525 frames, with
strictly increasing timestamps at the expected 40 ms cadence for every output.
OpenCV decoded the expected number with no extra frame; every decoded frame was
compared to its corresponding freshly drawn reference for the PSNR computation.
This does not prove semantic annotation alignment or rule out visually missing
overlays. The existing saved x264 export matching the reproduced hash confirms
reproduction of that export, not independent annotation correctness.

A Flutter Windows profile integration test attached the same `media_kit` video
controller used by Results. It opened each 525-frame local file, created a video
texture and observed playback position after seeks to 10 and 19 seconds. The driver
printed both success markers and `All tests passed`, but also warned that the
integration-test plugin was not detected and returned exit code 1. This tests a
local player path, not the app's streamed Results workflow or visual appearance.
Headless FFplay also returned exit code 0 for a one-second segment after a 10-second
seek in both files, but emitted `co located POCs unavailable` warnings; no visible
common-player playback inspection was performed.

The full render suite passed 25 tests, including real x264 and NVENC output when
available, OpenCV fallback, NVENC-to-x264 fallback before encoding, and a new test
that an FFmpeg failure after accepting one frame is reported and does not publish
the output. These tests do not prove compatibility on every device or driver.

## Reproduce and remaining work

From `backend/`, run the script once per codec and length, substituting the saved
record and source paths if needed:

```powershell
$record = '.cache/phase2_current_config_storage/jobs/02e44853f6f7/record.json'
$video = '.cache/phase2_current_config_storage/videos/b1e6c53e644d/source.mp4'
.\.venv\Scripts\python.exe scripts/bench_render_export.py --record $record --video $video --out-dir .cache/phase6_exports --frames 525 --codec libx264 --quality 23 --repeats 2
.\.venv\Scripts\python.exe scripts/bench_render_export.py --record $record --video $video --out-dir .cache/phase6_exports --frames 525 --codec h264_nvenc --quality 28 --repeats 2
.\.venv\Scripts\python.exe -m pytest tests/test_render.py -q -p no:cacheprovider
```

Raw logs and outputs remain under `.cache/phase6_*`; inspect before sharing. The
Flutter probe is `app/integration_test/export_playback_test.dart`. Remaining work:
separately attribute encoder readiness and pipe blocking, repeat in counterbalanced
order on independent short and longer recordings, evaluate perceptual quality and
small overlays, validate per-frame semantic alignment, and visually inspect playback
and seeking in the streamed Flutter Results screen and a common player. Do not
mark those validation tasks complete from this initial sample.
