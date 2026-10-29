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
    record = classify.run(record, StageContext(video_path=None, out_dir=None))
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
