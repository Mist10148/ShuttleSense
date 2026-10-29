"""Snapshot helper: compare a JSON-able value with a committed file.

Run `UPDATE_SNAPSHOTS=1 pytest` to rewrite the files after an intended change.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any


def assert_matches_snapshot(value: Any, path: Path) -> None:
    text = json.dumps(value, indent=2, sort_keys=True) + "\n"
    if os.environ.get("UPDATE_SNAPSHOTS") == "1" or not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
    expected = path.read_text(encoding="utf-8")
    assert json.loads(text) == json.loads(expected), (
        f"{path.name} is out of date. If the change is intended, run UPDATE_SNAPSHOTS=1 pytest "
        "and update the docs and Dart models in the same PR."
    )
