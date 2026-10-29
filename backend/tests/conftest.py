from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest


@pytest.fixture(scope="session")
def tiny_video(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """A 10-frame 160x90 MP4 generated on the fly (no binary fixtures in the repo)."""
    import cv2

    path = tmp_path_factory.mktemp("video") / "tiny.mp4"
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), 25.0, (160, 90))
    for i in range(10):
        frame = np.full((90, 160, 3), 40, dtype=np.uint8)
        cv2.circle(frame, (10 + i * 14, 45), 4, (255, 255, 255), -1)
        writer.write(frame)
    writer.release()
    return path
