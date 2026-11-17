from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from shuttlesense.schema import ClipRecord, Frame
from shuttlesense.stage import StageContext
from shuttlesense.tracking import heatmap_to_xy, rectify, remove_outliers, scale_to_video, tracknet
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


def test_burst_of_false_detections_is_removed() -> None:
    # A steady flight with three frames where the tracker jumped to a racket far away.
    xy = np.array([[100 + 10 * i, 200 + 4 * i] for i in range(12)], float)
    xy[5:8] = [[900, 80], [905, 82], [903, 81]]
    visible = np.ones(12, dtype=int)
    assert remove_outliers(xy, visible, outlier_px=80).tolist() == [1] * 5 + [0] * 3 + [1] * 4
    # The fastest real flight (a smash, well under 200 px a frame) is left alone.
    smash = np.array([[100 + 150 * i, 100 + 60 * i] for i in range(6)], float)
    assert remove_outliers(smash, np.ones(6, dtype=int), outlier_px=80).all()
    # A long run off the track is not a burst: the track may simply have moved there.
    moved = xy.copy()
    moved[5:] = [[900 + i, 80] for i in range(7)]
    assert remove_outliers(moved, visible, outlier_px=80).all()


def test_gap_fill_follows_a_curved_flight() -> None:
    # A parabola with three frames missing at the top: the fill keeps the curve, where a
    # straight line would leave a corner at each end of the gap.
    t = np.arange(11, dtype=float)
    xy = np.stack([100 + 20 * t, 300 - 60 * t + 6 * t**2], axis=1)
    visible = np.ones(11, dtype=int)
    visible[4:7] = 0
    out_xy, out_vis, source = rectify(xy * visible[:, None], visible, max_gap=8, outlier_px=1000)
    assert out_vis.all() and source[4:7] == ["interp"] * 3
    assert np.abs(out_xy[4:7] - xy[4:7]).max() < 8.0
    linear = xy[3] + (xy[7] - xy[3]) * (np.arange(1, 4)[:, None] / 4)
    assert np.abs(linear - xy[4:7]).max() > 15.0


def test_inpaint_mask_leaves_long_gaps_alone() -> None:
    xy = np.full((40, 2), 50.0)
    visible = np.zeros(40, dtype=int)
    visible[[0, 4, 39]] = 1
    mask = tracknet._inpaint_mask(xy, visible, 100, max_gap=30)
    assert mask[1:4].all() and not mask[5:39].any()
    assert tracknet._inpaint_mask(xy, visible, 100)[5:39].all()  # no limit given


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


def test_tracknet_input_channels_and_inpaint_mask() -> None:
    frames = [np.zeros((48, 64, 3), dtype=np.uint8) for _ in range(3)]
    median = np.zeros_like(frames[0])
    assert tracknet._track_input(frames, "", None).shape == (9, 288, 512)
    assert tracknet._track_input(frames, "concat", median).shape == (12, 288, 512)
    assert tracknet._track_input(frames, "subtract", median).shape == (3, 288, 512)
    assert tracknet._track_input(frames, "subtract_concat", median).shape == (12, 288, 512)
    xy = np.array([[10, 20], [0, 0], [0, 0], [20, 30]], float)
    assert tracknet._inpaint_mask(xy, np.array([1, 0, 0, 1]), 100).tolist() == [0, 1, 1, 0]


def test_latest_only_decodes_the_same_final_point(monkeypatch) -> None:
    torch = pytest.importorskip("torch")
    calls = []

    def decode(heatmap):
        calls.append(1)
        return float(heatmap[0, 0]), 2.0, 1

    monkeypatch.setattr(tracknet, "heatmap_to_xy", decode)

    def model(batch):
        return torch.tensor([[[[1.0]], [[2.0]], [[3.0]]]]).repeat(len(batch), 1, 1, 1)

    frame = np.zeros((288, 512, 3), dtype=np.uint8)
    windows = [[frame] * 3, [frame] * 3]
    full = tracknet.track_windows(model, windows, "", None, "cpu", (512, 288))
    assert len(calls) == 6
    calls.clear()
    latest = tracknet.track_windows(model, windows, "", None, "cpu", (512, 288), latest_only=True)
    assert latest == [[sequence[-1]] for sequence in full]
    assert len(calls) == 2


