"""Fake pipeline: the golden record scaled to the uploaded clip (task T1.10).

Lets the app and demos show non-empty results without a GPU or weights. Enabled with
`python -m shuttlesense.run --fake` or `SHUTTLESENSE_FAKE_PIPELINE=1` for the API.
"""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path
from typing import Any

from shuttlesense.analytics import keep_chat, write_exports
from shuttlesense.io import FrameReader
from shuttlesense.pipeline import STAGE_NAMES, StageEvent
from shuttlesense.schema import ClipRecord, Court, ScorePair, load_record

GOLDEN_RECORD = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "golden_record.json"
GOLDEN_DOUBLES = GOLDEN_RECORD.with_name("golden_record_doubles.json")


def load_golden(court: str = "singles") -> ClipRecord:
    """The golden record, or its doubles version (four players, hitters, service order)."""
    path = GOLDEN_DOUBLES if court == "doubles" else GOLDEN_RECORD
    return load_record(path.read_text(encoding="utf-8"))


def _scale_xy(x: float | None, y: float | None, sx: float, sy: float):
    return (None if x is None else round(x * sx, 1)), (None if y is None else round(y * sy, 1))


def scale_record(
    golden: ClipRecord, *, fps: float, width: int, height: int, num_frames: int
) -> ClipRecord:
    """Stretch the golden record over `num_frames` frames and a `width` x `height` image."""
    sx, sy = width / golden.width, height / golden.height
    n_src = len(golden.frames)
    num_frames = max(num_frames, 1)

    def src_index(i: int) -> int:
        return round(i * (n_src - 1) / max(num_frames - 1, 1))

    def dst_index(i: int) -> int:
        return round(i * (num_frames - 1) / max(n_src - 1, 1))

    frames = []
    for i in range(num_frames):
        f = golden.frames[src_index(i)].model_copy(deep=True)
        f.frame = i
        if f.shuttle and f.shuttle.visible:
            f.shuttle.x, f.shuttle.y = _scale_xy(f.shuttle.x, f.shuttle.y, sx, sy)
        for p in f.players.slots().values():
            if p is None:
                continue
            bx, by, bw, bh = p.bbox
            p.bbox = (bx * sx, by * sy, bw * sx, bh * sy)
            p.keypoints = [(x * sx, y * sy, s) for x, y, s in p.keypoints]
        frames.append(f)

    record = golden.model_copy(deep=True)
    record.fps, record.width, record.height = fps, width, height
    record.num_frames = num_frames
    record.frames = frames
    for hit in record.hits:
        hit.frame = dst_index(hit.frame)
        hit.time_s = round(hit.frame / fps, 3) if fps else 0.0
    for rally in record.rallies:
        rally.start_frame = dst_index(rally.start_frame)
        rally.end_frame = dst_index(rally.end_frame)
    for call in record.line_calls:
        call.frame = dst_index(call.frame)
        call.time_s = round(call.frame / fps, 3) if fps else 0.0
    if record.coaching is not None:
        for note in record.coaching.session_notes:
            for m in note.moments:
                m.frame = dst_index(m.frame)
                m.time_s = round(m.frame / fps, 3) if fps else 0.0
    from shuttlesense.referee import build_events

    record.rally_events = build_events(record)
    return record


def fake_pipeline(
    video_path: Path,
    out_dir: Path,
    *,
    clip_id: str,
    config: dict[str, Any] | None = None,
    court_corners_px: Sequence[Sequence[float]] | None = None,
    overlays: Sequence[str] = (),
    referee_enabled: bool = False,
    device: str = "cpu",
    on_event: StageEvent = lambda _name, _status, _progress: None,
) -> ClipRecord:
    """Drop-in replacement for run_pipeline that never touches a model."""
    # Same normalized size, fps and frame count as the real io stage (<= 720p, even sizes).
    io_cfg = (config or {}).get("stages", {}).get("io", {})
    reader = FrameReader(
        video_path,
        target_height=io_cfg.get("target_height", 720),
        max_fps=io_cfg.get("max_fps", 30),
    )
    from shuttlesense.config import court_type

    record = scale_record(
        load_golden(court_type(config or {})),
        fps=reader.fps,
        width=reader.width,
        height=reader.height,
        num_frames=len(reader),
    )
    record.clip_id = clip_id
    record.source_name = video_path.name
    if record.hits:  # the golden strokes stand in for the job's chosen model (D28)
        from shuttlesense.strokes import registry

        record.stroke_model = registry.algorithm(
            (config or {}).get("stages", {}).get("strokes", {})
        )
    record.mode = (config or {}).get("mode", "upload")
    if court_corners_px:
        from shuttlesense.court import compute_homography

        # Tapped on the source frame; the record uses normalized pixels (as court.run).
        sx = reader.width / reader.source.width
        sy = reader.height / reader.source.height
        corners = tuple((float(x) * sx, float(y) * sy) for x, y in court_corners_px)
        record.court = Court(corners_px=corners, homography=compute_homography(corners).tolist())
    else:
        record.court = None
    if not referee_enabled:
        record.rallies, record.score = [], None
        record.line_calls, record.rally_events = [], []
        for f in record.frames:
            f.rally_state = None
        for h in record.hits:
            h.rally_index = None
    elif record.score is not None:  # same start score and corrections as the real pipeline
        from shuttlesense.referee import apply_corrections, apply_user_changes, build_events
        from shuttlesense.referee.scoring import match_config

        start = ScorePair(**(config or {}).get("start_score", {}) or {})
        match = match_config(config or {})
        record.score.best_of, record.score.first_server = match["best_of"], match["first_server"]
        # The service slots come from the job only: the golden ones would not match the
        # user's first server (and play() refuses a server on the other side).
        record.score.first_server_id = match["first_server_id"]
        record.score.first_receiver_id = match["first_receiver_id"]
        record.score.game_service = match["game_service"]
        record.score.start_games = match["start_games"]
        record.score.auto_change_ends = match["auto_change_ends"]
        if not apply_user_changes(record, out_dir, start):
            apply_corrections(record, [], start)  # still re-score from the start score
            record.rally_events = build_events(record)

    for name in STAGE_NAMES:
        on_event(name, "running", 0.0)
        if name == "render":
            from shuttlesense.render import render_video

            render_video(
                record,
                reader,
                out_dir / "annotated.mp4",
                overlays=overlays,
                config=config,
                progress=lambda p: on_event("render", "running", p),
            )
        on_event(name, "done", 1.0)
    keep_chat(record, out_dir)
    write_exports(record, out_dir)
    return record
