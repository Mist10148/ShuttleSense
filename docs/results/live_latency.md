# Live latency (T8.12)

## Courtside recovery verification, November 6

- Command from `backend/`: `python scripts/bench_live.py --fake --frames 420 --realtime --out <temp>/shuttlesense-nov6-live-latency.md`
- Backend commit `2b0a5d2`, Windows 11, Python 3.13.3. The run used 420 synthetic 1280×720 frames paced at 30 fps, with other local verification running concurrently.
- Frame round trip was 34.7 ms at p95. Server arrival to frame event was 30.2 ms at p95.
- Measured p95 event lag was 1.61 s for hits (10 events), 1.65 s for line calls (3 events), and 1.65 s for rally closure (3 events). These are wall-clock measurements from the paced run.
- This run used fake perception. Model-backed latency and line-call accuracy on labelled landings remain open.

## Previous synthetic run

- Run: 2026-11-05 15:41 UTC, commit `09b458a`
- Command: `python scripts/bench_live.py --fake --frames 600`
- Mode: fake perception (in-process); frames: 600; source: synthetic 1280x720 frames
- Machine: Windows-11-10.0.26300-SP0, Python 3.13.3, GPU: NVIDIA GeForce RTX 4050 Laptop GPU
- Models on the server: {"tracking": false, "pose": false, "synthetic": true}

| Measure | p50 | p95 | p99 |
| --- | --- | --- | --- |
| Frame sent -> frame event back (ms) | 13.0 | 29.6 | 35.7 |
| Server: arrival -> event (ms) | 9.4 | 25.9 | 31.8 |

Throughput (frames processed one at a time): 61.6 fps. Budget: p95 <= 300 ms.

Event lag: how many frames after the frame it is about each decision arrives (at 30 fps), and the time since that frame was sent (frames sent back to back, so the ms column is not camera time).

| Event | Count | p50 frames | p95 frames | p95 s at camera rate | p50 ms | p95 ms |
| --- | --- | --- | --- | --- | --- | --- |
| hit | 16 | 19.0 | 21.0 | 0.7 | 324.9 | 371.7 |
| line_call | 4 | 49.0 | 50.9 | 1.7 | 888.1 | 919.2 |
| rally | 4 | 49.0 | 50.9 | 1.7 | 888.4 | 919.6 |

Fake perception replays synthetic rallies instead of running TrackNetV3 and pose, so these numbers are the overhead of everything around the models. They are not the GPU latency.