def test_tracknet_predict_maps_padded_windows(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    torch = pytest.importorskip("torch")

    class Reader:
        width, height = 1024, 576

        def __len__(self):
            return 5

        def batch(self, start, size):
            return [np.zeros((48, 64, 3), dtype=np.uint8) for _ in range(min(size, 5 - start))]

    class Model:
        def __call__(self, batch):
            out = torch.zeros((batch.shape[0], 3, 288, 512))
            out[:, :, 70:73, 120:123] = 0.9
            return out

    monkeypatch.setattr(tracknet, "_load_model", lambda *_: (Model(), 3, ""))
    progress = []
    ctx = StageContext(
        video_path=tmp_path / "v.mp4",
        out_dir=tmp_path,
        config={"stages": {"tracking": {"batch_size": 2, "use_inpaintnet": False}}},
        reader=Reader(),
        progress=progress.append,
    )
    xy, visible, source = tracknet.predict(ctx, tmp_path / "unused.pt")
    assert visible.tolist() == [1] * 5
    assert source == ["net"] * 5
    assert xy.tolist() == [[242.0, 142.0]] * 5
    assert progress[-1] == 0.9


def test_tracknet_inpaints_internal_gap(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    torch = pytest.importorskip("torch")

    class Reader:
        width, height = 1024, 576

        def __len__(self):
            return 4

        def batch(self, start, size):
            return [np.zeros((48, 64, 3), dtype=np.uint8) for _ in range(min(size, 4 - start))]

    class TrackModel:
        def __call__(self, batch):
            out = torch.zeros((batch.shape[0], 4, 288, 512))
            out[:, 0, 70:73, 120:123] = 0.9
            out[:, 3, 80:83, 130:133] = 0.9
            return out

    class InpaintModel:
        def __call__(self, coordinates, mask):
            assert mask[0, :, 0].tolist() == [0, 1, 1, 0]
            return torch.full_like(coordinates, 0.5)

    def load(_path, _device, kind):
        return (TrackModel(), 4, "") if kind == "tracknet" else (InpaintModel(), 4, "")

    monkeypatch.setattr(tracknet, "_load_model", load)
    weight = tmp_path / "inpaint.pt"
    weight.write_bytes(b"fixture")
    ctx = StageContext(
        video_path=tmp_path / "v.mp4",
        out_dir=tmp_path,
        config={
            "stages": {"tracking": {"use_inpaintnet": True, "inpaintnet_weights": str(weight)}}
        },
        reader=Reader(),
    )
    xy, visible, source = tracknet.predict(ctx, tmp_path / "track.pt")
    assert visible.tolist() == [1, 1, 1, 1]
    assert source == ["net", "inpaint", "inpaint", "net"]
    assert xy[1:3].tolist() == [[512.0, 288.0], [512.0, 288.0]]


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


def test_tracknet_runs_on_cpu_from_a_checkpoint(tmp_path: Path) -> None:
    """T2.2 "CPU fallback works": a real TrackNet (random weights, no download) is loaded
    from a checkpoint file with map_location="cpu" and run on CPU, without autocast."""
    torch = pytest.importorskip("torch")
    tracknet._tracknet_path()
    from model import TrackNet  # the pinned TrackNetV3 submodule

    seq_len = 2
    torch.manual_seed(0)
    model = TrackNet(in_dim=seq_len * 3, out_dim=seq_len)
    weights = tmp_path / "tracknet_random.pt"
    torch.save({"param_dict": {"seq_len": seq_len, "bg_mode": ""},
                "model": model.state_dict()}, weights)  # fmt: skip

    class Reader:
        width, height = 320, 180

        def __len__(self):
            return 3  # one full window and a partial one

        def batch(self, start, size):
            rng = np.random.default_rng(start)
            return [rng.integers(0, 255, (180, 320, 3), dtype=np.uint8)
                    for _ in range(min(size, 3 - start))]  # fmt: skip

    ctx = StageContext(
        video_path=tmp_path / "v.mp4",
        out_dir=tmp_path,
        config={"stages": {"tracking": {"batch_size": 1, "use_inpaintnet": False}}},
        reader=Reader(),
        device="cpu",
    )
    xy, visible, source = tracknet.predict(ctx, weights)
    assert xy.shape == (3, 2) and visible.shape == (3,)
    assert set(visible.tolist()) <= {0, 1} and len(source) == 3
    assert np.isfinite(xy).all()


@pytest.mark.parametrize("mode", ["", "concat", "subtract", "subtract_concat"])
def test_cached_tracknet_inputs_are_exact_for_all_background_modes(mode):
    import cv2

    rng = np.random.default_rng(121)
    frames = [rng.integers(0, 256, (73, 121, 3), dtype=np.uint8) for _ in range(3)]
    median = rng.integers(0, 256, (73, 121, 3), dtype=np.uint8) if mode else None
    prepared = [cv2.resize(frame[:, :, ::-1], tracknet.INPUT_SIZE) for frame in frames]
    assert np.array_equal(
        tracknet._track_input(frames, mode, median),
        tracknet._track_input_rgb(prepared, mode, median),
    )


def test_ensemble_weights_favour_the_middle_of_a_window() -> None:
    from shuttlesense.tracking.ensemble import ensemble_weights, window_starts

    weights = ensemble_weights(8)
    assert weights.sum() == pytest.approx(1.0)
    assert weights.tolist() == pytest.approx(weights[::-1].tolist())
    assert weights[3] > weights[1] > weights[0]
    assert window_starts(10, 8, 4) == [0, 4, 8]
    assert window_starts(10, 8, 99) == [0, 8]


def test_overlapping_windows_average_out_a_one_window_miss(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A frame one window misses at its edge is found when the next window sees it mid-flight."""
    torch = pytest.importorskip("torch")

    class Reader:
        width, height = 1024, 576

        def __init__(self) -> None:
            self.reads: list[int] = []

        def __len__(self):
            return 10

        def batch(self, start, size):
            self.reads.append(start)
            # The frame's index rides in the pixel values so the model can tell windows apart.
            return [
                np.full((48, 64, 3), i, dtype=np.uint8) for i in range(start, min(start + size, 10))
            ]

    class Model:
        def __call__(self, batch):
            out = torch.zeros((batch.shape[0], 4, 288, 512))
            out[:, :, 70:73, 120:123] = 0.9
            for b in range(batch.shape[0]):
                first = int(round(float(batch[b, 0, 0, 0]) * 255))
                if first == 0:
                    out[b, 3] = 0.0  # the window starting at 0 misses its last frame (3)
            return out

    monkeypatch.setattr(tracknet, "_load_model", lambda *_: (Model(), 4, ""))

    def run(stride):
        reader = Reader()
        ctx = StageContext(
            video_path=tmp_path / "v.mp4",
            out_dir=tmp_path,
            config={
                "stages": {
                    "tracking": {"batch_size": 2, "use_inpaintnet": False, "window_stride": stride}
                }
            },
            reader=reader,
        )
        return (*tracknet.predict(ctx, tmp_path / "unused.pt"), reader.reads)

    xy, visible, source, reads = run(None)
    assert visible.tolist() == [1, 1, 1, 0, 1, 1, 1, 1, 1, 1]
    assert reads == [0, 4, 8]

    xy, visible, source, reads = run(2)
    assert reads == [0, 2, 4, 6, 8]
    assert visible.tolist() == [1] * 10
    assert source == ["net"] * 10
    assert xy.tolist() == [[242.0, 142.0]] * 10
