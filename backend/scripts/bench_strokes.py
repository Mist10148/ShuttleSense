"""Stroke classifier latency on CPU and GPU (T3.14).

Usage: python scripts/bench_strokes.py [--models cnn,lstm,rf | --weights FILE]
                [--record out/record.json] [--duration-s 60] [--hits-per-min 40]
                [--runs 5] [--devices cpu,cuda] [--out ../docs/results/stroke_latency.md]

--models times each installed stroke model (D28) from its default weights file and writes one
row per model and device; the Random Forest runs on the CPU only.

Times the strokes stage (strokes.classify.run: feature windows, one batched forward pass,
softmax) the way the pipeline calls it. Latency does not depend on what the model learned,
so without --weights a randomly initialised network from configs/stroke_cnn.yaml stands in
and the script runs before training. With --weights the cold checkpoint load is timed too.

Without --record a 1-minute clip is synthesized from the golden record (its frames repeated,
a hit every 60 / --hits-per-min seconds, alternating players). Devices that are not
available (no CUDA) are skipped. Targets: < 5 s on GPU and < 30 s on CPU per 1-minute clip.
"""

from __future__ import annotations

import argparse
import json
import statistics
import time
from pathlib import Path
from typing import Any

from shuttlesense.config import BACKEND_DIR, load_config
from shuttlesense.schema import ClipRecord, Hit, load_record
from shuttlesense.stage import StageContext

RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"


