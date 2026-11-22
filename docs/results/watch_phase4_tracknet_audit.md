# Phase 4 TrackNetV3 path audit

## Scope and evidence

This is a code audit of the existing Watch PyTorch path, with notes on offline and
experimental paths. It does not change model behavior or establish a performance
improvement. The locally installed checkpoint reports `seq_len=8` and
`bg_mode=concat`; other checkpoints may differ. Phone footage profiling was deferred
by the owner. Existing broadcast measurements are short and not evidence of performance
or accuracy across intended footage.

The prior Phase 1 diagnostic measured median inclusive shuttle and player wall times
of 39.11 and 67.38 ms over 102 normalized frames, with concurrent model work and
warm-up ([baseline](watch_phase1_baseline.md)). A separate intrusive 35-frame CUDA
trace associated 48.65 ms of summed pageable host-to-device copy activity and 0.97 ms
device-to-pageable-host activity with the shuttle path, including warm-up; attribution
is approximate ([trace](watch_phase3_pose_profile.md)). The wall intervals overlap,
and activity sums can overlap and are not end-to-end latency. These measurements show
substantial shuttle work but do not establish the speedup achievable in Flutter or
whether it is the limiting path. The controlled end-to-end baseline remains open.

## Current path

| Area | Audit finding | Consequence or measurement gap |
| --- | --- | --- |
| Initialization | `ModelPerception._init_tracking` loads checkpoint parameters and weights, sets the model to evaluation mode and creates a per-session deque and background sample list. `_load_model` caches the model process-wide by resolved weight path, device and weight modification time. | Cold load and cache hits differ. Sessions have separate frame and median state but can share a model object. The cache key does not include model kind; normal TrackNet and InpaintNet paths use separate weights. Startup cost is not isolated by the cited frame timings. |
| Window and startup | Each frame appends to a deque of at most eight frames, oldest first. Until full, the oldest frame is repeated on the left; one prediction is returned for the newest frame. | Preserve ordering, first-frame padding and session boundaries in any replacement. Offline non-overlapping inference instead pads the final window on the right; optional overlapping offline inference averages heatmaps. |
| Resized cache | Watch enables `watch_preprocess_cache`: every BGR frame is converted to RGB and resized once to 512 x 288 before entering the deque. Ordinary live mode keeps original frames and resizes each window occurrence. | Cached and uncached preparation are covered by exact-input tests; they must retain equivalent resizing, channel order and background behavior. |
| Background | For a checkpoint with a background mode, the first 30 resized frames by default are retained; the median is recomputed after every new sample and then remains fixed. Input preparation resizes the median again, even when already at model dimensions. Offline estimates a median from up to 100 evenly sampled frames instead. | Early-frame startup work and allocations differ from steady state. Changing the median schedule changes model inputs. |
| Host input allocation | `_track_input_rgb` transposes RGB arrays, concatenates background and frames, casts to float32 and divides by 255; `track_windows` stacks windows and wraps the resulting NumPy batch with `torch.from_numpy`. For the installed checkpoint, one `(1, 27, 288, 512)` float32 input is 15.19 MiB. | Concatenation, casting, normalization and stacking can allocate or copy. The tensor wrapper shares the stacked NumPy storage; the subsequent device transfer is separate. Exact allocation counts and their individual costs have not been measured. |
| Inference and transfers | The caller uses `torch.inference_mode`; CUDA uses autocast. The batch is sent to the chosen device, the model runs, and Watch selects the last heatmap before converting to float32 and copying to CPU/NumPy. | CPU download and consumption can synchronize GPU work; measured wall time may include work from concurrent paths. The latest 512 x 288 float32 heatmap is 0.56 MiB. No assumption about exclusive transfer or model time follows from its size. |
| Decode and coordinates | `heatmap_to_xy` thresholds at 0.5, finds 8-connected components, chooses the largest by area and returns its centroid; no component means invisible. `scale_to_video` independently scales x and y from 512 x 288 into the session's full normalized-video size. Watch rounds visible coordinates to one decimal; invisible output is an empty `Shuttle`. | Preserve threshold, component selection, ties, visibility, scaling and rounding. These are normalized-video pixels, not necessarily original source pixels. Decode and coordinate-conversion costs are not separately measured in the cited Watch trace. |
| Experimental alternatives | The opt-in CUDA rolling window stores normalized frames in two device buffers, updates the background when its object changes, and preserves left padding. The optional RTX runner exports a fixed-shape latest-heatmap ONNX model and binds device inputs; errors fall back to PyTorch. Both are disabled by default. | Device normalization, copies, synchronization, engine initialization and fallback need end-to-end and accuracy evaluation; parity of an input buffer alone is insufficient to promote either path. |

## Verification and next steps

The targeted existing tests cover all four background input modes, cached versus
uncached sliding inputs, latest-only decoding, and rolling-buffer input parity on CPU
and available CUDA. They do not establish labeled shuttle recall or real-footage
end-to-end gains. Run from `backend/`:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/test_tracking.py tests/test_stream.py tests/test_watch_gpu_window.py -q -p no:cacheprovider -k "tracknet_input_channels or latest_only_decodes or cached_tracknet_inputs_are_exact or watch_cache_preserves_model_inputs or watch_enables_cache or rolling_window_matches_original_input"
```

Next, measure preparation, upload, inference, download, decode and background startup
separately with clearly stated synchronization and repeat an uninstrumented concurrent
end-to-end baseline. Test a low-risk candidate only against the same input and output
semantics. Keep the experimental paths disabled until repeated end-to-end and held-out
accuracy gates in the roadmap are met. Nothing in this audit justifies promoting a
replacement or declaring TrackNet immaterial.
