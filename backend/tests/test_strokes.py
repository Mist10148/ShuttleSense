from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import numpy as np
import pytest

from shuttlesense.fake import load_golden
from shuttlesense.schema import STROKE_CLASSES
from shuttlesense.stage import StageContext
from shuttlesense.strokes.dataset import StrokeDataset
from shuttlesense.strokes.metrics import classification_report


def write_npz(path: Path, n: int, f: int = 39, t: int = 32, seed: int = 0) -> None:
    rng = np.random.default_rng(seed)
    y = np.arange(n) % len(STROKE_CLASSES)
    x = rng.normal(0, 0.1, (n, t, f)).astype(np.float32)
    x[np.arange(n), :, y] += 1.0  # make classes separable
    np.savez(path, X=x, y=y, meta=np.array([f"c{i}" for i in range(n)]))


def test_dataset_reads_npz(tmp_path: Path) -> None:
    write_npz(tmp_path / "m1.npz", 12)
    write_npz(tmp_path / "m2.npz", 6)
    ds = StrokeDataset(tmp_path, ["m1", "m2"])
    assert len(ds) == 18 and ds.in_features == 39
    x, y = ds[0]
    assert x.shape == (39, 32) and x.dtype == np.float32 and y == 0
    pose_only = StrokeDataset(tmp_path, ["m1"], use_trajectory=False)
    assert pose_only.in_features == 34
    weights = ds.class_weights(len(STROKE_CLASSES))
    assert weights.shape == (6,) and np.isclose(weights.mean(), 1.0)


def test_classification_report() -> None:
    report = classification_report([0, 0, 1, 1, 2], [0, 1, 1, 1, 0], ["a", "b", "c"])
    assert report["accuracy"] == pytest.approx(0.6)
    assert report["macro_accuracy"] == pytest.approx((0.5 + 1.0 + 0.0) / 3)
    assert report["confusion_matrix"] == [[1, 1, 0], [0, 2, 0], [1, 0, 0]]


def test_model_forward_shape() -> None:
    torch = pytest.importorskip("torch")
    from shuttlesense.strokes.model import build_from_config

    model = build_from_config(39, {"channels": [16, 32], "kernel_sizes": [3, 3]})
    assert model(torch.zeros(4, 39, 32)).shape == (4, len(STROKE_CLASSES))


def test_classify_fills_fields_with_dummy_model(monkeypatch: pytest.MonkeyPatch) -> None:
    torch = pytest.importorskip("torch")
    from shuttlesense.strokes import classify

    class Fixed(torch.nn.Module):
        def forward(self, x):
            logits = torch.zeros(len(x), len(STROKE_CLASSES))
            logits[:, 0] = 3.0  # always "smash"
            return logits

    monkeypatch.setattr(
        classify, "load_classifier", lambda _p, _d: (Fixed(), {"use_trajectory": True})
    )
    record = load_golden()
    for h in record.hits:
        h.stroke = h.confidence = h.class_probs = None
    # The model's own answer: the rally and court context (test_stroke_context.py) is off.
    config = {"stages": {"strokes": {"context": {"enabled": False}}}}
    record = classify.run(record, StageContext(video_path=None, out_dir=None, config=config))
    assert {h.stroke for h in record.hits} == {"smash"}
    assert all(h.confidence > 0.7 and abs(sum(h.class_probs.values()) - 1) < 1e-3
               for h in record.hits)  # fmt: skip


def test_training_script_end_to_end(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    pytest.importorskip("torch")
    spec = importlib.util.spec_from_file_location(
        "train_stroke_classifier",
        Path(__file__).resolve().parent.parent / "scripts" / "train_stroke_classifier.py",
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["train_stroke_classifier"] = module
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "BACKEND_DIR", tmp_path)
    for i, m in enumerate(("a", "b", "c")):
        write_npz(tmp_path / f"{m}.npz", 60, seed=i)
    cfg = {
        "data": {"features_dir": ".", "classes": list(STROKE_CLASSES)},
        "model": {"channels": [16, 16], "kernel_sizes": [3, 3]},
        "train": {"epochs": 5, "batch_size": 16, "lr": 0.01, "weight_decay": 0.0,
                  "class_weighting": "inverse_frequency", "early_stopping_patience": 5},
    }  # fmt: skip
    result = module.train(cfg, {"train": ["a"], "val": ["b"], "test": ["c"]},
                          use_trajectory=True, seed=1, device="cpu")  # fmt: skip
    assert result["test"]["accuracy"] > 0.5
    assert result["checkpoint"]["in_features"] == 39
    assert result["checkpoint"]["window_frames"] == 32

    # The saved checkpoint loads without unpickling code, and inference uses its window.
    import torch

    from shuttlesense.strokes import classify

    torch.save(result["checkpoint"], tmp_path / "stroke.pt")
    monkeypatch.setattr(classify, "BACKEND_DIR", tmp_path)
    model, ckpt = classify.load_classifier("stroke.pt", "cpu")
    assert ckpt["window_frames"] == 32 and not model.training
    assert classify.load_classifier("stroke.pt", "cpu")[0] is model  # loaded once

    # New weights dropped in while the server runs are loaded, not the cached model.
    import os

    result["checkpoint"]["window_frames"] = 24
    torch.save(result["checkpoint"], tmp_path / "stroke.pt")
    stat = (tmp_path / "stroke.pt").stat()
    os.utime(tmp_path / "stroke.pt", ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000))
    assert classify.load_classifier("stroke.pt", "cpu")[1]["window_frames"] == 24


