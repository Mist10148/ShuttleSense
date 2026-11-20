from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from shuttlesense.render.writer import VideoWriter, ffmpeg_command, find_ffmpeg, nvenc_available


def _frames(n: int, size: tuple[int, int] = (64, 48)):
    w, h = size
    for i in range(n):
        img = np.zeros((h, w, 3), dtype=np.uint8)
        img[:, : (i * 4) % w] = 200
        yield img


def _count(path: Path) -> int:
    import cv2

    cap = cv2.VideoCapture(str(path))
    n = 0
    while cap.read()[0]:
        n += 1
    cap.release()
    return n


@pytest.mark.skipif(find_ffmpeg() is None, reason="ffmpeg not installed")
def test_writer_produces_playable_mp4(tmp_path: Path) -> None:
    out = tmp_path / "out.mp4"
    with VideoWriter(out, fps=25, size=(64, 48)) as writer:
        assert writer.backend == "ffmpeg"
        for img in _frames(12):
            writer.write(img)
    assert _count(out) == 12


def test_nvenc_produces_playable_video_when_available(tmp_path: Path) -> None:
    exe = find_ffmpeg()
    if exe is None or not nvenc_available(exe, (320, 240)):
        pytest.skip("NVENC is not available on this machine")
    out = tmp_path / "nvenc.mp4"
    with VideoWriter(out, fps=25, size=(320, 240), codec="h264_nvenc") as writer:
        assert writer.codec == "h264_nvenc"
        for frame in _frames(12, (320, 240)):
            writer.write(frame)
    assert _count(out) == 12


def test_writer_opencv_fallback(tmp_path: Path) -> None:
    out = tmp_path / "out.mp4"
    with VideoWriter(out, fps=25, size=(64, 48), use_ffmpeg=False) as writer:
        assert writer.backend == "opencv"
        for img in _frames(8):
            writer.write(img)
    assert _count(out) == 8


def test_nvenc_uses_its_own_quality_options(tmp_path: Path) -> None:
    nvenc = ffmpeg_command(
        tmp_path / "out.mp4", fps=25, size=(64, 48), crf=23, codec="h264_nvenc", exe="ffmpeg"
    )
    cpu = ffmpeg_command(
        tmp_path / "out.mp4", fps=25, size=(64, 48), crf=23, codec="libx264", exe="ffmpeg"
    )
    assert "-cq" in nvenc and "-crf" not in nvenc
    assert "-crf" in cpu and "-cq" not in cpu


def test_unavailable_nvenc_selects_cpu_before_writing(tmp_path: Path, monkeypatch) -> None:
    import sys

    from shuttlesense.render import writer as writer_module

    commands = []
    monkeypatch.setattr(writer_module.shutil, "which", lambda _: sys.executable)
    monkeypatch.setattr(writer_module, "nvenc_available", lambda *_: False)

    def command(*args, **kwargs):
        commands.append(kwargs["codec"])
        return [sys.executable, "-c", "import sys; sys.stdin.buffer.read(); sys.exit(1)"]

    monkeypatch.setattr(writer_module, "ffmpeg_command", command)
    with (
        pytest.raises(RuntimeError, match="ffmpeg failed"),
        VideoWriter(tmp_path / "out.mp4", fps=25, size=(64, 48), codec="h264_nvenc"),
    ):
        pass
    assert commands == ["libx264"]
    assert not (tmp_path / "out.mp4").exists()


