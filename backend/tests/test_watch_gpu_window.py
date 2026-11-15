from collections import deque

import numpy as np
import pytest

from shuttlesense.tracking.tracknet import INPUT_SIZE, _track_input_rgb
from shuttlesense.tracking.watch_gpu_window import WatchGpuWindow


@pytest.mark.parametrize("device", ["cpu", "cuda"])
def test_rolling_window_matches_original_input_exactly(device):
    torch = pytest.importorskip("torch")
    if device == "cuda" and not torch.cuda.is_available():
        pytest.skip("CUDA unavailable")
    rng = np.random.default_rng(11)
    window = deque(maxlen=8)
    rolling = WatchGpuWindow(8, device)
    background = None
    for index in range(12):
        frame = rng.integers(0, 256, (INPUT_SIZE[1], INPUT_SIZE[0], 3), dtype=np.uint8)
        if index < 4:
            background = rng.integers(0, 256, frame.shape, dtype=np.uint8)
        window.append(frame)
        padded = [window[0]] * (8 - len(window)) + list(window)
        expected = _track_input_rgb(padded, "concat", background)[None]
        actual = rolling.push(frame, background).cpu().numpy()
        assert np.array_equal(actual, expected)
