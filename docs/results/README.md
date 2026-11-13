# Results

Every number in the README's Evaluation section comes from one of these reports. Each is written by a script, as Markdown plus a `.json` with the raw numbers. Re-run the script rather than editing a report by hand, and note the commit it was measured on.

| Report | Script | Task | Status |
| --- | --- | --- | --- |
| [dataset.md](dataset.md) | `scripts/dataset_stats.py` (clips); annotation counts below | T3.13 | Annotation counts in; clip counts after extraction |
| `strokes.md` + figures | `scripts/train_stroke_classifier.py --seeds 1,2,3` (and `--pose-only`), then `scripts/make_figures.py` | T3.9, T3.12 | After training |
| `hits.md`, `hits_tuning.csv` | `scripts/eval_hits.py` (`--grid` on val matches) | T3.7 | After feature extraction |
| `tracking.md` | `scripts/label_shuttle.py`, then `scripts/eval_tracking.py` | T2.10 | Needs TrackNetV3 (T2.2) and labelled frames |
| `benchmark.md` | `scripts/benchmark.py --video ... --corners ... --referee` | T2.9 | Needs a team clip and the GPU |
| [stroke_latency.md](stroke_latency.md) | `scripts/bench_strokes.py` | T3.14 | CPU measured with an untrained model; GPU and trained weights to add |
| `rallies.md` | `scripts/label_clip.py`, then `scripts/eval_rallies.py` | T6.7 | Needs labelled team clips |
| `phone.md` | `scripts/label_clip.py`, then `scripts/eval_phone.py` | T7.2 | Needs labelled team clips |
| `speed.md` (+ `speed.png`) | `scripts/speed_report.py RECORD.json ... --plot speed.png` (T10.5) | T5.13 | Script ready; needs calibrated team clips |
| [live_latency.md](live_latency.md) | `scripts/bench_live.py` (`--fake`, or `--url` against a server with weights) | T8.12 | Fake-perception overhead measured; use `--require-models` for the GPU run. Default outputs separate fake, model-backed, and unverified runs. |
| [live_latency_fake.md](live_latency_fake.md) | `scripts/bench_live.py --fake --frames 300 --realtime` | T8.12 | Paced synthetic smoke run on Nov 12; no models or camera |
| `line_calls.md` | `scripts/eval_line_calls.py` (T7.1 labels with `in_out`, or `--gt-format shuttleset`) | T8.12 | Needs labelled landings |

Keep PNGs small (< 300 KB each); no video frames of people who did not consent.
