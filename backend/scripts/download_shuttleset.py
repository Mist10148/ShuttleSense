"""Download ShuttleSet annotations and the match list into backend/data/shuttleset/ (T1.9).

Match videos are not redistributed; follow the dataset's terms of use.
Usage: python scripts/download_shuttleset.py
"""

from __future__ import annotations

from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "shuttleset"
SHUTTLESET_REPO = "https://github.com/wywyWang/CoachAI-Projects"  # ShuttleSet lives here


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    # TODO(T1.9): fetch the ShuttleSet folder (sparse checkout or archive) from SHUTTLESET_REPO,
    # write match_list.csv with match id, video URL, duration and number of rallies.
    raise SystemExit(f"Not implemented yet (T1.9). Target folder: {DATA_DIR}")


if __name__ == "__main__":
    main()
