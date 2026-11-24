"""Recorded practice that follows one selected person in image space."""

from __future__ import annotations

import base64
import json
import logging
import time
from collections.abc import Callable
from functools import lru_cache
from pathlib import Path
from typing import Literal

import cv2
import numpy as np

from shuttlesense.atomic import atomic_write_text
from shuttlesense.pose.estimator import load_detector
from shuttlesense.pose.player_tracker import unique_player_poses
from shuttlesense.practice.evidence import ARM_JOINTS, arm_observations, pose_point
from shuttlesense.practice.pipeline import GeneralPracticeSetup
from shuttlesense.practice.selected_tracker import SelectedIdentityTracker
from shuttlesense.schema import ClipRecord, Frame, Players
from shuttlesense.stream.perception import configure_watch_pose
from shuttlesense.stream.watch_video import open_watch_video, render_watch_video

log = logging.getLogger(__name__)
MomentKind = Literal["marked", "movement", "snapshot"]


@lru_cache(maxsize=4)
def _configured_detector(detector, device, options):
    watch = dict(options)
    configured, raw, _ = configure_watch_pose(
        detector, watch, device, max(1, min(16, int(watch.get("pose_batch_size", 1))))
    )
    return configured, raw


def practice_pose_detector(config, device, *, tracker=None, frame_size=None):
    pose = config.get("stages", {}).get("pose", {})
    watch = config.get("watch") or {}
    detector = load_detector(pose.get("backend", "rtmlib"), pose.get("mode", "balanced"), device)
    detector, raw = _configured_detector(
        detector,
        device,
        tuple(
            (key, watch[key])
            for key in (
                "player_provider",
                "pose_opt_batch",
                "pose_batch_size",
                "pose_crop_lookup",
                "split_detector",
            )
            if key in watch
        ),
    )
    watch_factory = getattr(raw, "with_watch", None)
    mode = watch.get("candidate_filter", "off")
    if (
        tracker is not None
        and frame_size is not None
        and watch_factory
        and mode in ("filter", "shadow")
    ):
        from shuttlesense.pose.watch_candidates import SelectedWatchCandidates

        detector = watch_factory(
            max(1, min(16, int(watch.get("pose_batch_size", 1)))),
            SelectedWatchCandidates(
                tracker,
                frame_size,
                mode,
                watch.get("candidate_refresh_frames", 5),
            ),
            bool(watch.get("pose_crop_lookup", False)),
        )

    def detect(frame):
        candidates = [
            p
            for p in detector(frame)
            if np.isfinite((*p.bbox, p.score)).all()
            and min(p.bbox[2:]) > 0
            and p.score >= pose.get("min_person_score", 0.4)
        ]
        return unique_player_poses(
            sorted(candidates, key=lambda p: p.score, reverse=True),
            lambda p: p,
            iou_min=float(pose.get("duplicate_iou", 0.65)),
            pose_max=float(pose.get("duplicate_pose_fraction", 0.1)),
        )

    return detect


