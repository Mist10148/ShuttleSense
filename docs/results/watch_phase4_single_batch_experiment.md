# Phase 4: single-window batch copy experiment

## Result

The tested candidate removes the one-window `np.stack` copy by using a NumPy
batch-dimension view. It stays **experimental**: the inputs and decoded points agreed
in this sample, but raw model heatmaps differed. No production inference code or
configuration was changed. The result does not establish an end-to-end improvement.

## Method

On November 20, 2026, the experiment ran on the RTX 5070 Ti Laptop GPU using the
installed TrackNet PyTorch checkpoint (`seq_len=8`, `bg_mode=concat`) and CUDA autocast.
It read the first 48 normalized frames of the local re-encoded 21-second broadcast
section `.cache/phase2_fixed_source.mp4` (1920 x 1080, 50 fps, normalized to
1280 x 720 and 25 fps; SHA-256
`4b96538f112e3d99543ac368437a8592dd60dc1973f7e7d6e6f6de228ba9c132`). Each frame
was JPEG encoded and decoded before preparation. The test builds the same rolling
window, left padding, and changing first-30-frame background median as Watch, and
compares `np.stack([prepared])` with `prepared[None, ...]`. The 48 windows were
prebuilt and reused for three measured repetitions, after eight warm-up pairs; they
are not 144 independent footage samples. Execution order alternated. Model input
arrays, raw latest heatmaps, and thresholded, scaled, rounded Watch coordinates and
visibility were compared for each pair.

Preparation timing includes `_track_input_rgb` and batch construction. The second
timer includes tensor wrapping, upload, model inference, latest-heatmap conversion
and CPU download, with CUDA synchronization. Total is their combined timed interval.
Reading, JPEG, background-median construction, player processing, decoded point
comparison, Flutter, and network are excluded. Synchronization and running both
variants serially change the workload; other desktop processes were active. This is
not an end-to-end Watch benchmark.

## Measurements

| Metric | Stack baseline | Batch view |
| --- | ---: | ---: |
| Preparation median / p95 | 18.816 / 20.865 ms | 14.267 / 15.567 ms |
| Upload, inference and download median / p95 | 11.414 / 12.402 ms | 11.969 / 13.140 ms |
| Combined median / p95 | 29.983 / 32.397 ms | 26.262 / 28.325 ms |

All 144 input pairs were exactly equal, and all 144 decoded coordinate/visibility
results matched. All 144 raw heatmap pairs differed, with maximum absolute difference
0.0003662109375. As a limited repeatability control, 12 additional pairs of baseline
inferences on identical inputs had zero heatmap differences. This does not establish
the reason for the candidate's numerical differences, nor prove equality for footage
where heatmap values are close to the threshold. The two batch arrays can have
different strides or storage alignment even when their values match.

The observed combined median difference in this isolated run is about 12.4%; it must
not be interpreted as a Flutter or concurrent pipeline gain. Measurements are from a
single short, unlabeled section; they do not establish recall, trajectory or hit
parity. Investigate the numerical difference and repeat on broader data before
considering promotion, then apply the roadmap's end-to-end and labeled accuracy gates.

Reproduce from `backend/` with a locally available video:

```powershell
.\.venv\Scripts\python.exe scripts/bench_tracknet_single_batch.py --video .cache/phase2_fixed_source.mp4 --frames 48 --repeats 3 --warmup 8
```
