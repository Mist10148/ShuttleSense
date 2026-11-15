"""Conservative image-space preselection for Watch's RTMPose candidates."""
from __future__ import annotations

import cv2
import numpy as np

from shuttlesense.court import court_to_image
from shuttlesense.court.lines import play_bounds


class WatchCandidates:
    """Keep court-near boxes and anything near a confirmed player's last box.

    A malformed projection, clipped court, or missing calibration disables filtering.
    Shadow mode records estimates but leaves all candidates in inference.
    """

    def __init__(self, tracker, homography, frame_size, mode="shadow", margin_m=2.0,
                 proposal_margin=None, proposal_footpoint=False, footpoint=False):
        self.tracker, self.homography, self.frame_size = tracker, homography, frame_size
        self.mode, self.margin = mode, margin_m
        self.footpoint = footpoint
        self.stats = {"frames": 0, "people": 0, "eligible": 0, "excluded": 0,
                      "tracked_excluded": 0, "detection_s": 0.0, "pose_s": 0.0,
                      "fallback": False}
        self.excluded_players = []
        self.proposal = (WatchCandidates(
            tracker, homography, frame_size, "shadow",
            margin_m if proposal_margin is None else proposal_margin, footpoint=proposal_footpoint,
        ) if proposal_margin is not None or proposal_footpoint else None)
        self.proposal_keep = []
        self.proposal_stats = {"frames": 0, "additional_excluded": 0, "tracked_excluded": 0}
        self.proposal_players = []

    def select(self, boxes, image_shape):
        self.proposal_players = []
        if self.proposal is not None:
            self.proposal_keep = self.proposal.select(boxes, image_shape)
        keep = self._select(boxes, image_shape)
        if self.proposal is not None:
            self.proposal_stats["frames"] += 1
            self.proposal_stats["additional_excluded"] += sum(
                old and not new for old, new in zip(keep, self.proposal_keep, strict=True)
            )
        return keep

    def _select(self, boxes, image_shape):
        self.excluded_players = []
        keep = [True] * len(boxes)
        if self.homography is None or not len(boxes):
            return keep
        h, w = image_shape[:2]
        sx, sy = self.frame_size[0] / w, self.frame_size[1] / h
        xmin, xmax, ymin, ymax = play_bounds(self.tracker.court, self.tracker.court_size)
        try:
            p = court_to_image(self.homography, np.array([
                [xmin-self.margin, ymin-self.margin], [xmax+self.margin, ymin-self.margin],
                [xmax+self.margin, ymax+self.margin], [xmin-self.margin, ymax+self.margin],
            ])) / [sx, sy]
            if not np.isfinite(p).all() or np.abs(p).max() > max(w, h) * 20:
                return keep
            polygon = np.asarray(p, dtype=np.float32)
            if not cv2.isContourConvex(polygon):
                return keep
            # If the playable court extends offscreen we cannot safely identify spectators.
            court = court_to_image(self.homography, np.array([
                [xmin, ymin], [xmax, ymin], [xmax, ymax], [xmin, ymax],
            ])) / [sx, sy]
            if not np.isfinite(court).all() or any(
                x < 0 or x >= w or y < 0 or y >= h for x, y in court
            ):
                return keep
            protected = []
            for track in self.tracker.slots.values():
                if not track.locked or track.bbox is None:
                    continue
                x, y, bw, bh = track.bbox
                # A generous image-space envelope follows a locked player outside lines.
                protected.append(((x-bh)/sx, (y-bh)/sy, (x+bw+bh)/sx, (y+2*bh)/sy))
            keep = []
            for box in boxes:
                x0, y0, x1, y1 = map(float, box[:4])
                if not np.isfinite([x0, y0, x1, y1]).all() or x1 <= x0 or y1 <= y0:
                    keep.append(True)
                    continue
                rect = np.asarray([[x0,y0],[x1,y0],[x1,y1],[x0,y1]], dtype=np.float32)
                overlap, _ = cv2.intersectConvexConvex(polygon, rect)
                if self.footpoint:
                    overlap = cv2.pointPolygonTest(polygon, ((x0 + x1) / 2, y1), False) >= 0
                near_track = any(x0 <= b and x1 >= a and y0 <= d and y1 >= c
                                 for a, c, b, d in protected)
                keep.append(overlap > 0 or near_track)
        except (ValueError, TypeError, cv2.error, np.linalg.LinAlgError, ZeroDivisionError):
            return [True] * len(boxes)
        return keep

    def record(self, total, keep, detection_s, pose_s):
        self.stats["frames"] += 1
        self.stats["people"] += total
        self.stats["eligible"] += sum(keep)
        self.stats["excluded"] += total - sum(keep)
        self.stats["detection_s"] += detection_s
        self.stats["pose_s"] += pose_s

    def audit(self, players):
        if self.proposal is not None:
            for name in ("near", "near_2", "far", "far_2"):
                player = getattr(players, name)
                if player is not None and any(player.bbox == p.bbox for p in self.proposal_players):
                    self.proposal_stats["tracked_excluded"] += 1
        if self.mode != "shadow":
            return
        for name in ("near", "near_2", "far", "far_2"):
            player = getattr(players, name)
            if player is not None and any(player.bbox == p.bbox for p in self.excluded_players):
                self.stats["tracked_excluded"] += 1
