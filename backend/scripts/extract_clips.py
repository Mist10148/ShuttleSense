"""Cut per-stroke clips from ShuttleSet match videos (T3.1, T3.2).

Usage: python scripts/extract_clips.py --matches 1-22
Output: data/clips/<match_id>/<rally>_<hit>.mp4
"""

from __future__ import annotations

import argparse
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"


def parse_range(text: str) -> list[int]:
    start, _, end = text.partition("-")
    return list(range(int(start), int(end or start) + 1))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matches", type=parse_range, default=parse_range("1-44"))
    parser.add_argument("--pad-frames", type=int, default=16, help="frames kept around each hit")
    args = parser.parse_args()
    # TODO(T3.1/T3.2): read data/shuttleset annotations, cut a window around each stroke
    # from data/videos/<match>.mp4, log the number of clips per match.
    raise SystemExit(f"Not implemented yet. Matches requested: {args.matches}")


if __name__ == "__main__":
    main()
