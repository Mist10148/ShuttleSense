import cv2
import numpy as np
import pytest
from test_eval_scripts import load_script

from shuttlesense.io import FrameReader

audit = load_script("audit_watch_jpeg").audit


def test_audit_reports_pixel_difference_for_normalized_video(tiny_video):
    reader = FrameReader(tiny_video)
    frame = reader.read(0)
    ok, jpeg = cv2.imencode(".jpg", frame)
    assert ok
    decoded = cv2.imdecode(jpeg, cv2.IMREAD_COLOR)
    difference = np.abs(frame.astype(np.int16) - decoded.astype(np.int16))

    result = audit(reader, 1)

    assert result["frames"] == 1
    assert result["normalized_size"] == [reader.width, reader.height]
    assert result["changed_channel_values_percent"] == round(
        100 * np.count_nonzero(difference) / difference.size, 3
    )
    assert result["mean_absolute_channel_error"] == round(float(difference.mean()), 3)
    assert result["max_absolute_channel_error"] == int(difference.max())
    assert result["median_jpeg_bytes"] == jpeg.nbytes
    with pytest.raises(ValueError, match="frame limit"):
        audit(reader, 0)
