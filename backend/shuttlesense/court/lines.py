"""Singles court line segments in court meters (F9), shared with the app minimap.

Origin at the near-left singles corner, x across (0 to width), y toward the far baseline
(0 to length). Keep in sync with app/lib/features/results/widgets/court_minimap.dart.
"""

from __future__ import annotations

from shuttlesense.schema import COURT_SIZE_M, Point

SHORT_SERVICE_FROM_NET_M = 1.98

Segment = tuple[Point, Point]


def court_lines(size: Point = COURT_SIZE_M) -> dict[str, list[Segment]]:
    """Named groups of line segments: outline, net, short service lines, centre lines."""
    w, length = size
    net = length / 2
    near_ss, far_ss = net - SHORT_SERVICE_FROM_NET_M, net + SHORT_SERVICE_FROM_NET_M
    return {
        "outline": [
            ((0.0, 0.0), (w, 0.0)),
            ((w, 0.0), (w, length)),
            ((w, length), (0.0, length)),
            ((0.0, length), (0.0, 0.0)),
        ],
        "net": [((0.0, net), (w, net))],
        "short_service": [((0.0, near_ss), (w, near_ss)), ((0.0, far_ss), (w, far_ss))],
        "centre": [((w / 2, 0.0), (w / 2, near_ss)), ((w / 2, far_ss), (w / 2, length))],
    }