def test_make_figures_summarizes_seeds_and_ablation(tmp_path: Path) -> None:
    import json

    from shuttlesense.strokes.metrics import classification_report

    spec = importlib.util.spec_from_file_location(
        "make_figures", Path(__file__).resolve().parent.parent / "scripts" / "make_figures.py"
    )
    figures = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(figures)

    classes = list(STROKE_CLASSES)
    rng = np.random.default_rng(0)
    y = np.repeat(np.arange(6), 20)
    for name, noise in [("m_seed1", 0.1), ("m_seed2", 0.2), ("m_pose_only_seed1", 0.4),
                        ("m_pose_only_seed2", 0.5)]:  # fmt: skip
        pred = np.where(rng.random(len(y)) < noise, (y + 1) % 6, y)
        report = classification_report(y, pred, classes)
        (tmp_path / f"{name}.json").write_text(json.dumps({"test": report}), encoding="utf-8")
    (tmp_path / "m_seed3.json").write_text("{}", encoding="utf-8")  # no test section: ignored
    (tmp_path / "other_seed1.json").write_text("{}", encoding="utf-8")

    runs = figures.collect(tmp_path, "m")
    assert [r["seed"] for r in runs["full"]] == [1, 2] and len(runs["pose_only"]) == 2
    summary = figures.summarize(runs, classes)
    full, pose = summary["variants"]["full"], summary["variants"]["pose_only"]
    assert full["macro_accuracy"]["mean"] > pose["macro_accuracy"]["mean"]
    assert full["macro_accuracy"]["std"] > 0
    assert sum(map(sum, full["confusion_matrix"])) == 2 * len(y)
    assert full["confused_pairs"][0]["predicted"] != full["confused_pairs"][0]["true"]
    text = figures.to_markdown(summary, ["strokes_confusion.png"])
    assert "| pose + shuttle | 1, 2 |" in text and "![strokes_confusion.png]" in text

    pytest.importorskip("matplotlib")
    written = figures.plot(summary, tmp_path / "results")
    assert written == ["strokes_confusion.png", "strokes_per_class_f1.png", "strokes_ablation.png"]
    assert all((tmp_path / "results" / f).stat().st_size > 1000 for f in written)


def test_training_outputs_are_named_per_seed() -> None:
    spec = importlib.util.spec_from_file_location(
        "train_stroke_classifier",
        Path(__file__).resolve().parent.parent / "scripts" / "train_stroke_classifier.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    base = Path("weights/strokes/stroke_cnn.pt")
    assert module.output_path(base, "", 3).name == "stroke_cnn_seed3.pt"
    assert module.output_path(base, "_pose_only", 3).name == "stroke_cnn_pose_only_seed3.pt"
    assert module.output_path(base, "", None).name == "stroke_cnn.pt"


def test_extra_augmentation_is_off_by_default_and_keeps_the_window_shape() -> None:
    from shuttlesense.strokes.dataset import augment
    from shuttlesense.strokes.features import POSE_FEATURES

    x = np.ones((30, POSE_FEATURES + 5), dtype=np.float32)
    plain = augment(x.copy(), np.random.default_rng(0), True, noise=0.0, max_shift=0)
    # Only the mirror can change a window of ones: every value keeps its size.
    assert np.allclose(np.abs(plain[:, :POSE_FEATURES]), 1.0)

    rng = np.random.default_rng(0)
    out = augment(
        x.copy(),
        rng,
        True,
        noise=0.0,
        max_shift=0,
        scale_jitter=0.1,
        keypoint_dropout=0.5,
        shuttle_dropout=1.0,
    )
    assert out.shape == x.shape
    pose = np.abs(out[:, :POSE_FEATURES]).reshape(30, -1, 2)
    lost = (pose == 0).all(axis=(0, 2))
    assert 0 < lost.sum() < pose.shape[1]  # some joints are gone for the whole window
    kept = pose[:, ~lost]
    assert np.allclose(kept, kept[0, 0, 0]) and 0.9 <= kept[0, 0, 0] <= 1.1  # one scale
    hidden = (out[:, POSE_FEATURES + 2] == 0).sum()
    assert 2 <= hidden <= 8  # one run of frames without the shuttle
