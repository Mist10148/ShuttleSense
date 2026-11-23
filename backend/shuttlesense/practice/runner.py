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
from shuttlesense.render.style import MIN_KEYPOINT_SCORE, SKELETON_EDGES
from shuttlesense.render.writer import VideoWriter
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
    rendering = config.get("stages", {}).get("render", {})
    with VideoWriter(
        out_dir / "annotated.mp4",
        fps=reader.fps,
        size=(reader.width, reader.height),
        codec=rendering.get("codec", "libx264"),
        crf=rendering.get("crf", 23),
    ) as writer:
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
                writer.write(frame)
                continue
            if any(start <= index < end for start, end in gaps):
                analyzer.status = "needs_selection"
                analyzer.skip_untracked(index)
                record.frames.append(Frame(frame=index, shuttle=shuttle))
                unobserved.add(index)
                cv2.putText(
                    frame,
                    "Tracking unavailable",
                    (16, 36),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.7,
                    (255, 255, 255),
                    2,
                )
                writer.write(frame)
                continue
            if analyzer.status == "needs_selection":
                if index in selections:
                    analyzer.reselect(index, selections[index])
                else:
                    analyzer.skip_untracked(index)
                    record.frames.append(Frame(frame=index, shuttle=shuttle))
                    unobserved.add(index)
                    cv2.putText(
                        frame,
                        "Tracking unavailable",
                        (16, 36),
                        cv2.FONT_HERSHEY_SIMPLEX,
                        0.7,
                        (255, 255, 255),
                        2,
                    )
                    writer.write(frame)
                    continue
            people = [p for p in detector(frame) if p.score >= minimum]
            if index in selections:
                # Replay from the beginning after a pause; the explicit selection must
                # replace the previous tracker even when replay no longer loses it.
                analyzer.tracker = SelectedPlayerTracker(selections[index])
            player = analyzer.process(index, people)
            if player is None:
                if any(next_frame > index for next_frame in selections):
                    analyzer.skip_untracked(index)
                    record.frames.append(Frame(frame=index, shuttle=shuttle))
                    unobserved.add(index)
                    cv2.putText(
                        frame,
                        "Tracking unavailable",
                        (16, 36),
                        cv2.FONT_HERSHEY_SIMPLEX,
                        0.7,
                        (255, 255, 255),
                        2,
                    )
                    writer.write(frame)
                    continue
                raise SelectionNeeded(index)
            record.frames.append(Frame(frame=index, shuttle=shuttle, players=Players(near=player)))
            x, y, w, h = player.bbox
            cv2.rectangle(
                frame, (round(x), round(y)), (round(x + w), round(y + h)), (80, 220, 80), 2
            )
            points = player.keypoints
            for a, b in SKELETON_EDGES:
                if (
                    len(points) > max(a, b)
                    and points[a][2] >= MIN_KEYPOINT_SCORE
                    and points[b][2] >= MIN_KEYPOINT_SCORE
                ):
                    cv2.line(
                        frame,
                        tuple(round(v) for v in points[a][:2]),
                        tuple(round(v) for v in points[b][:2]),
                        (80, 220, 80),
                        2,
                    )
            if any(round(t * reader.fps) == index for t in setup.attempt_seconds):
                cv2.putText(
                    frame,
                    "Marked attempt",
                    (16, 36),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.7,
                    (255, 255, 255),
                    2,
                )
            if preview is not None and index % 6 == 0:
                image = frame
                if frame.shape[1] > 960:
                    scale = 960 / frame.shape[1]
                    image = cv2.resize(frame, (960, max(1, round(frame.shape[0] * scale))))
                ok, jpeg = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 75])
                if ok:
                    preview(index, base64.b64encode(jpeg).decode("ascii"))
            writer.write(frame)
            if index % 15 == 0:
                progress((index + 1) / len(reader))
        if analyzer.status != "done":
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
                "events": sorted([*events, *manual_events], key=lambda event: event["time_s"]),
                "shuttle_tracking_available": tracker is not None,
            }
        ),
    )
