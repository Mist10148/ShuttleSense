"""Click the shuttle on frames of a clip to make tracking ground truth (T2.10).

Usage: python scripts/label_shuttle.py --video ../samples/rally01.mp4
                [--out labels/rally01_shuttle.csv] [--every 1] [--start 0] [--count 300]

Opens an OpenCV window (needs `pip install opencv-python`, not the headless build) on every
--every-th source frame from --start, --count frames in all.

    left click       the shuttle is here (moves to the next frame)
    x                the shuttle is not visible on this frame (next frame)
    left / right     previous / next frame without labelling (also , and .)
    d                delete this frame's label
    s                save
    q or Esc         save and quit

Output: the TrackNetV3 CSV layout `Frame,Visibility,X,Y` in source frames and source pixels,
read by eval_tracking.py (pass --gt-height with the clip's height, and --gt-step when the
pipeline lowered the fps). An existing file is loaded first, so labelling can resume.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

COLUMNS = ("Frame", "Visibility", "X", "Y")


class ShuttleLabels:
    """frame -> (visible, x, y) in source pixels."""

    def __init__(self) -> None:
        self.points: dict[int, tuple[int, float, float]] = {}

    def mark(self, frame: int, x: float, y: float) -> None:
        self.points[frame] = (1, round(x, 1), round(y, 1))

    def mark_invisible(self, frame: int) -> None:
        self.points[frame] = (0, 0.0, 0.0)

    def clear(self, frame: int) -> None:
        self.points.pop(frame, None)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(COLUMNS)
            for frame in sorted(self.points):
                vis, x, y = self.points[frame]
                writer.writerow([frame, vis, f"{x:g}", f"{y:g}"])

    @classmethod
    def load(cls, path: Path) -> ShuttleLabels:
        labels = cls()
        if path.exists():
            with path.open(newline="", encoding="utf-8-sig") as f:
                for row in csv.DictReader(f):
                    vis = int(float(row["Visibility"]))
                    labels.points[int(float(row["Frame"]))] = (
                        vis, float(row["X"]) if vis else 0.0, float(row["Y"]) if vis else 0.0
                    )  # fmt: skip
        return labels


def frames_to_label(start: int, count: int, every: int, total: int) -> list[int]:
    """Source frame numbers to visit: start, start+every, ... (count of them, within the video)."""
    return [f for f in range(start, total, max(every, 1))][: max(count, 0)]


def to_source(point: tuple[int, int], scale: float) -> tuple[float, float]:
    """Window pixels -> source pixels (the window shows the frame scaled by `scale`)."""
    return point[0] / scale, point[1] / scale


def run_window(video: Path, out: Path, frames: list[int]) -> None:  # pragma: no cover - GUI
    import cv2

    labels = ShuttleLabels.load(out)
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise SystemExit(f"cannot open {video}")
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)) or 720
    scale = min(1.0, 900 / height)  # fit a 1080p frame on a laptop screen
    window = f"shuttle {video.name}"
    clicked: list[tuple[int, int]] = []
    cv2.namedWindow(window)
    cv2.setMouseCallback(
        window, lambda ev, x, y, *_: clicked.append((x, y)) if ev == cv2.EVENT_LBUTTONDOWN else None
    )
    pos = 0
    while 0 <= pos < len(frames):
        frame_no = frames[pos]
        cap.set(cv2.CAP_PROP_POS_FRAMES, frame_no)
        ok, img = cap.read()
        if not ok:
            break
        img = cv2.resize(img, None, fx=scale, fy=scale) if scale != 1.0 else img
        vis, x, y = labels.points.get(frame_no, (None, 0.0, 0.0))
        if vis == 1:
            cv2.circle(img, (round(x * scale), round(y * scale)), 6, (0, 255, 255), 2)
        state = {None: "unlabelled", 0: "not visible", 1: f"({x:g}, {y:g})"}[vis]
        text = f"frame {frame_no} ({pos + 1}/{len(frames)})  {state}"
        cv2.putText(img, text, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 4)
        cv2.putText(img, text, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 1)
        cv2.imshow(window, img)
        clicked.clear()
        while True:
            key = cv2.waitKeyEx(30)
            if clicked:
                labels.mark(frame_no, *to_source(clicked[-1], scale))
                pos += 1
                break
            if key == -1:
                continue
            if key in (ord("q"), 27):
                pos = -1
            elif key == ord("x"):
                labels.mark_invisible(frame_no)
                pos += 1
            elif key == ord("d"):
                labels.clear(frame_no)
            elif key in (2424832, 65361, 81, ord(",")):
                pos = max(pos - 1, 0)
            elif key in (2555904, 65363, 83, ord(".")):
                pos += 1
            elif key == ord("s"):
                labels.save(out)
            else:
                continue
            break
    labels.save(out)
    cap.release()
    cv2.destroyAllWindows()
    visible = sum(1 for v, _, _ in labels.points.values() if v)
    print(f"saved {len(labels.points)} frames ({visible} with the shuttle) to {out}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=None, help="default labels/<stem>_shuttle.csv")
    parser.add_argument("--start", type=int, default=0, help="first source frame")
    parser.add_argument("--count", type=int, default=300, help="frames to label")
    parser.add_argument("--every", type=int, default=1, help="label every n-th frame")
    args = parser.parse_args()
    import cv2

    cap = cv2.VideoCapture(str(args.video))
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    cap.release()
    frames = frames_to_label(args.start, args.count, args.every, total)
    run_window(args.video, args.out or Path("labels") / f"{args.video.stem}_shuttle.csv", frames)


if __name__ == "__main__":
    main()
