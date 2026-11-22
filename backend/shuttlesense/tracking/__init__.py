"""Shuttlecock tracking with TrackNetV3 and gap interpolation (F2)."""

from shuttlesense.tracking.interpolate import interpolate_gaps
from shuttlesense.tracking.postprocess import (
    heatmap_to_xy,
    rectify,
    remove_outliers,
    scale_to_video,
    track_arrays,
)
from shuttlesense.tracking.tracknet import run as _tracknet_run


def run(record, ctx):
    """The tracking stage on a whole uploaded clip: tracknet.run, with the flight fitting of
    rectify switched on (postprocess.offline_tracking). Live and Watch windows call rectify
    directly and keep their per-tick cost."""
    from shuttlesense.tracking.postprocess import offline_tracking

    with offline_tracking(record.height):
        return _tracknet_run(record, ctx)


__all__ = [
    "heatmap_to_xy",
    "interpolate_gaps",
    "rectify",
    "remove_outliers",
    "run",
    "scale_to_video",
    "track_arrays",
]
