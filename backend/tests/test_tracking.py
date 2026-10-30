from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from shuttlesense.schema import ClipRecord, Frame
from shuttlesense.stage import StageContext
from shuttlesense.tracking import heatmap_to_xy, rectify, remove_outliers, scale_to_video
from shuttlesense.tracking import run as tracking_run
from shuttlesense.tracking.postprocess import read_tracking_csv, write_tracking_csv


def test_heatmap_to_xy_picks_peak() -> None:
    heat = np.zeros((72, 128))
    heat[10:13, 20:23] = 0.9  # small blob
    heat[40:46, 60:66] = 0.8  # largest blob wins
    x, y, vis = heatmap_to_xy(heat, threshold=0.5)
    assert vis == 1 and (x, y) == (62.5, 42.5)
    assert heatmap_to_xy(np.zeros((8, 8)))[2] == 0


def test_scale_back_to_video_pixels() -> None:
    out = scale_to_video(np.array([[256.0, 144.0]]), (512, 288), (1280, 720))
    assert out.tolist() == [[640.0, 360.0]]


def test_outlier_removed() -> None:
    xy = np.array([[10, 10], [12, 11], [14, 12], [0, 0], [0, 0], [400, 300], [0, 0], [0, 0]], float)
    visible = np.array([1, 1, 1, 0, 0, 1, 0, 0])
    assert remove_outliers(xy, visible, outlier_px=80).tolist() == [1, 1, 1, 0, 0, 0, 0, 0]
    near = xy.copy()
    near[5] = [30, 20]
    assert remove_outliers(near, visible, outlier_px=80)[5] == 1


def test_long_gap_not_filled() -> None:
    xy = np.array([[0, 0]] + [[0, 0]] * 5 + [[60, 0], [70, 0], [0, 0], [90, 0]], float)
    visible = np.array([1, 0, 0, 0, 0, 0, 1, 1, 0, 1])
    out_xy, out_vis, source = rectify(xy, visible, max_gap=2, outlier_px=1000)
    assert out_vis.tolist() == [1, 0, 0, 0, 0, 0, 1, 1, 1, 1]
    assert source[8] == "interp" and source[7] == "net" and source[2] == ""
    assert out_xy[8].tolist() == [80.0, 0.0]


def test_stage_reads_precomputed_csv(tmp_path: Path) -> None:
    xy = np.array([[10.0, 20.0], [0, 0], [30.0, 40.0]])
    write_tracking_csv(tmp_path / "in.csv", xy, np.array([1, 0, 1]))
    assert read_tracking_csv(tmp_path / "in.csv", 3)[1].tolist() == [1, 0, 1]
    record = ClipRecord(clip_id="c", fps=30, width=64, height=48, num_frames=3,
                        frames=[Frame(frame=i) for i in range(3)])  # fmt: skip
    ctx = StageContext(
        video_path=tmp_path / "v.mp4",
        out_dir=tmp_path / "out",
        config={"stages": {"tracking": {"precomputed_csv": str(tmp_path / "in.csv")}}},
    )
    record = tracking_run(record, ctx)
    assert record.frames[1].shuttle.visible == 1  # 1-frame gap interpolated
    assert (record.frames[1].shuttle.x, record.frames[1].shuttle.y) == (20.0, 30.0)
    assert (tmp_path / "out" / "tracking.csv").read_text().splitlines()[2].endswith("interp")


def test_precomputed_csv_maps_source_frames_and_pixels(tmp_path: Path) -> None:
    from types import SimpleNamespace

    # 60 fps 1080p source, normalized to 30 fps 720p: keep even frames, scale by 2/3.
    rows = ["Frame,Visibility,X,Y"] + [f"{i},1,{300 + i},{600}" for i in range(8)]
    (tmp_path / "up.csv").write_text("\n".join(rows) + "\n")
    reader = SimpleNamespace(
        step=2, width=1280, height=720, source=SimpleNamespace(width=1920, height=1080)
    )
    record = ClipRecord(clip_id="c", fps=30, width=1280, height=720, num_frames=4,
                        frames=[Frame(frame=i) for i in range(4)])  # fmt: skip
    ctx = StageContext(
        video_path=tmp_path / "v.mp4",
        out_dir=tmp_path / "out",
        config={"stages": {"tracking": {"precomputed_csv": str(tmp_path / "up.csv")}}},
        reader=reader,
    )
    record = tracking_run(record, ctx)
    assert [f.shuttle.x for f in record.frames] == [200.0, 201.3, 202.7, 204.0]
    assert record.frames[3].shuttle.y == 400.0


REPO = Path(__file__).resolve().parents[2]


@pytest.mark.gpu
def test_tracknet_follows_the_shuttle_on_rally01(tmp_path: Path) -> None:
    """T2.2 smoke test: TrackNetV3 on the team's first test rally, on the GPU."""
    torch = pytest.importorskip("torch")
    from shuttlesense.config import BACKEND_DIR, load_config
    from shuttlesense.pipeline import run_pipeline

    video = REPO / "samples" / "rally01.mp4"
    config = load_config()
    weights = config.get("stages", {}).get("tracking", {}).get("tracknet_weights", "")
    if not torch.cuda.is_available():
        pytest.skip("no CUDA device")
    if not video.exists() or not weights or not (BACKEND_DIR / weights).exists():
        pytest.skip("samples/rally01.mp4 or the TrackNetV3 weights are missing")
    for name in ("pose", "hits", "strokes", "feedback", "render"):
        config.setdefault("stages", {}).setdefault(name, {})["enabled"] = False
    record = run_pipeline(video, tmp_path, clip_id="rally01", config=config, device="cuda")
    visible = sum(1 for f in record.frames if f.shuttle and f.shuttle.visible)
    assert visible > 0.5 * len(record.frames)
    assert (tmp_path / "tracking.csv").exists()
