# Live latency (T8.12)

## Paced courtside benchmark, November 10

- Command from `backend/` with the project venv active

  ```powershell
  python scripts/bench_live.py --fake --frames 420 --realtime --out (Join-Path $env:TEMP 'shuttlesense-nov10-live-latency.md')
  ```

- Commit `96e211c`, Windows 11, Python 3.13.3. The in-process server used 420 synthetic 1280 by 720 frames paced at 30 fps with fake perception.

| Measure | p50 | p95 | Observations |
| --- | --- | --- | --- |
| Frame sent to frame event | 12.9 ms | 26.2 ms | 420 frames |
| Server arrival to frame event | 9.3 ms | 22.9 ms | 420 frames |
| Hit contact to hit event | 670.4 ms | 736.4 ms | 10 hits |
| Landing to line-call event | 1704.6 ms | 1733.1 ms | 3 calls |
| Rally end to rally event | 1704.8 ms | 1733.5 ms | 3 rally ends |

The line-call lag includes the look-ahead and settling time. Model-backed latency and
accuracy on labelled landings remain open.

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
