"""Download ShuttleSet annotations and the match list into backend/data/shuttleset/ (T1.9).

Usage: python scripts/download_shuttleset.py [--source path/to/ShuttleSet/set]

Downloads only ShuttleSet/set from SHUTTLESET_REPO (GitHub API + raw files, no git needed),
or reads an existing copy with --source. Writes:
  data/shuttleset/m01 ... m44/set*.csv   per-set stroke annotations (upstream columns)
  data/shuttleset/match_list.csv         match_id, video, video_url, players, duration_min,
                                         num_rallies, num_strokes
and prints the stroke type counts (input for the label mapping, T3.3).

Match videos are not redistributed: download each `video_url` for research use only and
save it as data/videos/<video> (the `video` column). Follow the dataset's terms of use.
"""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import sys
import tempfile
import urllib.request
from collections import Counter
from pathlib import Path
from urllib.parse import quote

DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "shuttleset"
SHUTTLESET_REPO = "https://github.com/wywyWang/CoachAI-Projects"  # ShuttleSet lives here
BRANCH = "main"
SET_FOLDER = "ShuttleSet/set/"
MATCH_LIST_COLUMNS = (
    "match_id",
    "video",
    "video_url",
    "players",
    "duration_min",
    "num_rallies",
    "num_strokes",
)


def fetch_set_folder(dest: Path) -> Path:
    """Download ShuttleSet/set into dest; returns the set folder.

    Uses one GitHub tree API call plus raw file downloads instead of git: other folders in
    the upstream repo have paths with ":", which git cannot check out on Windows.
    """
    owner_repo = SHUTTLESET_REPO.removeprefix("https://github.com/")
    tree_url = f"https://api.github.com/repos/{owner_repo}/git/trees/{BRANCH}?recursive=1"
    with urllib.request.urlopen(tree_url, timeout=60) as res:
        tree = json.load(res)["tree"]
    paths = [t["path"] for t in tree if t["type"] == "blob" and t["path"].startswith(SET_FOLDER)]
    for i, path in enumerate(paths, start=1):
        target = dest / path
        target.parent.mkdir(parents=True, exist_ok=True)
        raw = f"https://raw.githubusercontent.com/{owner_repo}/{BRANCH}/{quote(path)}"
        with urllib.request.urlopen(raw, timeout=60) as res, target.open("wb") as out:
            shutil.copyfileobj(res, out)
        print(f"\rdownloaded {i}/{len(paths)} files", end="", flush=True)
    print()
    return dest / SET_FOLDER


def read_set_rows(match_dir: Path) -> list[dict[str, str]]:
    rows = []
    for path in sorted(match_dir.glob("set*.csv")):
        with path.open(newline="", encoding="utf-8-sig") as f:
            rows.extend({**row, "_set": path.stem} for row in csv.DictReader(f))
    return rows


def build(set_dir: Path, out_dir: Path) -> Counter[str]:
    """Copy the annotations as m01.. folders, write match_list.csv; return stroke type counts."""
    with (set_dir / "match.csv").open(newline="", encoding="utf-8-sig") as f:
        matches = sorted(csv.DictReader(f), key=lambda m: int(m["id"]))
    out_dir.mkdir(parents=True, exist_ok=True)
    types: Counter[str] = Counter()
    listed = []
    for m in matches:
        source = set_dir / m["video"]
        if not source.is_dir():
            print(f"match {m['id']}: folder {m['video']!r} missing, skipped")
            continue
        match_id = f"m{int(m['id']):02d}"
        target = out_dir / match_id
        target.mkdir(exist_ok=True)
        for path in source.glob("set*.csv"):
            shutil.copyfile(path, target / path.name)
        rows = read_set_rows(target)
        types.update(r["type"] for r in rows if r.get("type"))
        listed.append(
            [
                match_id,
                f"{m['video']}.mp4",
                m.get("url", ""),
                f"{m.get('winner', '')} vs {m.get('loser', '')}",
                m.get("duration", ""),
                len({(r["_set"], r["rally"]) for r in rows}),
                len(rows),
            ]
        )
    with (out_dir / "match_list.csv").open("w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows([MATCH_LIST_COLUMNS, *listed])
    return types


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="existing ShuttleSet/set folder (no download)")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        set_dir = args.source or fetch_set_folder(Path(tmp) / "upstream")
        types = build(set_dir, DATA_DIR)
    # ShuttleSet type names are Chinese; a Windows console defaults to a code page without them.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    print(f"wrote {DATA_DIR / 'match_list.csv'}")
    print(f"{sum(types.values())} strokes, {len(types)} types:")
    for name, count in types.most_common():
        print(f"  {count:6d}  {name}")


if __name__ == "__main__":
    main()