def synthetic_record(duration_s: float = 60.0, hits_per_min: float = 40.0) -> ClipRecord:
    """A clip of `duration_s` built from the golden record's frames, with evenly spaced hits."""
    from shuttlesense.fake import load_golden

    golden = load_golden()
    fps = golden.fps or 30.0
    n = max(1, round(duration_s * fps))
    frames = [golden.frames[i % len(golden.frames)].model_copy(update={"frame": i})
              for i in range(n)]  # fmt: skip
    gap = max(1, round(fps * 60.0 / hits_per_min))
    hits = [Hit(id=k, frame=f, time_s=round(f / fps, 3), player="near" if k % 2 == 0 else "far")
            for k, f in enumerate(range(gap // 2, n, gap))]  # fmt: skip
    return golden.model_copy(update={"frames": frames, "hits": hits, "num_frames": n})


def random_model(use_trajectory: bool = True):
    """(model, checkpoint dict) for an untrained network shaped like the trained one."""
    from shuttlesense.strokes.features import num_features
    from shuttlesense.strokes.model import build_from_config

    cfg = load_config(BACKEND_DIR / "configs" / "stroke_cnn.yaml")
    in_features = num_features(use_trajectory)
    model = build_from_config(in_features, cfg.get("model", {}), len(cfg["data"]["classes"]))
    ckpt = {
        "in_features": in_features,
        "use_trajectory": use_trajectory,
        "window_frames": cfg["data"].get("window_frames", 30),
        "classes": list(cfg["data"]["classes"]),
    }
    return model.eval(), ckpt


def available_devices(wanted: list[str]) -> list[str]:
    import torch

    return [d for d in wanted if d == "cpu" or (d == "cuda" and torch.cuda.is_available())]


def time_device(
    record: ClipRecord, device: str, runs: int = 5, weights: str | None = None
) -> dict[str, Any]:
    """Median wall time of the strokes stage on `device`; also the cold load with weights."""
    from shuttlesense.strokes import classify

    load_s = None
    if weights:
        for key in [k for k in classify._MODELS if k[:2] == (weights, device)]:
            del classify._MODELS[key]  # time a cold load
        start = time.perf_counter()
        loaded = classify.load_classifier(weights, device)
        load_s = time.perf_counter() - start
    else:
        model, ckpt = random_model()
        loaded = (model.to(device), ckpt)
    ctx = StageContext(video_path=Path(), out_dir=Path(), device=device, config={})
    times = []
    real_load = classify.load_classifier
    classify.load_classifier = lambda _path, _device: loaded  # time inference only
    try:
        for _ in range(runs + 1):  # the first run warms up (CUDA kernels, allocator)
            rec = record.model_copy(deep=True)
            start = time.perf_counter()
            classify.run(rec, ctx)
            if device == "cuda":
                import torch

                torch.cuda.synchronize()
            times.append(time.perf_counter() - start)
    finally:
        classify.load_classifier = real_load
    return {
        "device": device,
        "runs": runs,
        "median_s": round(statistics.median(times[1:]), 4),
        "max_s": round(max(times[1:]), 4),
        "first_run_s": round(times[0], 4),
        "load_s": None if load_s is None else round(load_s, 4),
    }


TARGETS = {"cpu": 30.0, "cuda": 5.0}


def time_models(
    record: ClipRecord, names: list[str], devices: list[str], runs: int = 5
) -> list[dict[str, Any]]:
    """One row per installed model and device, timed from its default weights file."""
    from shuttlesense.strokes import registry

    rows = []
    for name in names:
        path = registry.DEFAULT_WEIGHTS[name]
        if not (BACKEND_DIR / path).is_file():
            print(f"{name}: {path} not found, skipped")
            continue
        for device in devices if registry.REQUIRES[name] else ["cpu"]:
            row = time_device(record, device, runs, path)
            row["model"] = registry.LABELS[name]
            row["file_mb"] = round((BACKEND_DIR / path).stat().st_size / 1e6, 2)
            rows.append(row)
    return rows


def models_markdown(result: dict[str, Any]) -> str:
    lines = [
        "# Stroke classifier latency",
        "",
        f"{result['hits']} hits in a {result['duration_s']:.0f} s clip, trained weights from "
        "`backend/weights/strokes/`. The time covers building the feature windows and one "
        "batched prediction, as the pipeline's strokes stage does.",
        "",
        "| Model | Device | Median (s) | Max (s) | First run (s) | Load (s) | File (MB) | Target |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for r in result["models"]:
        target = TARGETS.get(r["device"])
        ok = "met" if target and r["median_s"] < target else "missed"
        lines.append(
            f"| {r['model']} | {r['device']} | {r['median_s']:.3f} | {r['max_s']:.3f} | "
            f"{r['first_run_s']:.3f} | {r['load_s']:.3f} | {r['file_mb']:.2f} | "
            f"< {target:g} s ({ok}) |"
        )
    lines.append("")
    return "\n".join(lines)


def to_markdown(result: dict[str, Any]) -> str:
    targets = TARGETS
    lines = [
        "# Stroke classifier latency",
        "",
        f"{result['hits']} hits in a {result['duration_s']:.0f} s clip, model: {result['model']}.",
        "",
        "| Device | Median (s) | Max (s) | First run (s) | Checkpoint load (s) | Target |",
        "| --- | ---: | ---: | ---: | ---: | --- |",
    ]
    for r in result["devices"]:
        target = targets.get(r["device"])
        ok = "met" if target and r["median_s"] < target else "missed"
        load = "-" if r["load_s"] is None else f"{r['load_s']:.3f}"
        lines.append(
            f"| {r['device']} | {r['median_s']:.3f} | {r['max_s']:.3f} | "
            f"{r['first_run_s']:.3f} | {load} | < {target:g} s ({ok}) |"
        )
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", default=None, help="checkpoint, relative to backend/")
    parser.add_argument("--models", default=None, help="comma-separated: cnn,lstm,rf")
    parser.add_argument("--record", type=Path, default=None)
    parser.add_argument("--duration-s", type=float, default=60.0)
    parser.add_argument("--hits-per-min", type=float, default=40.0)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--devices", default="cpu,cuda")
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "stroke_latency.md")
    args = parser.parse_args()
    try:
        import torch  # noqa: F401
    except ImportError:
        raise SystemExit("torch is not installed: pip install -r requirements/ml.txt") from None

    if args.record:
        record = load_record(args.record.read_text(encoding="utf-8"))
    else:
        record = synthetic_record(args.duration_s, args.hits_per_min)
    devices = available_devices([d for d in args.devices.split(",") if d])
    result: dict[str, Any] = {
        "hits": len(record.hits),
        "duration_s": record.num_frames / (record.fps or 30.0),
    }
    if args.models:
        names = [m for m in args.models.split(",") if m]
        result["models"] = time_models(record, names, devices, args.runs)
        if not result["models"]:
            raise SystemExit("none of the models is installed: train or download the weights")
        markdown = models_markdown(result)
    else:
        result["model"] = args.weights or "random init (configs/stroke_cnn.yaml)"
        result["devices"] = [time_device(record, d, args.runs, args.weights) for d in devices]
        markdown = to_markdown(result)
    print(markdown)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(markdown, encoding="utf-8")
    args.out.with_suffix(".json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.out} and {args.out.with_suffix('.json')}")


if __name__ == "__main__":
    main()
