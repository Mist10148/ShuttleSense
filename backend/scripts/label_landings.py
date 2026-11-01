"""Mark where each rally's shuttle landed, in court meters, for line-call evaluation (T8.12).

Usage: python scripts/label_landings.py --video ../samples/rally01.mp4 --labels labels/rally01.csv
                [--corners x1,y1,...,x4,y4 | --record out/record.json]

Adds landing_x_m and landing_y_m to the rally rows of a T7.1 label file (made with
label_clip.py), which eval_line_calls.py uses for its near-line numbers. All other columns
are kept. The court corners come from --corners (near-left, near-right, far-right, far-left
singles corners in video pixels) or from the calibration saved in a record.json, scaled from
the record's processing size to the video's.

Opens each rally at its end time in an OpenCV window (needs `pip install opencv-python`,
not the headless build).

Keys
    click            the landing point (click again to move it)
    left / right     one frame back / forward (also , and .)
    [ / ]            half a second back / forward
    n / p            next / previous rally
    x                clear this rally's landing
    s                save
    q or Esc         save and quit
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
from types import ModuleType

import numpy as np

LANDING_COLUMNS = ("landing_x_m", "landing_y_m")
MAX_OFF_COURT_M = 5.0  # a click farther from the court than this is a mistake


def _label_clip() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "label_clip", Path(__file__).with_name("label_clip.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_corners(text: str) -> list[tuple[float, float]]:
    values = [float(v) for v in text.split(",")]
    if len(values) != 8:
        raise ValueError("--corners needs 8 numbers: x1,y1,...,x4,y4")
    return [(values[i], values[i + 1]) for i in range(0, 8, 2)]


def corners_from_record(path: Path, video_size: tuple[int, int]) -> list[tuple[float, float]]:
    """The record's court corners, scaled from its processing size to the video's."""
    data = json.loads(path.read_text(encoding="utf-8"))
    court = data.get("court")
    if not court or not court.get("corners_px"):
        raise ValueError(f"{path} has no court calibration")
    sx, sy = video_size[0] / data["width"], video_size[1] / data["height"]
    return [(x * sx, y * sy) for x, y in court["corners_px"]]


def to_court(corners_px: list[tuple[float, float]], point_px: tuple[float, float]) -> tuple:
    """(x_m, y_m) of a pixel on the court plane, rounded to the centimeter."""
    from shuttlesense.court import compute_homography, image_to_court, validate_corners
    from shuttlesense.schema import COURT_SIZE_M

    validate_corners(corners_px)
    x, y = image_to_court(compute_homography(corners_px), np.array([point_px], dtype=float))[0]
    width, length = COURT_SIZE_M
    near = -MAX_OFF_COURT_M <= x <= width + MAX_OFF_COURT_M and (
        -MAX_OFF_COURT_M <= y <= length + MAX_OFF_COURT_M
    )
    if not (np.isfinite(x) and np.isfinite(y) and near):
        raise ValueError("that point is not on or near the court floor")
    return round(float(x), 2), round(float(y), 2)


class LandingLabels:
    """The rally rows of one label file and their landings."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.labels = _label_clip().ClipLabels.load(path)
        for column in LANDING_COLUMNS:
            if column not in self.labels.extra:
                self.labels.extra.append(column)

    @property
    def rallies(self) -> list[dict]:
        return sorted(self.labels.rallies, key=lambda r: r["start_s"])

    def landing(self, index: int) -> tuple[float, float] | None:
        r = self.rallies[index]
        x, y = r.get("landing_x_m"), r.get("landing_y_m")
        return (float(x), float(y)) if x not in (None, "") and y not in (None, "") else None

    def set_landing(self, index: int, point_m: tuple[float, float] | None) -> None:
        r = self.rallies[index]
        r["landing_x_m"], r["landing_y_m"] = (
            (f"{point_m[0]:.2f}", f"{point_m[1]:.2f}") if point_m else ("", "")
        )

    def save(self) -> None:
        self.labels.save(self.path)


# OpenCV key codes for the arrows differ by platform (waitKeyEx).
LEFT_KEYS = {2424832, 65361, 81, ord(",")}
RIGHT_KEYS = {2555904, 65363, 83, ord(".")}


def run_window(video: Path, labels: LandingLabels, corners: list) -> None:  # pragma: no cover
    import cv2

    if not labels.rallies:
        raise SystemExit(f"{labels.path} has no rally rows; label rallies with label_clip.py")
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise SystemExit(f"cannot open {video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) or 1
    rally = 0
    index = min(int(labels.rallies[0]["end_s"] * fps), total - 1)
    message = "click the landing; n/p: rally, s: save, q: quit"
    window = f"landings {video.name}"
    clicked: list[tuple[int, int]] = []
    cv2.namedWindow(window)
    cv2.setMouseCallback(
        window, lambda event, x, y, *_: clicked.append((x, y)) if event == 1 else None
    )
    poly = np.array(corners, dtype=np.int32)
    while True:
        cap.set(cv2.CAP_PROP_POS_FRAMES, index)
        ok, frame = cap.read()
        if not ok:
            index = max(index - 1, 0)
            continue
        if clicked:
            try:
                labels.set_landing(rally, to_court(corners, clicked.pop()))
                message = f"rally {rally + 1}: landing {labels.landing(rally)} m"
            except ValueError as exc:
                message = str(exc)
        cv2.polylines(frame, [poly], True, (0, 255, 255), 1)
        r = labels.rallies[rally]
        point = labels.landing(rally)
        status = (
            f"rally {rally + 1}/{len(labels.rallies)} ({r['start_s']:.1f}-{r['end_s']:.1f} s, "
            f"{r.get('in_out') or 'no call'})  frame {index}  landing "
            + (f"{point[0]:.2f}, {point[1]:.2f} m" if point else "-")
        )
        for y, text in ((30, status), (60, message)):
            cv2.putText(frame, text, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 4)
            cv2.putText(frame, text, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 1)
        cv2.imshow(window, frame)
        key = cv2.waitKeyEx(30)
        if key in (ord("q"), 27):
            break
        if key in LEFT_KEYS:
            index = max(index - 1, 0)
        elif key in RIGHT_KEYS:
            index = min(index + 1, total - 1)
        elif key in (ord("["), ord("]")):
            step = round(fps / 2) * (1 if key == ord("]") else -1)
            index = min(max(index + step, 0), total - 1)
        elif key in (ord("n"), ord("p")):
            rally = (rally + (1 if key == ord("n") else -1)) % len(labels.rallies)
            index = min(int(labels.rallies[rally]["end_s"] * fps), total - 1)
        elif key == ord("x"):
            labels.set_landing(rally, None)
            message = f"rally {rally + 1}: landing cleared"
        elif key == ord("s"):
            labels.save()
            message = f"saved {labels.path}"
    labels.save()
    cap.release()
    cv2.destroyAllWindows()
    done = sum(labels.landing(i) is not None for i in range(len(labels.rallies)))
    print(f"saved {done} of {len(labels.rallies)} landings to {labels.path}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--labels", type=Path, required=True, help="T7.1 label file to extend")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--corners", help="x1,y1,...,x4,y4 in video pixels")
    group.add_argument("--record", type=Path, help="record.json with the court calibration")
    args = parser.parse_args()
    if args.corners:
        corners = parse_corners(args.corners)
    else:
        import cv2

        cap = cv2.VideoCapture(str(args.video))
        size = (int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)))
        cap.release()
        corners = corners_from_record(args.record, size)
    run_window(args.video, LandingLabels(args.labels), corners)


if __name__ == "__main__":
    main()
