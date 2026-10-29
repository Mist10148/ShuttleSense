from __future__ import annotations

import csv
import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


@pytest.fixture(scope="module")
def ds():
    spec = importlib.util.spec_from_file_location(
        "download_shuttleset", SCRIPTS / "download_shuttleset.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["download_shuttleset"] = module
    spec.loader.exec_module(module)
    return module


def write_csv(path: Path, rows: list[list]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows(rows)


def test_build_writes_match_list_that_extract_clips_reads(ds, tmp_path: Path) -> None:
    upstream = tmp_path / "set"
    write_csv(
        upstream / "match.csv",
        [
            ["id", "video", "duration", "winner", "loser", "url"],
            ["2", "B_vs_C_Open", "52", "B", "C", "https://youtu.be/b"],
            ["1", "A_vs_B_Final", "83", "A", "B", "https://youtu.be/a"],
            ["3", "Missing_Folder", "40", "D", "E", "https://youtu.be/d"],
        ],
    )
    header = ["rally", "ball_round", "frame_num", "player", "type"]
    write_csv(upstream / "A_vs_B_Final" / "set1.csv", [header, [1, 1, 10, "A", "serve"],
              [1, 2, 30, "B", "clear"], [2, 1, 90, "B", "serve"]])  # fmt: skip
    write_csv(upstream / "A_vs_B_Final" / "set2.csv", [header, [1, 1, 5, "A", "serve"]])
    write_csv(upstream / "B_vs_C_Open" / "set1.csv", [header, [1, 1, 7, "C", "smash"]])

    types = ds.build(upstream, tmp_path / "out")

    assert types == {"serve": 3, "clear": 1, "smash": 1}
    with (tmp_path / "out" / "match_list.csv").open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    assert [r["match_id"] for r in rows] == ["m01", "m02"]  # sorted by id, missing skipped
    first = rows[0]
    assert first["video"] == "A_vs_B_Final.mp4" and first["players"] == "A vs B"
    assert (first["num_rallies"], first["num_strokes"]) == ("3", "4")
    assert sorted(p.name for p in (tmp_path / "out" / "m01").iterdir()) == ["set1.csv", "set2.csv"]
