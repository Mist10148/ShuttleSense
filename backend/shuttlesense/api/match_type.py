"""Conservative, user-confirmed match-format suggestions for recorded video."""

from __future__ import annotations

import numpy as np

from shuttlesense.court import compute_homography, image_to_court
from shuttlesense.court.lines import DOUBLES_SIDE_ALLEY_M
from shuttlesense.io import FrameReader
from shuttlesense.pose.tracking import foot_point
from shuttlesense.schema import COURT_SIZE_M


def suggest_counts(counts: list[tuple[int, int]]) -> dict:
    doubles = sum(near >= 2 and far >= 2 for near, far in counts)
    singles = sum(near == 1 and far == 1 for near, far in counts)
    # Even a single four-player observation is conflicting evidence for singles.
    result = "doubles" if doubles >= 3 else "singles" if singles >= 8 and doubles == 0 else None
    detail = (
        "Suggestion based on detected players; spectators and occlusion can affect it."
        if result
        else "Not enough consistent player observations. Choose the format manually."
    )
    return {"suggestion": result, "detail": detail, "sampled_frames": len(counts)}


def detect_match_type(source, corners, config, device) -> dict:
    from shuttlesense.pose.estimator import load_detector

    if device.startswith("cuda"):
        # Load CUDA and cuDNN DLLs before ONNX Runtime creates its sessions on Windows.
        import torch  # noqa: F401

    cfg = config.get("stages", {}).get("pose", {})
    if not cfg.get("enabled", True):
        raise RuntimeError("Pose detection is disabled on this server.")
    detector = load_detector(cfg.get("backend", "rtmlib"), cfg.get("mode", "balanced"), device)
    reader = FrameReader(source, target_height=720, max_fps=30)
    if reader.source.width <= 0 or reader.source.height <= 0:
        raise ValueError("Video dimensions are unavailable.")
    scaled = [
        [x * reader.width / reader.source.width, y * reader.height / reader.source.height]
        for x, y in corners
    ]
    homography = compute_homography(scaled)
    indices = sorted(
        set(int(i) for i in np.linspace(0, max(0, len(reader) - 1), min(12, len(reader))))
    )
    counts = []
    threshold = cfg.get("min_person_score", 0.4)
    width, length = COURT_SIZE_M
    for index in indices:
        frame = reader.read(index)
        if frame is None:
            continue
        points = [foot_point(p) for p in detector(frame) if p.score >= threshold]
        near = far = 0
        if points:
            for x, y in image_to_court(homography, np.asarray(points)):
                if -DOUBLES_SIDE_ALLEY_M <= x <= width + DOUBLES_SIDE_ALLEY_M and 0 <= y <= length:
                    if y < length / 2:
                        near += 1
                    else:
                        far += 1
        counts.append((near, far))
    return suggest_counts(counts)
