"""The three selectable stroke models and the BST feature import (Phase 11)."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
import pytest

from shuttlesense import pipeline
from shuttlesense.fake import load_golden
from shuttlesense.schema import STROKE_CLASSES
from shuttlesense.stage import StageContext, StageSkipped
from shuttlesense.strokes import classify, registry
from shuttlesense.strokes.features import (
    POSE_FEATURES,
    build_window,
    pose_vector,
    shuttle_features,
)
from shuttlesense.strokes.rf import Forest, summary_features

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


def load_script(name: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def write_npz(path: Path, n: int, t: int = 30, seed: int = 0) -> None:
    rng = np.random.default_rng(seed)
    y = np.arange(n) % len(STROKE_CLASSES)
    x = rng.normal(0, 0.1, (n, t, 39)).astype(np.float32)
    x[np.arange(n), :, y] += 1.0  # make classes separable
    np.savez(path, X=x, y=y, meta=np.array([f"c{i}" for i in range(n)]))


def train_cfg(algorithm: str) -> dict:
    return {
        "algorithm": algorithm,
        "data": {
            "features_dir": ".",
            "classes": list(STROKE_CLASSES),
            "pose_norm": "bbox_diag",
        },
        "model": {"hidden": 16, "layers": 1, "trees": 20, "max_depth": 6},
        "train": {"epochs": 6, "batch_size": 16, "lr": 0.01, "weight_decay": 0.0,
                  "class_weighting": "inverse_frequency", "early_stopping_patience": 6},
    }  # fmt: skip


def stroke_ctx(**strokes) -> StageContext:
    return StageContext(video_path=None, out_dir=None, config={"stages": {"strokes": strokes}})


# --- features -------------------------------------------------------------------------


def test_pose_norm_divides_by_height_or_diagonal() -> None:
    keypoints = [(13.0, 24.0, 1.0)] * 17
    bbox = (10.0, 20.0, 30.0, 40.0)  # centre (25, 40), height 40, diagonal 50
    by_height = pose_vector(keypoints, bbox)
    by_diag = pose_vector(keypoints, bbox, "bbox_diag")
    assert by_height[:2] == pytest.approx([-12 / 40, -16 / 40])
    assert by_diag[:2] == pytest.approx([-12 / 50, -16 / 50])
    with pytest.raises(ValueError):
        pose_vector(keypoints, bbox, "nope")


def test_shuttle_features_steps_only_between_seen_frames() -> None:
    xy = np.array([[0.1, 0.1], [0.2, 0.3], [0.0, 0.0], [0.5, 0.5], [0.6, 0.4]])
    out = shuttle_features(xy, np.array([True, True, False, True, True]))
    assert out[1] == pytest.approx([0.2, 0.3, 1, 0.1, 0.2])
    assert not out[2].any()  # unseen frame: all zeros
    assert out[3] == pytest.approx([0.5, 0.5, 1, 0, 0])  # no step after a gap
    assert out[4] == pytest.approx([0.6, 0.4, 1, 0.1, -0.1])


# --- BST import -----------------------------------------------------------------------


def make_bst_tree(root: Path) -> None:
    rng = np.random.default_rng(0)
    folders = {
        "Top_殺球": 2,  # smash, top player
        "Bottom_放小球": 1,  # net shot, bottom player
        "Bottom_平球": 3,  # drive: left out
        "未知球種": 1,  # unknown: left out
    }
    for split in ("train", "val", "test"):
        for folder, count in folders.items():
            d = root / split / folder
            d.mkdir(parents=True)
            for i in range(count):
                frames = 30 if i == 0 else 27  # a short clip is padded
                joints = rng.normal(0, 0.1, (frames, 2, 17, 2))
                joints[:, 0] += 1.0  # top player is recognisable
                shuttle = rng.uniform(0.2, 0.8, (frames, 2))
                shuttle[3] = 0.0  # not found on frame 3
                np.save(d / f"1_1_{i}_2_joints.npy", joints)
                np.save(d / f"1_1_{i}_2_shuttle.npy", shuttle)
                np.save(d / f"1_1_{i}_2_pos.npy", np.zeros((frames, 2, 2)))


def test_import_bst_features(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    importer = load_script("import_bst_features")
    src, out = tmp_path / "dataset_npy", tmp_path / "features"
    make_bst_tree(src)
    splits = tmp_path / "splits_bst.json"
    monkeypatch.setattr(
        sys, "argv", ["x", "--src", str(src), "--out", str(out), "--splits", str(splits)]
    )
    importer.main()

    assert json.loads(splits.read_text(encoding="utf-8")) == {
        "train": ["bst_train"],
        "val": ["bst_val"],
        "test": ["bst_test"],
    }
    with np.load(out / "bst_train.npz", allow_pickle=False) as data:
        x, y, meta = data["X"], data["y"], data["meta"]
    assert x.shape == (3, 30, 39) and x.dtype == np.float32
    by_label = dict(zip(meta.tolist(), y.tolist(), strict=True))
    assert by_label["Top_殺球/1_1_0_2"] == STROKE_CLASSES.index("smash")
    assert by_label["Bottom_放小球/1_1_0_2"] == STROKE_CLASSES.index("net_shot")
    top = x[meta.tolist().index("Top_殺球/1_1_0_2")]
    bottom = x[meta.tolist().index("Bottom_放小球/1_1_0_2")]
    assert top[:, :POSE_FEATURES].mean() > 0.8 and abs(bottom[:, :POSE_FEATURES].mean()) < 0.2
    assert top[3, POSE_FEATURES + 2] == 0 and top[4, POSE_FEATURES + 2] == 1  # visible flag
    assert not top[4, POSE_FEATURES + 3 :].any()  # no step right after the gap
    short = x[meta.tolist().index("Top_殺球/1_1_1_2")]
    assert short[:, :POSE_FEATURES].any(axis=1).all()  # stretched over the window: no dead frames


def test_short_bst_clips_keep_the_hit_at_the_window_centre() -> None:
    importer = load_script("import_bst_features")
    frames, window = 25, 30
    joints = np.zeros((frames, 2, 17, 2))
    joints[:, 0] = np.arange(1, frames + 1)[:, None, None]  # frame number + 1 in every value
    shuttle = np.full((frames, 2), 0.5)
    shuttle[:, 0] = np.linspace(0.2, 0.44, frames)  # 0.01 per frame
    shuttle[7] = 0.0  # not found on frame 7

    resampled = importer.clip_window(joints, shuttle, 0, window)
    # The clip centre (frame 12 of 25) lands on the window centre (frame 15 of 30).
    assert resampled[window // 2, 0] == pytest.approx(frames // 2 + 1, abs=0.5)
    assert resampled[:, 0].min() >= 1 and resampled[:, 0].max() <= frames
    assert (np.diff(resampled[:, 0]) >= 0).all()
    seen = resampled[:, POSE_FEATURES + 2] > 0
    assert 0 < (~seen).sum() <= 2  # the gap stays a gap; it is not bridged
    step = resampled[seen, POSE_FEATURES + 3]
    assert step[step != 0] == pytest.approx(0.01 * frames / window, abs=1e-3)  # per 1/30 s

    centred = importer.clip_window(joints, shuttle, 0, window, "centre")
    assert not centred[:3].any() and not centred[28:].any()
    assert centred[window // 2, 0] == frames // 2 + 1
    padded = importer.clip_window(joints, shuttle, 0, window, "end")
    assert padded[0, 0] == 1 and not padded[frames:].any()
    with pytest.raises(ValueError):
        importer.clip_window(joints, shuttle, 0, window, "nope")

    long = np.zeros((31, 2, 17, 2))
    long[:, 0] = np.arange(1, 32)[:, None, None]
    assert importer.clip_window(long, np.zeros((31, 2)), 0, window)[0, 0] == 1


def test_import_matches_build_window() -> None:
    """A BST clip built from the golden record gives the same window as inference."""
    importer = load_script("import_bst_features")
    record = load_golden()
    hit = record.hits[0]
    window = 30
    start = hit.frame - window // 2
    joints = np.zeros((window, 2, 17, 2))
    shuttle = np.zeros((window, 2))
    for t in range(window):
        i = start + t
        if not 0 <= i < len(record.frames):
            continue
        frame = record.frames[i]
        player = getattr(frame.players, hit.player_attr)
        if player:
            pose = pose_vector(player.keypoints, player.bbox, "bbox_diag")
            joints[t, 1] = pose.reshape(17, 2)
        s = frame.shuttle
        if s is not None and s.visible and s.x is not None:
            shuttle[t] = (s.x / record.width, s.y / record.height)
    expected = build_window(record, hit.frame, hit.player_attr, window, True, "bbox_diag")
    assert importer.clip_window(joints, shuttle, 1, window) == pytest.approx(expected, abs=1e-6)


# --- Random Forest --------------------------------------------------------------------


def test_summary_features_shapes_and_empty_windows() -> None:
    rng = np.random.default_rng(0)
    full = summary_features(rng.normal(size=(5, 30, 39)).astype(np.float32))
    pose_only = summary_features(rng.normal(size=(5, 30, 34)).astype(np.float32))
    assert full.shape[0] == 5 and full.shape[1] > pose_only.shape[1]
    empty = summary_features(np.zeros((2, 30, 39), np.float32))
    assert np.isfinite(empty).all()
    assert np.isfinite(summary_features(np.zeros((1, 1, 39), np.float32))).all()


def test_forest_matches_sklearn_and_round_trips(tmp_path: Path) -> None:
    ensemble = pytest.importorskip("sklearn.ensemble")
    rng = np.random.default_rng(0)
    rows = rng.normal(size=(300, 12)).astype(np.float32)
    y = (rows[:, 0] > 0).astype(int) + 2 * (rows[:, 1] > 0).astype(int)  # classes 0..3
    y[y == 2] = 3  # class 2 never appears: its column must stay empty, not shift
    model = ensemble.RandomForestClassifier(n_estimators=15, max_depth=6, random_state=0)
    model.fit(rows, y)
    forest = Forest.from_sklearn(model, {"classes": ["a", "b", "c", "d"]})
    probs = forest.predict_proba(rows)
    assert probs.shape == (300, 4) and not probs[:, 2].any()
    assert probs[:, [0, 1, 3]] == pytest.approx(model.predict_proba(rows), abs=1e-5)

    forest.save(tmp_path / "rf.npz")
    loaded = Forest.load(tmp_path / "rf.npz")  # plain arrays, read with allow_pickle=False
    assert loaded.meta == {"classes": ["a", "b", "c", "d"]}
    assert loaded.predict_proba(rows) == pytest.approx(probs, abs=2e-3)  # float16 leaves


def test_train_rf_and_classify(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    pytest.importorskip("sklearn")
    trainer = load_script("train_stroke_classifier")
    monkeypatch.setattr(trainer, "BACKEND_DIR", tmp_path)
    for i, m in enumerate(("a", "b", "c")):
        write_npz(tmp_path / f"{m}.npz", 90, seed=i)
    result = trainer.train(
        train_cfg("rf"),
        {"train": ["a"], "val": ["b"], "test": ["c"]},
        use_trajectory=True,
        seed=1,
        device="cpu",
    )
    assert result["algorithm"] == "rf" and result["test"]["accuracy"] > 0.8
    trainer.save_checkpoint(result["checkpoint"], tmp_path / "stroke_rf.npz")

    monkeypatch.setattr(classify, "BACKEND_DIR", tmp_path)
    model, ckpt = classify.load_classifier("stroke_rf.npz", "cpu")
    assert ckpt["kind"] == "rf" and ckpt["window_frames"] == 30
    assert ckpt["pose_norm"] == "bbox_diag"
    record = load_golden()
    for h in record.hits:
        h.stroke = h.confidence = h.class_probs = None
    record = classify.run(record, stroke_ctx(algorithm="rf", weights_rf="stroke_rf.npz"))
    assert all(h.stroke in STROKE_CLASSES for h in record.hits)
    assert all(abs(sum(h.class_probs.values()) - 1) < 1e-2 for h in record.hits)


# --- LSTM -----------------------------------------------------------------------------


def test_lstm_forward_shape() -> None:
    torch = pytest.importorskip("torch")
    from shuttlesense.strokes.model import build_from_config

    model = build_from_config(39, {"hidden": 16, "layers": 1}, kind="lstm")
    assert model(torch.zeros(4, 30, 39)).shape == (4, len(STROKE_CLASSES))
    with pytest.raises(ValueError):
        build_from_config(39, {}, kind="rf")


def test_train_lstm_and_classify(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    torch = pytest.importorskip("torch")
    trainer = load_script("train_stroke_classifier")
    monkeypatch.setattr(trainer, "BACKEND_DIR", tmp_path)
    for i, m in enumerate(("a", "b", "c")):
        write_npz(tmp_path / f"{m}.npz", 60, seed=i)
    result = trainer.train(
        train_cfg("lstm"),
        {"train": ["a"], "val": ["b"], "test": ["c"]},
        use_trajectory=True,
        seed=1,
        device="cpu",
    )
    assert result["test"]["accuracy"] > 0.5
    assert result["checkpoint"]["kind"] == "lstm"
    trainer.save_checkpoint(result["checkpoint"], tmp_path / "stroke_lstm.pt")
    assert torch.load(tmp_path / "stroke_lstm.pt", weights_only=True)["window_frames"] == 30

    monkeypatch.setattr(classify, "BACKEND_DIR", tmp_path)
    record = load_golden()
    for h in record.hits:
        h.stroke = None
    record = classify.run(record, stroke_ctx(algorithm="lstm", weights_lstm="stroke_lstm.pt"))
    assert all(h.stroke in STROKE_CLASSES for h in record.hits)


# --- registry -------------------------------------------------------------------------


def test_missing_or_unknown_model_skips_the_stage(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(classify, "BACKEND_DIR", tmp_path)
    record = load_golden()
    with pytest.raises(StageSkipped, match="stroke model not installed$"):
        classify.run(record, stroke_ctx(weights="none.pt"))
    with pytest.raises(StageSkipped, match=r"not installed \(Random Forest\)"):
        classify.run(record, stroke_ctx(algorithm="rf", weights_rf="none.npz"))
    with pytest.raises(StageSkipped, match="'svm' is not implemented"):
        classify.run(record, stroke_ctx(algorithm="svm"))


def test_installed_models_follow_weights_and_packages(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(registry, "BACKEND_DIR", tmp_path)
    monkeypatch.setattr(pipeline, "BACKEND_DIR", tmp_path)
    strokes = {"weights": "cnn.pt", "weights_lstm": "lstm.pt", "weights_rf": "rf.npz"}
    config = {"stages": {"strokes": strokes}}
    assert registry.installed_models(config) == []
    for name in ("cnn.pt", "lstm.pt", "rf.npz"):
        (tmp_path / name).write_bytes(b"x")
    monkeypatch.setattr(registry, "_has", lambda module: True)
    assert registry.installed_models(config) == ["cnn", "lstm", "rf", "ensemble"]
    (tmp_path / "lstm.pt").unlink()  # the ensemble needs all three
    assert registry.installed_models(config) == ["cnn", "rf"]
    (tmp_path / "lstm.pt").write_bytes(b"x")
    assert registry.installed_models({"stages": {"strokes": {**strokes, "enabled": False}}}) == []

    # Without torch only the forest is left, and the stage follows the chosen model.
    monkeypatch.setattr(registry, "_has", lambda module: module != "torch")
    monkeypatch.setattr(pipeline, "_installed", lambda module: module != "torch")
    assert registry.installed_models(config) == ["rf"]
    assert "strokes" not in pipeline.available_stages(config)
    strokes["algorithm"] = "rf"
    assert "strokes" in pipeline.available_stages(config)
    strokes["algorithm"] = "svm"
    assert "strokes" not in pipeline.available_stages(config)


# --- reports --------------------------------------------------------------------------


def test_figures_compare_the_models(tmp_path: Path) -> None:
    from shuttlesense.strokes.metrics import classification_report

    figures = load_script("make_figures")
    classes = list(STROKE_CLASSES)
    rng = np.random.default_rng(0)
    y = np.repeat(np.arange(6), 20)
    names = [
        ("stroke_cnn_metrics_seed1", 0.1),
        ("stroke_cnn_metrics_seed2", 0.1),
        ("stroke_rf_metrics_seed1", 0.3),
        ("stroke_cnn_metrics_pose_only_seed1", 0.4),
    ]
    for name, noise in names:
        pred = np.where(rng.random(len(y)) < noise, (y + 1) % 6, y)
        report = {"test": classification_report(y, pred, classes)}
        (tmp_path / f"{name}.json").write_text(json.dumps(report), encoding="utf-8")

    runs, found = figures.collect_models(["cnn", "lstm", "rf"], tmp_path)
    assert list(runs) == ["cnn", "rf", "cnn_pose_only"] and found == classes  # no LSTM runs
    summary = figures.summarize(runs, classes)
    text = figures.to_markdown(summary, [], note="Trained on the BST features.")
    assert "| 1D CNN | 1, 2 |" in text and "| Random Forest | 1 |" in text
    assert "| 1D CNN, pose only | 1 |" in text and "Trained on the BST features." in text

    pytest.importorskip("matplotlib")
    written = figures.plot(summary, tmp_path / "results")
    assert written == [
        "strokes_confusion_cnn.png",
        "strokes_confusion_rf.png",
        "strokes_per_class_f1.png",
        "strokes_models.png",
    ]


def test_bench_times_installed_models(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    pytest.importorskip("sklearn")
    trainer = load_script("train_stroke_classifier")
    bench = load_script("bench_strokes")
    monkeypatch.setattr(trainer, "BACKEND_DIR", tmp_path)
    write_npz(tmp_path / "a.npz", 60)
    result = trainer.train(
        train_cfg("rf"), {"train": ["a"], "val": ["a"]}, use_trajectory=True, seed=1, device="cpu"
    )
    (tmp_path / "weights" / "strokes").mkdir(parents=True)
    trainer.save_checkpoint(result["checkpoint"], tmp_path / registry.DEFAULT_WEIGHTS["rf"])
    monkeypatch.setattr(classify, "BACKEND_DIR", tmp_path)
    monkeypatch.setattr(bench, "BACKEND_DIR", tmp_path)

    record = bench.synthetic_record(duration_s=5, hits_per_min=60)
    rows = bench.time_models(record, ["cnn", "rf"], ["cpu", "cuda"], runs=1)
    assert [(r["model"], r["device"]) for r in rows] == [("Random Forest", "cpu")]  # no CNN file
    text = bench.models_markdown({"hits": 5, "duration_s": 5.0, "models": rows})
    assert "| Random Forest | cpu |" in text and "< 30 s (met)" in text


# --- options stored with the weights ----------------------------------------------------


def test_summary_v2_leaves_frames_without_data_out() -> None:
    rng = np.random.default_rng(0)
    x = rng.normal(0, 0.1, (4, 30, 39)).astype(np.float32)
    x[:, :, :POSE_FEATURES] += 1.0  # every pose value is positive: a zero frame is the minimum
    x[:, :, POSE_FEATURES + 2] = 1.0  # the shuttle is seen on every frame
    full_v1, full_v2 = summary_features(x), summary_features(x, 2)
    # On complete windows version 2 is version 1 plus two "pose present" columns.
    assert full_v2.shape[1] == full_v1.shape[1] + 2
    assert full_v2[:, :-18] == pytest.approx(full_v1[:, :-16], abs=1e-5)
    assert full_v2[:, -16:] == pytest.approx(full_v1[:, -16:], abs=1e-6)
    assert full_v2[:, -18:-16] == pytest.approx(1.0)

    gap = x.copy()
    gap[:, 24:] = 0.0  # the player and the shuttle are gone for the last six frames
    v1, v2 = summary_features(gap), summary_features(gap, 2)
    low = slice(2 * 39, 2 * 39 + POSE_FEATURES)  # the per-value minimum block, pose columns
    assert v2[:, low] == pytest.approx(x[:, :24, :POSE_FEATURES].min(1), abs=1e-6)
    assert (v1[:, low] == 0).all()  # version 1 reports the empty frames instead
    assert v2[:, -18] == pytest.approx(24 / 30)
    assert np.isfinite(summary_features(np.zeros((2, 30, 39), np.float32), 2)).all()
    assert np.isfinite(summary_features(np.zeros((1, 1, 34), np.float32), 2)).all()
    with pytest.raises(ValueError):
        summary_features(x, 4)


def test_forest_file_names_its_summary_version(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pytest.importorskip("sklearn")
    trainer = load_script("train_stroke_classifier")
    monkeypatch.setattr(trainer, "BACKEND_DIR", tmp_path)
    for i, m in enumerate(("a", "b")):
        write_npz(tmp_path / f"{m}.npz", 90, seed=i)
    cfg = train_cfg("rf")
    cfg["model"]["summary_version"] = 2
    cfg["train"]["shift_copies"] = [-2, 2]
    cfg["data"]["window_fps"] = 30
    result = trainer.train(
        cfg, {"train": ["a"], "val": ["b"], "test": []}, use_trajectory=True, seed=1, device="cpu"
    )
    trainer.save_checkpoint(result["checkpoint"], tmp_path / "stroke_rf.npz")
    monkeypatch.setattr(classify, "BACKEND_DIR", tmp_path)
    model, ckpt = classify.load_classifier("stroke_rf.npz", "cpu")
    assert (ckpt["summary_version"], ckpt["window_fps"]) == (2, 30.0)
    x = np.zeros((3, 30, 39), np.float32)
    assert classify.predict_proba(model, "rf", x, "cpu").shape == (3, len(STROKE_CLASSES))
    record = load_golden()
    record = classify.run(record, stroke_ctx(algorithm="rf", weights_rf="stroke_rf.npz"))
    assert all(h.stroke in STROKE_CLASSES for h in record.hits)


def test_window_covers_the_training_time_span_at_another_frame_rate() -> None:
    record = load_golden()  # 30 fps
    hit, window = 30, 30
    same = build_window(record, hit, "near", window, True, "bbox_diag")
    assert (build_window(record, hit, "near", window, True, "bbox_diag", 30.0) == same).all()

    # The same rally filmed at 15 fps: every second frame.
    half = record.model_copy(update={"frames": record.frames[::2], "fps": record.fps / 2})
    plain = build_window(half, hit // 2, "near", window, True, "bbox_diag")
    timed = build_window(half, hit // 2, "near", window, True, "bbox_diag", 30.0)
    even = np.arange(window) % 2 == (window // 2) % 2  # samples that fall on a 15 fps frame
    inside = (hit + np.arange(window) - window // 2 >= 0) & (
        hit + np.arange(window) - window // 2 < len(record.frames) - 1
    )
    pose = slice(0, POSE_FEATURES)
    assert timed[even & inside, pose] == pytest.approx(same[even & inside, pose], abs=1e-5)
    # Without the frame rate the window spans twice the time and no longer lines up.
    where = slice(POSE_FEATURES, POSE_FEATURES + 2)  # the shuttle position
    assert timed[even & inside, where] == pytest.approx(same[even & inside, where], abs=1e-5)
    assert np.abs(plain[even & inside, where] - same[even & inside, where]).max() > 0.01
    # Shuttle steps are per 1/30 s again, not per 15 fps frame.
    moving = (timed[:, POSE_FEATURES + 3] != 0) & (same[:, POSE_FEATURES + 3] != 0)
    assert moving.sum() >= 5
    ratio = (
        np.abs(timed[moving, POSE_FEATURES + 3 :]).sum()
        / np.abs(same[moving, POSE_FEATURES + 3 :]).sum()
    )
    assert ratio == pytest.approx(1.0, abs=0.25)


def test_sample_rows_never_bridges_a_gap() -> None:
    from shuttlesense.strokes.features import sample_rows

    values = np.array([[0.0], [1.0], [9.0], [3.0]], np.float32)
    valid = np.array([True, True, False, True])
    rows, ok = sample_rows(values, valid, np.array([0.0, 0.5, 1.4, 1.6, 2.6, 3.0, 3.6, -1.0]))
    assert rows[:, 0] == pytest.approx([0.0, 0.5, 1.0, 0.0, 3.0, 3.0, 0.0, 0.0])
    assert ok.tolist() == [True, True, True, False, True, True, False, False]
    assert sample_rows(np.zeros((0, 2)), np.zeros(0, bool), np.array([0.0]))[1].tolist() == [False]


def test_temperature_rescales_confidence_only() -> None:
    trainer = load_script("train_stroke_classifier")
    rng = np.random.default_rng(0)
    logits = rng.normal(0, 2, (4000, 6))
    probs = np.exp(logits) / np.exp(logits).sum(1, keepdims=True)
    y = np.array([rng.choice(6, p=p) for p in probs])
    assert trainer.fit_temperature(logits, y) == pytest.approx(1.0, abs=0.1)
    hot = trainer.fit_temperature(logits * 3, y)  # three times too confident
    assert hot == pytest.approx(3.0, abs=0.3)
    assert trainer.nll(logits * 3, y, hot) < trainer.nll(logits * 3, y)
    assert trainer.fit_temperature(np.zeros((0, 6)), np.zeros(0, int)) == 1.0

    torch = pytest.importorskip("torch")
    from shuttlesense.strokes.model import build_model

    torch.manual_seed(0)
    model = build_model(39, len(STROKE_CLASSES)).eval()
    x = rng.normal(0, 1, (8, 30, 39)).astype(np.float32)
    plain = classify.predict_proba(model, "cnn", x, "cpu")
    cooled = classify.predict_proba(model, "cnn", x, "cpu", temperature=4.0)
    assert (plain.argmax(1) == cooled.argmax(1)).all()
    assert cooled.max(1).mean() < plain.max(1).mean()
    assert cooled.sum(1) == pytest.approx(1.0, abs=1e-5)


def test_shift_range_and_shifted_copies() -> None:
    from shuttlesense.strokes.dataset import augment, shift_window

    x = np.arange(1, 7, dtype=np.float32)[:, None] * np.ones((1, 39), np.float32)
    later = shift_window(x.copy(), 2)
    assert later[:, 0].tolist() == [0, 0, 1, 2, 3, 4]
    assert shift_window(x.copy(), -1)[:, 0].tolist() == [2, 3, 4, 5, 6, 0]
    assert shift_window(x, 0) is x
    rng = np.random.default_rng(0)
    still = [augment(x.copy(), rng, True, noise=0.0, max_shift=0)[:, 40 % 39] for _ in range(8)]
    assert all(row.tolist() == x[:, 1].tolist() for row in still)
    starts = {int(np.argmax(augment(x.copy(), rng, False, 0.0, 4)[:, 1] > 0)) for _ in range(200)}
    assert max(starts) == 4  # up to four frames late


# --- ensemble -------------------------------------------------------------------------


def test_average_probabilities_follows_each_models_class_order() -> None:
    a = (np.array([[0.9, 0.1]]), ["smash", "drop"])
    b = (np.array([[0.6, 0.4]]), ["drop", "smash"])  # the other order
    out = classify.average_probabilities([a, b], ["smash", "drop"])
    assert out[0] == pytest.approx([0.65, 0.35])
    # A class one model does not know counts as 0 for it, and the rows still sum to 1.
    c = (np.array([[1.0]]), ["smash"])
    out = classify.average_probabilities([a, c], ["smash", "drop"])
    assert out[0] == pytest.approx([0.95, 0.05]) and out.sum() == pytest.approx(1.0)


def test_ensemble_runs_the_three_models_and_averages(monkeypatch: pytest.MonkeyPatch) -> None:
    record = load_golden()
    classes = list(STROKE_CLASSES)
    seen = []

    def fake(_record, _ctx, name, _slots):
        seen.append(name)
        p = np.full((len(record.hits), len(classes)), 0.02)
        # CNN and LSTM lean towards a drop, the forest is sure of a smash.
        p[:, classes.index("drop")] = {"cnn": 0.5, "lstm": 0.5, "rf": 0.02}[name]
        p[:, classes.index("smash")] = {"cnn": 0.4, "lstm": 0.4, "rf": 0.9}[name]
        return p, classes

    monkeypatch.setattr(classify, "model_probabilities", fake)
    ctx = stroke_ctx(algorithm="ensemble", context={"enabled": False})
    record = classify.run(record, ctx)
    assert seen == ["cnn", "lstm", "rf"]
    assert record.stroke_model == "ensemble"
    assert all(h.stroke == "smash" for h in record.hits)
    assert all(abs(sum(h.class_probs.values()) - 1) < 1e-2 for h in record.hits)

    seen.clear()
    record = classify.run(record, stroke_ctx(algorithm="rf", context={"enabled": False}))
    assert seen == ["rf"] and record.stroke_model == "rf"


def test_ensemble_names_the_member_that_is_missing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(classify, "BACKEND_DIR", tmp_path)
    with pytest.raises(StageSkipped, match="stroke model not installed$"):
        classify.run(load_golden(), stroke_ctx(algorithm="ensemble", weights="none.pt"))
    # Live and Watch sessions load "the model's checkpoint": for the ensemble, its lead's.
    assert registry.weights_path({"weights": "a.pt"}, "ensemble") == "a.pt"
    assert registry.all_weights({}, "ensemble") == [
        registry.DEFAULT_WEIGHTS[m] for m in ("cnn", "lstm", "rf")
    ]
