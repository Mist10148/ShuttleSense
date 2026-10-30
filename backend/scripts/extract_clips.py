"""Cut per-stroke clips from ShuttleSet match videos (T3.1, T3.2).

Usage: python scripts/extract_clips.py --matches 1-22 [--pad-frames 16]
Input:  data/shuttleset/match_list.csv (match_id, video) and the per-set annotation CSVs
        data/shuttleset/<match_id>/set*.csv (ShuttleSet columns: rally, ball_round,
        frame_num, player, type), videos in data/videos/.
Output: data/clips/<match_id>/<set>_<rally>_<stroke>.mp4 and data/clips/<match_id>/index.csv
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
INDEX_COLUMNS = (
    "clip",
    "match_id",
    "set",
    "rally",
    "stroke_no",
    "hit_frame_in_clip",
    "player",
    "shuttleset_type",
    "fps",
)


@dataclass(frozen=True)
class Stroke:
    set: int
    rally: int
    stroke_no: int
    frame: int
    player: str
    type: str


@dataclass(frozen=True)
class Window:
    stroke: Stroke
    start: int  # first source frame, inclusive
    end: int  # last source frame, inclusive

    @property
    def hit_frame_in_clip(self) -> int:
        return self.stroke.frame - self.start


def parse_range(text: str) -> list[int]:
    start, _, end = text.partition("-")
    return list(range(int(start), int(end or start) + 1))


def stroke_windows(strokes: list[Stroke], pad: int, num_frames: int) -> tuple[list[Window], int]:
    """[frame - pad, frame + pad] around each stroke, and the number skipped.

    A window is skipped when it runs past the video, or crosses into another rally: it must
    stay after the previous rally's last stroke and before the next rally's first stroke.
    """
    ordered = sorted(strokes, key=lambda s: (s.set, s.rally, s.frame))
    rallies: dict[tuple[int, int], list[Stroke]] = {}
    for s in ordered:
        rallies.setdefault((s.set, s.rally), []).append(s)
    keys = list(rallies)
    windows, skipped = [], 0
    for k, key in enumerate(keys):
        lo = rallies[keys[k - 1]][-1].frame + 1 if k > 0 else 0
        hi = rallies[keys[k + 1]][0].frame - 1 if k + 1 < len(keys) else num_frames - 1
        hi = min(hi, num_frames - 1)
        for s in rallies[key]:
            start, end = s.frame - pad, s.frame + pad
            if start < lo or end > hi:
                skipped += 1
                continue
            windows.append(Window(s, start, end))
    return windows, skipped


def _int(text: str) -> int:
    """ShuttleSet writes most numbers as floats ("11496.0")."""
    return int(float(text))


def read_strokes(match_dir: Path) -> list[Stroke]:
    strokes = []
    for set_no, path in enumerate(sorted(match_dir.glob("set*.csv")), start=1):
        with path.open(newline="", encoding="utf-8-sig") as f:
            for row in csv.DictReader(f):
                strokes.append(
                    Stroke(
                        set=set_no,
                        rally=_int(row["rally"]),
                        stroke_no=_int(row["ball_round"]),
                        frame=_int(row["frame_num"]),
                        player=row["player"],
                        type=row["type"],
                    )
                )
    return strokes


def cut_clips(video: Path, windows: list[Window], out_dir: Path, match_id: str) -> int:
    """Write one 720p clip per window (existing clips are kept: resume support).

    VideoWriter only moves a clip into place once it is complete, so an interrupted run
    leaves no partial clip to be kept on resume."""
    from shuttlesense.io import FrameReader
    from shuttlesense.render.writer import VideoWriter

    # No fps downsampling, so normalized frame indices equal the annotation's source frames.
    reader = FrameReader(video, target_height=720, max_fps=0)
    out_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    for w in windows:
        name = f"{w.stroke.set}_{w.stroke.rally}_{w.stroke.stroke_no}.mp4"
        rows.append(
            [
                name,
                match_id,
                w.stroke.set,
                w.stroke.rally,
                w.stroke.stroke_no,
                w.hit_frame_in_clip,
                w.stroke.player,
                w.stroke.type,
                f"{reader.fps:.3f}",
            ]
        )
        target = out_dir / name
        if target.exists():
            continue
        with VideoWriter(target, fps=reader.fps, size=(reader.width, reader.height)) as writer:
            for _i, frame in reader.frames(w.start, w.end + 1):
                writer.write(frame)
    with (out_dir / "index.csv").open("w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows([INDEX_COLUMNS, *rows])
    return len(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matches", type=parse_range, default=parse_range("1-44"))
    parser.add_argument("--pad-frames", type=int, default=16, help="frames kept around each hit")
    args = parser.parse_args()

    from shuttlesense.io import FrameReader

    match_list = DATA_DIR / "shuttleset" / "match_list.csv"
    if not match_list.exists():
        raise SystemExit("data/shuttleset/match_list.csv missing: run download_shuttleset.py")
    with match_list.open(newline="", encoding="utf-8") as f:
        matches = {row["match_id"]: row for row in csv.DictReader(f)}
    for number in args.matches:
        # By id, not position: download_shuttleset.py leaves out matches it could not fetch.
        match_id = f"m{number:02d}"
        row = matches.get(match_id)
        if row is None:
            print(f"{match_id}: not in match_list.csv, skipped")
            continue
        video = DATA_DIR / "videos" / row["video"]
        if not video.exists():
            print(f"{match_id}: video missing, skipped")
            continue
        strokes = read_strokes(DATA_DIR / "shuttleset" / match_id)
        # source_frames is counted by decoding when the container reports no frame count.
        num_frames = FrameReader(video, target_height=720, max_fps=0).source_frames
        windows, skipped = stroke_windows(strokes, args.pad_frames, num_frames)
        n = cut_clips(video, windows, DATA_DIR / "clips" / match_id, match_id)
        print(f"{match_id}: {n} clips, {skipped} strokes skipped (window crosses a boundary)")


if __name__ == "__main__":
    main()
