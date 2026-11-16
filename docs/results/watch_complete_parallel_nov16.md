# Frame-by-frame Watch concurrency comparison

On November 16, 2026, three 45-second sequential and three concurrent runs used the
same original 50 fps broadcast upload, doubles calibration, RTX 5070 Ti laptop GPU,
CUDA detector and TensorRT RTX pose provider. The video is normalized to 25 fps and
720p. Each run used the actual `/watch` WebSocket through FastAPI TestClient, including
model setup and frame request/response, with temporary storage and recording enabled.
The benchmark excludes Flutter display, actual network latency and upload time. The
first sequential run predates the optional timing fields; those fields do not change
the analyzed frames. Runs were cold process starts with a warm on-disk model cache;
other desktop processes were active. No GPU utilization or peak VRAM was recorded.

| Mode | Video processed at about 45 seconds | Frames | Setup | Export after save |
| --- | ---: | ---: | ---: | ---: |
| Sequential | 11.24 s | 281 | 3.84 s | 2.02 s |
| Sequential | 11.04 s | 276 | 4.36 s | 2.49 s |
| Sequential | 11.64 s | 291 | 4.17 s | 2.36 s |
| Concurrent | 13.92 s | 348 | 4.35 s | 3.15 s |
| Concurrent | 14.84 s | 371 | 4.30 s | 2.47 s |
| Concurrent | 14.72 s | 368 | 4.39 s | 2.44 s |

Median video progress increased from 11.24 s to 14.72 s, approximately 31% for these
tests. The 14.84 s concurrent run had median 98.12 ms round trip, including 86.53 ms
processing, 5.85 ms frame reading and 2.79 ms JPEG preparation. These independently
calculated medians should not be added to estimate a frame. The app's actual 45-second
checkpoint may differ, and a faster path is not guaranteed on other hardware.

A separate real-model 120-frame comparison using identical JPEG input, player filtering,
batch size and providers produced identical player and shuttle outputs on every frame;
hits, rallies, line calls and score also matched. This was repeated with the singles
and doubles court configuration using the same doubles footage; it is not a test on
actual singles footage, labeled data, or a full match. Camera changes and occlusions
require further representative testing. Concurrency is enabled with `auto` for CUDA;
set `watch.frame_parallel_perception` to `false` to use the sequential path.

For a longer 525-frame saved recording with the same overlays, two libx264 exports
took 3.35 s and 3.29 s (about 4.38 MB each); two NVENC exports took 3.10 s each
(about 8.40 MB). Each reported 525 output frames. The configured quality values are
not visually equivalent by definition, and the difference is small in absolute time;
libx264 remains the default. No full Flutter playback or visual-quality comparison
was performed in this benchmark.
