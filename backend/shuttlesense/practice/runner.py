"""Process a selected-player practice clip into a rendered video and evidence."""

from __future__ import annotations

import base64
import json
import logging
from collections.abc import Callable
from pathlib import Path

import cv2

from shuttlesense.atomic import atomic_write_text
from shuttlesense.io import FrameReader
from shuttlesense.pose.estimator import load_detector
from shuttlesense.practice.evidence import SelectedPlayerTracker, assess_attempt
from shuttlesense.practice.pipeline import PracticeAnalyzer, PracticeSetup
from shuttlesense.schema import ClipRecord, Frame, Players, Shuttle

log = logging.getLogger(__name__)


def build_shuttle_tracker(config: dict, device: str, size: tuple[int, int]):
    """Use the Watch TrackNet path; pose-only practice remains available if absent."""
    if not config.get("stages", {}).get("tracking", {}).get("enabled", True):
        return None
    try:
        from shuttlesense.stream.perception import ModelPerception

        tracker = ModelPerception(config, device, size, None)
        return tracker if tracker.available.get("tracking") else None
    except (ImportError, OSError, RuntimeError, ValueError):
        log.warning("Practice shuttle tracking unavailable", exc_info=True)
        return None


class SelectionNeeded(Exception):
    def __init__(self, frame: int):
        self.frame = frame
        super().__init__(f"Player selection needed at frame {frame}")


def run_practice(
    source: Path,
    out_dir: Path,
    setup: PracticeSetup,
    selections: dict[int, tuple[float, float, float, float]],
    gaps: list[tuple[int, int]],
    config: dict,
    device: str,
    progress: Callable[[float], None],
    check_cancelled: Callable[[], None],
    preview: Callable[[int, str], None] | None = None,
) -> None:
    reader = FrameReader(source, target_height=0, max_fps=0)
    analyzer = PracticeAnalyzer(setup, reader.fps, len(reader))
    pose = config.get("stages", {}).get("pose", {})
    detector = load_detector(pose.get("backend", "rtmlib"), pose.get("mode", "balanced"), device)
    tracker = build_shuttle_tracker(config, device, (reader.width, reader.height))
    record = ClipRecord(
        clip_id="practice",
        mode="practice",
        fps=reader.fps,
        width=reader.width,
        height=reader.height,
        num_frames=len(reader),
    )
    unobserved: set[int] = set()
    minimum = pose.get("min_person_score", 0.4)
    for index, frame in reader:
        check_cancelled()
        shuttle = Shuttle()
        if tracker is not None:
            try:
                shuttle = tracker._shuttle(frame)
            except (RuntimeError, ValueError, OSError):
                log.warning("Practice shuttle tracking failed", exc_info=True)
                tracker = None
        if index < setup.selection_frame:
            record.frames.append(Frame(frame=index, shuttle=shuttle))
            unobserved.add(index)
            continue
        people = [p for p in detector(frame) if p.score >= minimum]
        if index in selections:
            analyzer.tracker = SelectedPlayerTracker(selections[index])
        if analyzer.status == "needs_selection":
            # Reacquire only a unique overlapping detection near the last known box.
            # Otherwise retain the gap instead of assigning a different player.
            analyzer.tracker.lost = False
            analyzer.status = "running"
        player = analyzer.process(index, people)
        if player is None:
            analyzer.skip_untracked(index)
            record.frames.append(Frame(frame=index, shuttle=shuttle))
            unobserved.add(index)
        else:
            record.frames.append(Frame(frame=index, shuttle=shuttle, players=Players(near=player)))
        if preview is not None and index % 6 == 0:
            image = frame
            if frame.shape[1] > 960:
                scale = 960 / frame.shape[1]
                image = cv2.resize(frame, (960, max(1, round(frame.shape[0] * scale))))
            ok, jpeg = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 75])
            if ok:
                preview(index, base64.b64encode(jpeg).decode("ascii"))
        if index % 15 == 0:
            progress(0.75 * (index + 1) / len(reader))
    if analyzer.next_frame != len(reader):
        raise RuntimeError("Video ended before all practice frames were analyzed")
    from shuttlesense.practice.auto import analyze_strokes

    events = analyze_strokes(record, config, device, unobserved)
    for i, event in enumerate(events):
        event["id"] = f"auto-{i}"
        if event["stroke"] in ("clear", "smash", "drop") and not any(
            abs(item.moment_s - event["time_s"]) <= 0.1 for item in analyzer.observations
        ):
            analyzer.observations.append(
                assess_attempt(
                    record.frames[event["frame"]].players.near,
                    event["stroke"],
                    setup.arm,
                    event["time_s"],
                    provenance="automatic",
                )
            )
    from shuttlesense import feedback
    from shuttlesense.render import render_video
    from shuttlesense.stage import StageContext

    feedback.run(
        record, StageContext(video_path=source, out_dir=out_dir, config=config, device=device)
    )
    analysis_notes = [
        {
            "time_s": hit.time_s,
            "stroke": hit.stroke,
            "rule": item.rule,
            "passed": item.passed,
            "tip": item.tip,
            "value": item.value,
        }
        for hit in record.hits
        for item in hit.feedback
    ]

    def render_progress(value: float) -> None:
        check_cancelled()
        progress(0.75 + 0.25 * value)

    render_video(
        record,
        FrameReader(source, target_height=0, max_fps=0),
        out_dir / "annotated.mp4",
        overlays=("trail", "pose", "boxes", "hits", "strokes", "speed"),
        config=config,
        progress=render_progress,
    )
    manual_events = [
        {
            "id": f"manual-{i}",
            "frame": round(item.moment_s * reader.fps),
            "time_s": item.moment_s,
            "stroke": item.stroke,
            "confidence": None,
            "source": "manual",
            "confirmed": True,
            "model": None,
        }
        for i, item in enumerate(analyzer.observations)
        if item.observations and item.observations[0].provenance == "user_marked"
    ]
    atomic_write_text(out_dir / "practice_frames.json", record.model_dump_json())
    atomic_write_text(
        out_dir / "practice.json",
        json.dumps(
            {
                "setup": setup.model_dump(),
                "fps": reader.fps,
                "observations": [a.model_dump() for a in analyzer.observations],
                "automatic_events": events,
                "analysis_notes": analysis_notes,
                "unobserved_frames": len(unobserved),
                "events": sorted([*events, *manual_events], key=lambda event: event["time_s"]),
                "shuttle_tracking_available": tracker is not None,
            }
        ),
    )
