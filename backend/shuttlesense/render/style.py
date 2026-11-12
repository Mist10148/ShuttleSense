"""Overlay colours and sizes, shared with the app theme (app/lib/core/theme/app_theme.dart)."""

from __future__ import annotations


def bgr(hex_color: str) -> tuple[int, int, int]:
    """'#RRGGBB' -> OpenCV (B, G, R)."""
    value = hex_color.lstrip("#")
    r, g, b = (int(value[i : i + 2], 16) for i in (0, 2, 4))
    return b, g, r


NEAR = bgr("#1565C0")
FAR = bgr("#E65100")
# Doubles partners: a lighter shade of their side's colour (app_theme.dart PlayerColors).
NEAR_2 = bgr("#42A5F5")
FAR_2 = bgr("#FFA726")
SHUTTLE = bgr("#C6A700")
COURT = bgr("#FFFFFF")
TEXT = bgr("#FFFFFF")
PANEL = bgr("#000000")
HIT = bgr("#FFD600")
IN_COURT = bgr("#2E7D32")
OUT_COURT = bgr("#C62828")
UNCERTAIN = bgr("#9E9E9E")
UNCERTAIN_CALL = bgr("#FBC02D")  # landing marker for close in/out calls
MINIMAP_BG = bgr("#2E7D4F")  # app seed colour

PLAYER_COLORS = {"near": NEAR, "far": FAR, "near_2": NEAR_2, "far_2": FAR_2}

FONT = 0  # cv2.FONT_HERSHEY_SIMPLEX
MIN_KEYPOINT_SCORE = 0.3

# COCO-17 skeleton edges.
SKELETON_EDGES = (
    (5, 7), (7, 9), (6, 8), (8, 10), (5, 6), (5, 11), (6, 12), (11, 12),
    (11, 13), (13, 15), (12, 14), (14, 16), (0, 1), (0, 2), (1, 3), (2, 4),
)  # fmt: skip


def scale_for(height: int) -> float:
    """Line/text scale relative to 720p so overlays look the same at any resolution."""
    return max(height, 1) / 720
