# Live latency (T8.12)

- Run: 2026-11-03 00:01 UTC, commit `f0c16e6`
- Command: `python scripts/bench_live.py --fake --frames 600`
- Mode: fake perception (in-process); frames: 600; source: synthetic 1280x720 frames
- Machine: Windows-11-10.0.26300-SP0, Python 3.13.3, GPU: NVIDIA GeForce RTX 4050 Laptop GPU
- Models on the server: {"tracking": false, "pose": false, "synthetic": true}

| Measure | p50 | p95 | p99 |
| --- | --- | --- | --- |
| Frame sent -> frame event back (ms) | 10.9 | 23.8 | 28.2 |
| Server: arrival -> event (ms) | 7.5 | 20.0 | 24.5 |

Throughput (frames processed one at a time): 73.0 fps. Budget: p95 <= 300 ms.

Event lag: how many frames after the frame it is about each decision arrives (at 30 fps), and the time since that frame was sent (frames sent back to back, so the ms column is not camera time).

| Event | Count | p50 frames | p95 frames | p95 s at camera rate | p50 ms | p95 ms |
| --- | --- | --- | --- | --- | --- | --- |
| hit | 16 | 19.0 | 21.0 | 0.7 | 277.3 | 325.7 |
| line_call | 4 | 49.0 | 50.9 | 1.7 | 718.3 | 733.2 |
| rally | 4 | 49.0 | 50.9 | 1.7 | 718.6 | 733.5 |

Fake perception replays synthetic rallies instead of running TrackNetV3 and pose, so these numbers are the overhead of everything around the models. They are not the GPU latency.