def test_writer_reports_ffmpeg_error_instead_of_broken_pipe(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import sys

    from shuttlesense.render import writer as writer_module

    # Stands in for an ffmpeg that rejects the input and exits before reading any frame.
    fail = "import sys; sys.stderr.write('width not divisible by 2'); sys.exit(1)"
    monkeypatch.setattr(writer_module.shutil, "which", lambda _name: sys.executable)
    monkeypatch.setattr(
        writer_module, "ffmpeg_command", lambda *a, **k: [sys.executable, "-c", fail]
    )
    out = tmp_path / "out.mp4"
    writer = VideoWriter(out, fps=25, size=(640, 480))
    with pytest.raises(RuntimeError, match="width not divisible by 2"), writer:
        for img in _frames(200, size=(640, 480)):  # far more than the pipe buffer holds
            writer.write(img)
    assert writer._proc is not None and writer._proc.returncode == 1
    assert not out.exists()
    assert list(tmp_path.iterdir()) == []


def test_writer_reports_encoder_failure_after_first_frame(tmp_path: Path, monkeypatch) -> None:
    import sys

    from shuttlesense.render import writer as writer_module

    fail_after_frame = (
        "import sys; sys.stdin.buffer.read(64 * 48 * 3); "
        "sys.stderr.write('encoder failed after input'); sys.exit(7)"
    )
    monkeypatch.setattr(writer_module, "find_ffmpeg", lambda: sys.executable)
    monkeypatch.setattr(
        writer_module, "ffmpeg_command", lambda *a, **k: [sys.executable, "-c", fail_after_frame]
    )
    out = tmp_path / "out.mp4"
    with (
        pytest.raises(RuntimeError, match="encoder failed after input"),
        VideoWriter(out, fps=25, size=(64, 48)) as writer,
    ):
        writer.write(next(_frames(1)))
    assert writer.frames == 1
    assert writer._proc is not None and writer._proc.returncode == 7
    assert not out.exists()


def _record_with_track():
    from shuttlesense.schema import ClipRecord, Frame, Shuttle

    frames = [Frame(frame=i, shuttle=Shuttle()) for i in range(10)]
    frames[3].shuttle = Shuttle(x=20, y=20, visible=1)
    frames[5].shuttle = Shuttle(x=100, y=60, visible=1)
    return ClipRecord(clip_id="c", fps=25, width=160, height=90, num_frames=10, frames=frames)


def test_trail_draws_only_visible_points() -> None:
    from shuttlesense.render.overlays import RenderState, draw_trail

    record = _record_with_track()
    img = np.zeros((90, 160, 3), dtype=np.uint8)
    draw_trail(img, record, 6, RenderState(scale=1.0))
    assert img[20, 20].any() and img[60, 100].any()
    assert img[45, 60].sum() == 0  # nothing between the points
    assert img.any(axis=2).sum() < 400  # two small dots only


def test_optimized_trail_matches_full_frame_blending_at_edges() -> None:
    import cv2

    from shuttlesense.render import style
    from shuttlesense.render.overlays import RenderState, draw_trail
    from shuttlesense.schema import ClipRecord, Frame, Shuttle

    positions = [(0, 0), (159, 89), (80, 45), (-2, 30)]
    frames = [
        Frame(frame=i, shuttle=Shuttle(x=x, y=y, visible=1)) for i, (x, y) in enumerate(positions)
    ]
    record = ClipRecord(
        clip_id="c", fps=25, width=160, height=90, num_frames=len(frames), frames=frames
    )
    rng = np.random.default_rng(7)
    image = rng.integers(0, 256, (90, 160, 3), dtype=np.uint8)
    expected = image.copy()
    for frame in frames:
        age = (3 - frame.frame) / 12
        radius = max(1, round(6 - 4 * age))
        overlay = expected.copy()
        cv2.circle(
            overlay,
            (int(frame.shuttle.x), int(frame.shuttle.y)),
            radius,
            style.SHUTTLE,
            -1,
            cv2.LINE_AA,
        )
        cv2.addWeighted(overlay, 1 - 0.8 * age, expected, 0.8 * age, 0, dst=expected)
    draw_trail(image, record, 3, RenderState())
    assert np.array_equal(image, expected)


def test_speed_overlay_uses_the_same_running_peak_when_seeking() -> None:
    from shuttlesense.render import overlays, style

    record = _record_with_track()
    for frame, speed in zip(record.frames, [None, 0, 30, 20, 50, 0, None, 45, 60, 10], strict=True):
        frame.shuttle_speed_kmh = speed
    state = overlays.RenderState()
    for i in (8, 2, 9, 0, 4):
        expected = np.zeros((90, 160, 3), np.uint8)
        actual = expected.copy()
        overlays._label(expected, overlays.status_text(record, i), (12, 76), style.PANEL, 1)
        overlays.draw_speed(actual, record, i, state)
        assert np.array_equal(actual, expected)


def test_layers_respect_overlay_selection() -> None:
    from shuttlesense.render.overlays import RenderState, draw_frame
    from shuttlesense.schema import Player

    record = _record_with_track()
    record.frames[5].players.near = Player(bbox=(50, 10, 40, 70), score=0.9)
    state = RenderState()
    only_boxes = draw_frame(np.zeros((90, 160, 3), np.uint8), record, 5, ["boxes"], state)
    assert not only_boxes[60, 100].any() and only_boxes[40, 50].any()
    only_trail = draw_frame(np.zeros((90, 160, 3), np.uint8), record, 5, ["trail"], state)
    assert only_trail[60, 100].any() and not only_trail[40, 50].any()
    nothing = draw_frame(np.zeros((90, 160, 3), np.uint8), record, 5, ["minimap?"], state)
    assert not nothing.any()


def test_render_stage_writes_annotated_mp4(tiny_video: Path, tmp_path: Path) -> None:
    from shuttlesense.fake import fake_pipeline

    record = fake_pipeline(tiny_video, tmp_path, clip_id="c", overlays=["trail", "pose", "boxes"])
    assert record.num_frames == 10
    assert _count(tmp_path / "annotated.mp4") == 10


def test_hit_marker_visible_only_within_duration() -> None:
    from shuttlesense.render.overlays import RenderState, draw_hits, draw_strokes
    from shuttlesense.schema import Hit, Player

    record = _record_with_track()
    kps = [(0.0, 0.0, 0.0)] * 17
    kps[9] = (80.0, 40.0, 0.9)
    for f in record.frames:
        f.players.near = Player(bbox=(60, 30, 40, 50), keypoints=kps, score=0.9)
    record.hits = [Hit(id=0, frame=2, time_s=0.08, player="near", stroke="smash", confidence=0.81)]
    state = RenderState(config={"stages": {"hits": {"marker_duration_s": 0.2}}})  # 5 frames
    blank = np.zeros((90, 160, 3), np.uint8)
    for frame, expected in ((1, False), (2, True), (7, True), (8, False)):
        img = blank.copy()
        draw_hits(img, record, frame, state)
        assert img.any() == expected, frame
    img = blank.copy()
    draw_strokes(img, record, 9, state)  # label stays until the next hit
    assert img.any()


def test_court_lines_hit_corners() -> None:
    from shuttlesense.court import compute_homography
    from shuttlesense.render.overlays import RenderState, court_segments_px
    from shuttlesense.schema import ClipRecord, Court

    corners = [[20.0, 80.0], [140.0, 80.0], [120.0, 20.0], [40.0, 20.0]]
    h = compute_homography(corners)
    record = ClipRecord(clip_id="c", fps=25, width=160, height=90, num_frames=1,
                        court=Court(corners_px=corners, homography=h.tolist()))  # fmt: skip
    outline = court_segments_px(record, RenderState())[:4]
    assert [list(a) for a, _b in outline] == corners


def test_status_text() -> None:
    from shuttlesense.fake import load_golden
    from shuttlesense.render.overlays import status_text

    text = status_text(load_golden(), 50)
    assert text.startswith("In play") and "km/h (est.)" in text and text.endswith("3 strokes")


def test_minimap_layer_draws_in_corner() -> None:
    from shuttlesense.analytics.stage import run as analytics_run
    from shuttlesense.fake import load_golden
    from shuttlesense.render.overlays import RenderState, draw_minimap, minimap_rect
    from shuttlesense.stage import StageContext

    record = analytics_run(load_golden(), StageContext(video_path=None, out_dir=None))
    img = np.zeros((720, 1280, 3), np.uint8)
    draw_minimap(img, record, 10, RenderState())
    x, y, w, h = minimap_rect(img.shape, record.court.court_size_m, "top-right")
    assert h == 144 and x + w < 1280 and y < 50
    inside = img[y : y + h, x : x + w]
    assert inside.any()
    outside = img.copy()
    outside[y : y + h, x : x + w] = 0
    assert not outside.any()


def test_score_layer_updates_after_rally() -> None:
    from shuttlesense.render.overlays import RenderState, draw_score, score_at
    from shuttlesense.schema import ClipRecord, Frame, Rally, Score, ScorePair

    record = ClipRecord(
        clip_id="c", fps=10, width=160, height=90, num_frames=40,
        frames=[Frame(frame=i) for i in range(40)],
        rallies=[
            Rally(index=0, start_frame=0, end_frame=10, winner="far",
                  score_after=ScorePair(near=5, far=7)),
            Rally(index=1, start_frame=20, end_frame=30, winner="near",
                  score_after=ScorePair(near=6, far=7)),
        ],
        score=Score(near=6, far=7),
    )  # fmt: skip
    assert score_at(record, 5) == (5, 6)  # before the first rally ends: starting score
    assert score_at(record, 15) == (5, 7)
    assert score_at(record, 35) == (6, 7)
    img = np.zeros((90, 160, 3), np.uint8)
    draw_score(img, record, 15, RenderState())
    assert img.any()
    # Every rally after the game was won (score_after None): the final score stays up.
    for r in record.rallies:
        r.score_after = None
    assert score_at(record, 35) == (6, 7)
    record.score = None
    blank = np.zeros((90, 160, 3), np.uint8)
    draw_score(blank, record, 15, RenderState())
    assert not blank.any()


def test_score_layer_counts_awards_from_their_frame() -> None:
    from datetime import UTC, datetime

    from shuttlesense.render.overlays import score_at
    from shuttlesense.schema import ClipRecord, Frame, Rally, Score, ScoreCorrection, ScorePair

    def award(index: int, winner: str, frame: int) -> ScoreCorrection:
        return ScoreCorrection(rally_index=index, winner_before=None, winner_after=winner,
                               at=datetime.now(UTC), kind="award", frame=frame)  # fmt: skip

    record = ClipRecord(
        clip_id="c", fps=10, width=160, height=90, num_frames=80,
        frames=[Frame(frame=i) for i in range(80)],
        rallies=[Rally(index=0, start_frame=40, end_frame=50, winner="near",
                       score_after=ScorePair(near=1, far=1))],
        score=Score(near=2, far=1, corrections=[award(0, "far", 30), award(1, "near", 70)]),
    )  # fmt: skip
    assert score_at(record, 10) == (0, 0)
    assert score_at(record, 35) == (0, 1)
    assert score_at(record, 55) == (1, 1)
    assert score_at(record, 75) == (2, 1)


def test_doubles_court_lines_and_partner_colours() -> None:
    from shuttlesense.court import court_lines
    from shuttlesense.fake import load_golden
    from shuttlesense.render import style
    from shuttlesense.render.overlays import _player_labels, court_type_of

    singles = court_lines()
    doubles = court_lines(court="doubles")
    assert set(singles) < set(doubles)
    assert min(p[0] for seg in doubles["doubles_sides"] for p in seg) == -0.46
    assert len(style.PLAYER_COLORS) == 4 and style.PLAYER_COLORS["near_2"] != style.NEAR
    record = load_golden("doubles")
    assert court_type_of(record) == "doubles" and court_type_of(load_golden()) == "singles"
    assert [label for _, label in _player_labels(record)] == ["Near 1", "Near 2", "Far 1", "Far 2"]


def test_doubles_render_draws_every_layer(tmp_path) -> None:
    from shuttlesense.fake import load_golden
    from shuttlesense.render.overlays import RenderState, draw_boxes, draw_minimap, draw_pose

    record = load_golden("doubles")
    img = np.zeros((record.height, record.width, 3), np.uint8)
    state = RenderState()
    for layer in (draw_boxes, draw_pose, draw_minimap):
        layer(img, record, 10, state)
    assert img.any()


@pytest.mark.parametrize(
    "corners",
    [
        [[20, 80], [140, 80], [120, 20], [40, 20]],
        [[-40, 100], [190, 100], [140, -10], [20, -10]],
        [[-80, 60], [-10, 60], [-20, 20], [-70, 20]],
    ],
)
def test_court_region_matches_full_frame_blend(corners):
    import cv2

    from shuttlesense.court import compute_homography
    from shuttlesense.render import style
    from shuttlesense.render.overlays import RenderState, court_segments_px, draw_court
    from shuttlesense.schema import ClipRecord, Court

    record = ClipRecord(
        clip_id="c",
        fps=25,
        width=160,
        height=90,
        num_frames=1,
        court=Court(corners_px=corners, homography=compute_homography(corners).tolist()),
    )
    state = RenderState(scale=1)
    img = np.random.default_rng(7).integers(0, 256, (90, 160, 3), dtype=np.uint8)
    expected = img.copy()
    overlay = expected.copy()
    for a, b in court_segments_px(record, state):
        cv2.line(overlay, a, b, style.COURT, 3, cv2.LINE_AA)
    cv2.addWeighted(overlay, 0.6, expected, 0.4, 0, dst=expected)
    draw_court(img, record, 0, state)
    assert np.array_equal(img, expected)


def test_cached_hit_and_stroke_counts_match_original_at_random_frames():
    from shuttlesense.fake import load_golden
    from shuttlesense.render.overlays import (
        RenderState,
        _cached_last_hit,
        _last_hit_before,
        draw_speed,
        status_text,
    )

    record = load_golden("doubles")
    state = RenderState()
    for index in [0, len(record.frames) - 1, 10, 25, 3, 50]:
        if index >= len(record.frames):
            continue
        assert _cached_last_hit(record, index, state) == _last_hit_before(record, index)
        draw_speed(np.zeros((record.height, record.width, 3), np.uint8), record, index, state)
        assert status_text(record, index) == status_text(
            record,
            index,
            peak_history=state.cache["peak_history"],
            stroke_counts=state.cache["stroke_counts"],
        )


def test_cached_score_overlay_matches_score_at_every_frame(monkeypatch):
    from shuttlesense.fake import load_golden
    from shuttlesense.render import overlays

    record = load_golden("doubles")
    state = overlays.RenderState()
    # Exercise arbitrary seek order and compare the labels to the uncached score function.
    labels = []
    monkeypatch.setattr(overlays, "_label", lambda img, text, *args: labels.append(text))
    for i in reversed(range(len(record.frames))):
        labels.clear()
        overlays.draw_score(np.zeros((record.height, record.width, 3), np.uint8), record, i, state)
        score = overlays.score_at(record, i)
        if score is None:
            assert not labels
        else:
            assert labels == [f"Near {score[0]}", f"Far {score[1]}"]
