"""Court line segments and in/out areas in court meters (F9, F20), shared with the app minimap.

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


# Doubles adds 0.46 m outside each singles sideline; its long service line sits 0.76 m inside
# the baseline (serves only). Singles serves use the baseline as the long line.
DOUBLES_SIDE_ALLEY_M = 0.46
DOUBLES_LONG_SERVICE_M = 0.76

Bounds = tuple[float, float, float, float]  # x_min, x_max, y_min, y_max in court meters


def play_bounds(court: str = "singles", size: Point = COURT_SIZE_M) -> Bounds:
    """The area a rally shot must land in (lines are in)."""
    w, length = size
    alley = DOUBLES_SIDE_ALLEY_M if court == "doubles" else 0.0
    return (-alley, w + alley, 0.0, length)


def service_bounds(
    server_side: str, server_x: float, court: str = "singles", size: Point = COURT_SIZE_M
) -> Bounds:
    """The receiver's service court for a serve from `server_side` standing at `server_x`.

    Serves go diagonally: a server right of the centre line serves to the half of the court
    left of it, and the other way round.
    """
    w, length = size
    net = length / 2
    centre = w / 2
    alley = DOUBLES_SIDE_ALLEY_M if court == "doubles" else 0.0
    back = DOUBLES_LONG_SERVICE_M if court == "doubles" else 0.0
    x_lo, x_hi = (-alley, centre) if server_x >= centre else (centre, w + alley)
    if server_side == "near":
        return (x_lo, x_hi, net + SHORT_SERVICE_FROM_NET_M, length - back)
    return (x_lo, x_hi, back, net - SHORT_SERVICE_FROM_NET_M)