def retained_frame(reader, source_frame):
    return min((source_frame + reader.step // 2) // reader.step, len(reader) - 1)


def review_moments(record: ClipRecord, review_seconds: list[float]) -> list[dict]:
    fps = record.fps
    lag = max(1, round(0.2 * fps))
    spacing = max(1, round(0.75 * fps))
    marked = {round(t * fps) for t in review_seconds if round(t * fps) < len(record.frames)}
    scores = np.zeros(len(record.frames))
    best_snapshot: tuple[int, int] | None = None
    reliable_from = dict.fromkeys(ARM_JOINTS, 0)
    for i, frame in enumerate(record.frames):
        player = frame.players.near
        if player is None:
            reliable_from = dict.fromkeys(ARM_JOINTS, i + 1)
            continue
        count = 0
        for arm, (shoulder_id, _, wrist_id) in ARM_JOINTS.items():
            shoulder, wrist = pose_point(player, shoulder_id), pose_point(player, wrist_id)
            if shoulder is None or wrist is None:
                reliable_from[arm] = i + 1
            elif i - lag >= reliable_from[arm]:
                earlier = record.frames[i - lag].players.near
                earlier_shoulder = pose_point(earlier, shoulder_id)
                earlier_wrist = pose_point(earlier, wrist_id)
                if (
                    earlier is not None
                    and earlier_shoulder is not None
                    and earlier_wrist is not None
                ):
                    delta = (wrist - shoulder) / player.bbox[3] - (
                        earlier_wrist - earlier_shoulder
                    ) / earlier.bbox[3]
                    scores[i] = max(scores[i], float(np.linalg.norm(delta)))
            if best_snapshot is None or best_snapshot[0] < 4:
                count += sum(o.status == "observed" for o in arm_observations(player, arm, i / fps))
        if count and (best_snapshot is None or count > best_snapshot[0]):
            best_snapshot = (count, i)

    scores_padded = np.pad(scores, (1, 1))
    peaks = [
        i
        for i, score in enumerate(scores)
        if score >= 0.12 and score > scores_padded[i] and score >= scores_padded[i + 2]
    ]
    peaks = [
        i
        for i in peaks
        if any(
            obs.status == "observed"
            for arm in ARM_JOINTS
            for obs in arm_observations(record.frames[i].players.near, arm, i / fps)
        )
    ]
    picks: dict[int, MomentKind] = dict.fromkeys(marked, "marked")
    automatic = 0
    for i in sorted(peaks, key=lambda j: (-scores[j], j)):
        if all(abs(i - other) >= spacing for other in picks):
            picks[i] = "movement"
            automatic += 1
            if automatic == 8:
                break
    if not peaks and best_snapshot is not None:
        picks.setdefault(best_snapshot[1], "snapshot")

    moments = []
    for i, kind in sorted(picks.items()):
        time_s = i / fps
        observations = []
        for arm in ARM_JOINTS:
            for obs in arm_observations(record.frames[i].players.near, arm, time_s):
                observations.append(
                    {
                        **obs.model_dump(),
                        "id": f"pose-{i}-{arm}-{obs.rule}",
                        "arm": arm,
                        "description": f"{arm.capitalize()} arm. {obs.description}",
                        "provenance": "user_marked" if kind == "marked" else "automatic",
                    }
                )
        moments.append(
            {
                "frame": i,
                "time_s": time_s,
                "kind": kind,
                "observations": observations,
            }
        )
    return moments


def run_general_practice(
    source: Path,
    out_dir: Path,
    setup: GeneralPracticeSetup,
    config: dict,
    device: str,
    progress: Callable[[float], None],
    check_cancelled: Callable[[], None],
    preview: Callable[[int, str], None] | None,
    control: Callable[[], bool],
    *,
    show_occlusion_hold: bool = True,
) -> None:
    from shuttlesense.practice.runner import SelectionNeeded
    from shuttlesense.render.overlays import RenderState, draw_frame
    from shuttlesense.render.style import scale_for

    reader = open_watch_video(source, config)
    setup.validate_segment(reader.source.fps, reader.source.num_frames)
    selection = retained_frame(reader, setup.selection_frame)
    sx, sy = reader.width / reader.source.width, reader.height / reader.source.height
    x, y, w, h = setup.selected_bbox
    pose = config.get("stages", {}).get("pose", {})
    stages = config.get("stages", {})
    held_boxes = {}
    render_config = {
        **config,
        "stages": {
            **stages,
            "render": {
                **stages.get("render", {}),
                "selected_player": True,
                "practice_occlusion_boxes": held_boxes,
            },
        },
    }
    tracker = SelectedIdentityTracker(
        (x * sx, y * sy, w * sx, h * sy),
        max_gap=int(pose.get("max_reacquire_gap_frames", 90)),
        image_cfg=pose,
    )
    setup_started = time.perf_counter()
    detector = practice_pose_detector(
        config, device, tracker=tracker, frame_size=(reader.width, reader.height)
    )
    setup_s = time.perf_counter() - setup_started
    record = ClipRecord(
        clip_id="practice",
        mode="practice",
        fps=reader.fps,
        width=reader.width,
        height=reader.height,
        num_frames=len(reader),
    )
    unobserved = []
    lost_from = None
    preview_state = RenderState(config=render_config, scale=scale_for(reader.height))
    overlays = ("pose", "boxes")
    # The prefix only needs empty timeline records. Decode it once during export.
    record.frames.extend(Frame(frame=i, player_hold_safe=False) for i in range(selection))
    last_update = 0.0
    started = time.perf_counter()
    last_confirmed_frame = None
    previous_display = None
    for i, frame in reader.frames(selection, len(reader)):
        check_cancelled()
        if control() and i > selection:
            break
        player = None
        if i == selection:
            player = tracker.lock_selection(detector(frame), frame)
            if player is None:
                raise SelectionNeeded(selection * reader.step)
        elif lost_from is None:
            player = tracker.update(detector(frame), frame)
            if tracker.missing > tracker.max_gap:
                lost_from = i - tracker.missing + 1
        if player is None:
            unobserved.append(i)
            if (
                show_occlusion_hold
                and last_confirmed_frame is not None
                and (i - last_confirmed_frame) / reader.fps <= 0.25
            ):
                held_boxes[i] = tracker.bbox
        else:
            last_confirmed_frame = i
        record.frames.append(
            Frame(frame=i, players=Players(near=player), player_hold_safe=player is not None)
        )
        display = (
            "confirmed"
            if player is not None
            else "hold"
            if i in held_boxes
            else "lost"
            if lost_from is not None
            else "search"
        )
        if preview is not None and (display != previous_display or i % 6 == 0):
            image = draw_frame(frame.copy(), record, i, overlays, preview_state)
            if display == "search" and show_occlusion_hold:
                cv2.putText(
                    image,
                    "Looking for selected player",
                    (12, max(24, round(30 * preview_state.scale))),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.7 * preview_state.scale,
                    (255, 255, 255),
                    2,
                    cv2.LINE_AA,
                )
            if reader.width > 960:
                image = cv2.resize(image, (960, max(1, round(reader.height * 960 / reader.width))))
            ok, jpeg = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 75])
            if ok:
                # Practice preview timestamps use the original video metadata.
                preview(i * reader.step, base64.b64encode(jpeg).decode("ascii"))
        previous_display = display
        now = time.monotonic()
        if now - last_update >= 0.5:
            progress(0.9 * (i + 1) / len(reader))
            last_update = now
        if lost_from is not None:
            if not control():
                # Preserve the rest as a gap and only decode it during export.
                remainder = range(i + 1, len(reader))
                unobserved.extend(remainder)
                record.frames.extend(Frame(frame=j, player_hold_safe=False) for j in remainder)
            break

    if len(record.frames) == selection:
        raise SelectionNeeded(selection * reader.step)
    record.num_frames = len(record.frames)
    moments = review_moments(record, setup.review_seconds)
    analysis_s = time.perf_counter() - started
    progress(0.9)
    last_update = 0.0

    def render_progress(value: float):
        nonlocal last_update
        check_cancelled()
        now = time.monotonic()
        if now - last_update >= 0.5 or value >= 1:
            progress(0.9 + 0.099 * value)
            last_update = now

    started = time.perf_counter()
    render_watch_video(
        record,
        reader,
        out_dir / "annotated.mp4",
        overlays=overlays,
        config=render_config,
        progress=render_progress,
    )
    log.info(
        "General Practice %s: %dx%d %.3f fps, %d frames, analysis %.3fs, render %.3fs, setup %.3fs",
        out_dir.name,
        reader.width,
        reader.height,
        reader.fps,
        record.num_frames,
        analysis_s,
        time.perf_counter() - started,
        setup_s,
    )
    atomic_write_text(out_dir / "practice_frames.json", record.model_dump_json())
    atomic_write_text(
        out_dir / "practice.json",
        json.dumps(
            {
                "analysis_kind": "general",
                "setup": setup.model_dump(),
                "fps": record.fps,
                "processed_frames": record.num_frames,
                "stopped_early": record.num_frames < len(reader),
                "selection_frame": selection,
                "unobserved_frames": len(unobserved),
                "unobserved_indices": unobserved,
                "tracking_lost_from_s": None if lost_from is None else lost_from / record.fps,
                "review_moments": moments,
            }
        ),
    )
