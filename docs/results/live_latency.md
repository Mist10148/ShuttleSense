# Live latency (T8.12)

- Run: 2026-10-30 17:25 UTC, commit `420d9d8`
- Command: `python scripts/bench_live.py --fake --frames 600`
- Mode: fake perception (in-process); frames: 600; source: synthetic 1280x720 frames
- Machine: Windows-11-10.0.26300-SP0, Python 3.13.3, GPU: NVIDIA GeForce RTX 4050 Laptop GPU
- Models on the server: {"tracking": false, "pose": false, "synthetic": true}

| Measure | p50 | p95 | p99 |
| --- | --- | --- | --- |
| Frame sent -> frame event back (ms) | 10.1 | 20.7 | 23.3 |
| Server: arrival -> event (ms) | 7.0 | 17.5 | 20.1 |

Throughput (frames processed one at a time): 82.2 fps. Budget: p95 <= 300 ms.

Fake perception replays synthetic rallies instead of running TrackNetV3 and pose, so these numbers are the overhead of everything around the models. They are not the GPU latency.
