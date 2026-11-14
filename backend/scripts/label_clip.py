"""Label hits, strokes and rallies on a team phone clip (T7.1).

Usage: python scripts/label_clip.py --video ../samples/rally01.mp4 [--out labels/rally01.csv]
       python scripts/label_clip.py --video ../samples/doubles01.mp4 --boxes [--every 10]

Opens the clip in an OpenCV window (needs `pip install opencv-python`, not the headless
build). Labels are kept in seconds, so they hold for any fps the pipeline normalizes to.

Keys
    space            play / pause
    left / right     one frame back / forward (also , and .)
    [ / ]            one second back / forward
    n / f            the player who hits next is near / far (shown on screen)
    a / b            doubles: the next hitter is player 1 / 2 of that side (1 = the one
                     on the left when play starts, as the app numbers them)
    1-6              hit at this frame by that player: 1 smash, 2 clear, 3 drop,
                     4 net shot, 5 lift, 6 serve
    h                hit at this frame with no stroke class
    r                rally starts here; press again where it ends
    N / F            winner of the last rally is near / far
    i / o            the last rally ended in / out
    u                undo the last hit or rally
    s                save
    q or Esc         save and quit

The output is the label file read by eval_phone.py, eval_hits.py, eval_rallies.py and
eval_doubles.py (UTF-8, header row): hit rows fill time_s, player, stroke; rally rows fill
start_s, end_s, winner, in_out, and in doubles server and receiver. In doubles a hit's player
is a slot (near_1, near_2, far_1, far_2); a rally's server is the slot of its first hit and its
receiver the slot of its second (the receiver always returns the serve). An existing file
is loaded first, so labelling can resume; columns this tool does not edit
(such as landing_x_m / landing_y_m from label_landings.py) are kept as they are.

With --boxes (doubles, T9.2) the tool steps through every --every-th frame instead and asks
for the four player boxes, one slot at a time: drag a box and press Enter, or press c (or
Enter with no box) when that player is not in view. Boxes go to labels/<video stem>_boxes.csv
(frame, time_s, slot, x, y, w, h in source pixels), read by eval_doubles.py --boxes for ID
switches and IDF1. Frames already labelled for all four slots are skipped, so it resumes too.
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass, field
from pathlib import Path

COLUMNS = ("time_s", "player", "stroke", "start_s", "end_s", "winner", "in_out", "server",
           "receiver")  # fmt: skip
SLOTS = ("near_1", "near_2", "far_1", "far_2")
STROKE_KEYS = {"1": "smash", "2": "clear", "3": "drop", "4": "net_shot", "5": "lift", "6": "serve"}


@dataclass
class ClipLabels:
    """Hits and rallies of one clip, edited by key presses."""

    hits: list[dict] = field(default_factory=list)
    rallies: list[dict] = field(default_factory=list)
    player: str = "near"
    rally_start: float | None = None
    extra: list[str] = field(default_factory=list)  # other tools' columns, kept on save
    _order: list[str] = field(default_factory=list)  # "hit" / "rally", for undo

    def handle_key(self, key: str, time_s: float) -> str | None:
        """Apply one key at playback time `time_s`; returns a status message, or None if the
        key is not a labelling key."""
        t = round(time_s, 3)
        if key in ("n", "f"):
            self.player = "near" if key == "n" else "far"
            return f"next hitter: {self.player}"
        if key in ("a", "b"):
            side = self.player.split("_")[0]
            self.player = f"{side}_{1 if key == 'a' else 2}"
            return f"next hitter: {self.player}"
        if key in STROKE_KEYS or key == "h":
            stroke = STROKE_KEYS.get(key, "")
            self.hits.append({"time_s": t, "player": self.player, "stroke": stroke})
            self._order.append("hit")
            # The other side hits next (in doubles, either partner: press a / b).
            self.player = "far" if self.player.startswith("near") else "near"
            return f"hit {t:.3f}s {stroke or '(no class)'}"
        if key == "r":
            if self.rally_start is None:
                self.rally_start = t
                return f"rally starts {t:.3f}s"
            start, self.rally_start = self.rally_start, None
            if t <= start:
                return "rally end must be after its start; start cleared"
            self.rallies.append({"start_s": start, "end_s": t, "winner": "", "in_out": ""})
            self._order.append("rally")
            return f"rally {start:.3f}-{t:.3f}s"
        if key in ("N", "F", "i", "o"):
            if not self.rallies:
                return "no rally yet"
            last = self.rallies[-1]
            if key in ("N", "F"):
                last["winner"] = "near" if key == "N" else "far"
                return f"rally winner: {last['winner']}"
            last["in_out"] = "in" if key == "i" else "out"
            return f"rally ended {last['in_out']}"
        if key == "u":
            if not self._order:
                return "nothing to undo"
            kind = self._order.pop()
            (self.hits if kind == "hit" else self.rallies).pop()
            return f"removed last {kind}"
        return None

    def rows(self) -> list[dict[str, str]]:
        """CSV rows: hits, then rallies, each in time order."""
        out = []
        for h in sorted(self.hits, key=lambda h: h["time_s"]):
            out.append({
                **{c: h.get(c, "") for c in self.extra},
                "time_s": f"{h['time_s']:.3f}", "player": h["player"], "stroke": h["stroke"],
            })  # fmt: skip
        for r in sorted(self.rallies, key=lambda r: r["start_s"]):
            server, receiver = self.service(r)
            out.append({
                **{c: r.get(c, "") for c in self.extra},
                "start_s": f"{r['start_s']:.3f}",
                "end_s": f"{r['end_s']:.3f}",
                "winner": r["winner"],
                "in_out": r["in_out"],
                "server": server,
                "receiver": receiver,
            })  # fmt: skip
        return out

    def service(self, rally: dict) -> tuple[str, str]:
        """Doubles (server, receiver) of a rally: the slots of its first two hits; empty
        when those hits name a side only (singles, or the partner was not marked)."""
        hits = sorted(
            (h for h in self.hits if rally["start_s"] <= h["time_s"] <= rally["end_s"]),
            key=lambda h: h["time_s"],
        )
        slots = [h["player"] if h["player"] in SLOTS else "" for h in hits[:2]]
        slots += [""] * (2 - len(slots))
        return slots[0], slots[1]

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=[*COLUMNS, *self.extra], restval="")
            writer.writeheader()
            writer.writerows(self.rows())

    @classmethod
    def load(cls, path: Path) -> ClipLabels:
        labels = cls()
        if not path.exists():
            return labels
        with path.open(newline="", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f)
            labels.extra = [c for c in reader.fieldnames or [] if c not in COLUMNS]
            for row in reader:
                kept = {c: row.get(c) or "" for c in labels.extra}
                if row.get("time_s"):
                    labels.hits.append({
                        **kept,
                        "time_s": float(row["time_s"]),
                        "player": row.get("player", ""),
                        "stroke": row.get("stroke", ""),
                    })  # fmt: skip
                    labels._order.append("hit")
                elif row.get("start_s") and row.get("end_s"):
                    labels.rallies.append({
                        **kept,
                        "start_s": float(row["start_s"]),
                        "end_s": float(row["end_s"]),
                        "winner": row.get("winner", ""),
                        "in_out": row.get("in_out", ""),
                    })  # fmt: skip
                    labels._order.append("rally")
        return labels


# OpenCV key codes for the arrows differ by platform (waitKeyEx).
LEFT_KEYS = {2424832, 65361, 81, ord(",")}
RIGHT_KEYS = {2555904, 65363, 83, ord(".")}


BOX_COLUMNS = ("frame", "time_s", "slot", "x", "y", "w", "h")
Box = tuple[float, float, float, float]


@dataclass
class BoxLabels:
    """Player boxes per (frame, slot) for doubles identity evaluation (T9.2). A slot with
    `None` was looked at and is not in view."""

    fps: float = 30.0
    boxes: dict[tuple[int, str], Box | None] = field(default_factory=dict)

    def set(self, frame: int, slot: str, box: Box | None) -> None:
        if slot not in SLOTS:
            raise ValueError(f"unknown slot {slot!r}")
        self.boxes[(frame, slot)] = box

    def frames_to_label(self, total: int, every: int) -> list[int]:
        """Every `every`-th frame that still misses one of the four slots."""
        return [
            f
            for f in range(0, total, max(1, every))
            if any((f, slot) not in self.boxes for slot in SLOTS)
        ]

    @classmethod
    def load(cls, path: Path, fps: float = 30.0) -> BoxLabels:
        labels = cls(fps=fps)
        if not path.exists():
            return labels
        with path.open(newline="", encoding="utf-8-sig") as f:
            for row in csv.DictReader(f):
                box = None
                if row.get("w") and row.get("h"):
                    box = tuple(float(row[k]) for k in ("x", "y", "w", "h"))
                labels.boxes[(int(row["frame"]), row["slot"])] = box  # type: ignore[assignment]
        return labels

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(BOX_COLUMNS)
            for (frame, slot), box in sorted(self.boxes.items()):
                xywh = ["", "", "", ""] if box is None else [f"{v:.1f}" for v in box]
                writer.writerow([frame, f"{frame / self.fps:.3f}", slot, *xywh])


def run_boxes(video: Path, out: Path, every: int) -> None:  # pragma: no cover - needs a display
    import cv2

    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise SystemExit(f"cannot open {video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) or 1
    labels = BoxLabels.load(out, fps)
    window = f"boxes {video.name}"
    try:
        for frame_index in labels.frames_to_label(total, every):
            cap.set(cv2.CAP_PROP_POS_FRAMES, frame_index)
            ok, frame = cap.read()
            if not ok:
                break
            for slot in SLOTS:
                if (frame_index, slot) in labels.boxes:
                    continue
                shown = frame.copy()
                text = f"frame {frame_index}: box {slot} (Enter: ok, c: not in view, Esc: quit)"
                for color, thickness in (((0, 0, 0), 4), ((255, 255, 255), 1)):
                    cv2.putText(shown, text, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, color,
                                thickness)  # fmt: skip
                x, y, w, h = cv2.selectROI(window, shown, showCrosshair=False)
                if cv2.waitKey(1) == 27:
                    raise KeyboardInterrupt
                labels.set(frame_index, slot, (x, y, w, h) if w and h else None)
            labels.save(out)
    except KeyboardInterrupt:
        pass
    labels.save(out)
    cap.release()
    cv2.destroyAllWindows()
    print(f"saved {len(labels.boxes)} slot labels to {out}")


def run_window(video: Path, out: Path) -> None:  # pragma: no cover - needs a display
    import cv2

    labels = ClipLabels.load(out)
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise SystemExit(f"cannot open {video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) or 1
    index, playing, message = 0, False, "space: play, n/f: player, 1-6: stroke, r: rally"
    window = f"label {video.name}"
    while True:
        cap.set(cv2.CAP_PROP_POS_FRAMES, index)
        ok, frame = cap.read()
        if not ok:
            if index == 0:  # nothing readable to step back to: stop instead of spinning
                cap.release()
                raise SystemExit(f"cannot read frames from {video}")
            index, playing = index - 1, False
            continue
        t = index / fps
        status = (
            f"{t:7.3f}s  frame {index}/{total}  next: {labels.player}  "
            f"hits {len(labels.hits)}  rallies {len(labels.rallies)}"
            + ("  [rally open]" if labels.rally_start is not None else "")
        )
        for y, text in ((30, status), (60, message)):
            cv2.putText(frame, text, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 4)
            cv2.putText(frame, text, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 1)
        cv2.imshow(window, frame)
        key = cv2.waitKeyEx(max(1, int(1000 / fps)) if playing else 0)
        if playing and key == -1:
            index = min(index + 1, total - 1)
            continue
        if key in (ord("q"), 27):
            break
        if key == ord(" "):
            playing = not playing
        elif key in LEFT_KEYS:
            index, playing = max(index - 1, 0), False
        elif key in RIGHT_KEYS:
            index, playing = min(index + 1, total - 1), False
        elif key in (ord("["), ord("]")):
            step = round(fps) * (1 if key == ord("]") else -1)
            index = min(max(index + step, 0), total - 1)
        elif key == ord("s"):
            labels.save(out)
            message = f"saved {out}"
        elif 0 <= key < 256:
            message = labels.handle_key(chr(key), t) or message
    labels.save(out)
    cap.release()
    cv2.destroyAllWindows()
    print(f"saved {len(labels.hits)} hits and {len(labels.rallies)} rallies to {out}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=None, help="default labels/<video stem>.csv")
    parser.add_argument("--boxes", action="store_true", help="doubles: label player boxes")
    parser.add_argument("--every", type=int, default=10, help="--boxes: every n-th frame")
    args = parser.parse_args()
    if args.boxes:
        out = args.out or Path("labels") / f"{args.video.stem}_boxes.csv"
        run_boxes(args.video, out, args.every)
    else:
        run_window(args.video, args.out or Path("labels") / f"{args.video.stem}.csv")


if __name__ == "__main__":
    main()
