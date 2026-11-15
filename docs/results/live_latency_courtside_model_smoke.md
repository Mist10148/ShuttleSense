# Live latency (T8.12)

- Run: 2026-11-15 00:57 UTC, commit `2314f09`
- Command: `python scripts/bench_live.py --url <live-url> --frames 120 --video <input-video> --corners 106,325,534,325,440,105,200,105 --realtime --require-models --out <report-path>`
- Mode: remote server (address omitted); frames: 120; source: video file (path omitted)
- Machine: Windows-11-10.0.26300-SP0, Python 3.13.3, GPU: NVIDIA GeForce RTX 4050 Laptop GPU
- Models on the server: {"tracking": true, "pose": true}

| Measure | p50 | p95 | p99 |
| --- | --- | --- | --- |
| Frame sent -> frame event back (ms) | 109.8 | 201.4 | 249.7 |
| Server: arrival -> event (ms) | 107.8 | 199.7 | 236.3 |

Throughput (frames processed one at a time): 7.6 fps. Budget: p95 <= 300 ms.
