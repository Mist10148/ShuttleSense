# Live latency (T8.12)

- Run: 2026-11-15 00:43 UTC, commit `d79066f`
- Command: `python scripts/bench_live.py --fake --frames 300 --realtime --out <report-path>`
- Mode: fake perception (in-process); frames: 300; source: synthetic 1280x720 frames
- Machine: Windows-11-10.0.26300-SP0, Python 3.13.3, GPU: NVIDIA GeForce RTX 4050 Laptop GPU
- Models on the server: {"tracking": false, "pose": false, "synthetic": true}

| Measure | p50 | p95 | p99 |
| --- | --- | --- | --- |
| Frame sent -> frame event back (ms) | 11.7 | 23.0 | 30.3 |
| Server: arrival -> event (ms) | 8.6 | 20.1 | 27.3 |

Throughput (frames processed one at a time): 30.0 fps. Budget: p95 <= 300 ms.

Event lag: how many frames after the frame it is about each decision arrives (at 30 fps), and the time since that frame was sent (frames paced at camera rate).

| Event | Count | p50 frames | p95 frames | p95 s at camera rate | p50 ms | p95 ms |
| --- | --- | --- | --- | --- | --- | --- |
| hit | 8 | 19.0 | 21.0 | 0.7 | 669.7 | 735.9 |
| line_call | 2 | 50.5 | 51.0 | 1.7 | 1719.7 | 1734.4 |
| rally | 2 | 50.5 | 51.0 | 1.7 | 1720.0 | 1734.7 |

Fake perception replays synthetic rallies instead of running TrackNetV3 and pose, so these numbers are the overhead of everything around the models. They are not the GPU latency.
