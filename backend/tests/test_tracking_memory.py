"""An uploaded TrackNet ensemble can continue after a failed batch allocation."""

import numpy as np
import pytest

from shuttlesense.tracking.ensemble import track_overlapping


def test_smaller_batches_resume_from_failed_window():
    torch = pytest.importorskip("torch")
    calls = []

    class Reader:
        width = height = 8

        def __len__(self):
            return 6

        def batch(self, start, size):
            return list(range(start, min(start + size, len(self))))

    def model(batch):
        calls.append(batch[:, 0].tolist())
        if len(batch) > 2:
            raise torch.OutOfMemoryError("batch too large")
        maps = torch.zeros((len(batch), 2, 8, 8))
        for b, frames in enumerate(batch):
            for i, frame in enumerate(frames):
                maps[b, i, 3, int(frame) + 1] = 1
        return maps

    xy, visible = track_overlapping(
        model,
        Reader(),
        seq_len=2,
        stride=1,
        batch_size=4,
        device="cpu",
        prepare=np.asarray,
        input_size=(8, 8),
    )
    assert calls == [[0, 1, 2, 3], [0, 1], [2, 3], [4, 5]]
    np.testing.assert_array_equal(visible, np.ones(6))
    np.testing.assert_allclose(xy[:, 0], np.arange(1, 7))
