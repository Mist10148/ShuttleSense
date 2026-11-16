"""Experimental exact TrackNet concat-window construction on CUDA."""
from __future__ import annotations

import numpy as np

from shuttlesense.tracking.tracknet import INPUT_SIZE


class WatchGpuWindow:
    """Keep normalized frames on GPU, preserving NumPy's float32 division results."""

    def __init__(self, seq_len, device):
        import torch

        self.torch, self.seq_len, self.device = torch, seq_len, device
        values = np.arange(256, dtype=np.uint8).astype(np.float32) / 255.0
        self.lut = torch.from_numpy(values).to(device)
        shape = (1, (seq_len + 1) * 3, INPUT_SIZE[1], INPUT_SIZE[0])
        self.buffers = [torch.empty(shape, dtype=torch.float32, device=device) for _ in range(2)]
        self.current = None
        self.background = None
        self.background_source = None

    def _normalize(self, image):
        data = np.ascontiguousarray(image.transpose(2, 0, 1))
        pixels = self.torch.from_numpy(data).to(self.device)
        return self.lut[pixels.long()]

    def push(self, rgb, median):
        if rgb.shape != (INPUT_SIZE[1], INPUT_SIZE[0], 3) or rgb.dtype != np.uint8:
            raise ValueError("unexpected TrackNet frame format")
        if median is None or median.shape != rgb.shape or median.dtype != np.uint8:
            raise ValueError("unexpected TrackNet background format")
        frame = self._normalize(rgb)
        if self.background_source is not median:
            self.background = self._normalize(median)
            self.background_source = median
        target = self.buffers[0 if self.current is None else 1 - self.current]
        target[:, :3].copy_(self.background)
        if self.current is None:
            for index in range(self.seq_len):
                target[:, 3 + index * 3:6 + index * 3].copy_(frame)
            self.current = 0
        else:
            previous = self.buffers[self.current]
            target[:, 3:-3].copy_(previous[:, 6:])
            target[:, -3:].copy_(frame)
            self.current = 1 - self.current
        return target
