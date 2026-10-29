"""Shuttlecock tracking with TrackNetV3 and gap interpolation (F2)."""

from shuttlesense.tracking.interpolate import interpolate_gaps
from shuttlesense.tracking.tracknet import run

__all__ = ["interpolate_gaps", "run"]
