"""Experimental exact RTMPose crop normalization using byte lookup tables."""

from __future__ import annotations

import numpy as np


class PoseCropLookup:
    """Reuse RTMLib's geometry and OpenCV warp; replace only pixel normalization."""

    def __init__(self, pose):
        from rtmlib.tools.pose_estimation.rtmpose import bbox_xyxy2cs, top_down_affine

        self.pose = pose
        self.enabled = True
        self.bbox_xyxy2cs, self.top_down_affine = bbox_xyxy2cs, top_down_affine
        mean, std = np.asarray(pose.mean), np.asarray(pose.std)
        if (
            mean.shape != (3,)
            or std.shape != (3,)
            or np.any(std == 0)
            or mean.dtype != np.float64
            or std.dtype != np.float64
        ):
            raise ValueError("unsupported RTMPose normalization")
        values = np.arange(256, dtype=np.float64)[:, None]
        self.lookup = np.asarray((values - mean) / std, dtype=np.float32).T.copy()

    def prepare(self, image, boxes):
        width, height = self.pose.model_input_size
        batch = np.empty((len(boxes), 3, height, width), dtype=np.float32)
        geometry = []
        for index, box in enumerate(boxes):
            center, scale = self.bbox_xyxy2cs(np.array(box), padding=1.25)
            crop, scale = self.top_down_affine(self.pose.model_input_size, scale, center, image)
            if crop.dtype != np.uint8 or crop.shape != (height, width, 3):
                raise ValueError("unsupported RTMPose crop")
            for channel in range(3):
                batch[index, channel] = self.lookup[channel, crop[:, :, channel]]
            geometry.append((center, scale))
        return batch, geometry
