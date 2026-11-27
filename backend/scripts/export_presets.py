"""Write the personality presets the app shows to docs/coach-personality/presets.json.

Usage (from backend/): python scripts/export_presets.py [--check]

The app mirrors the registry in shuttlesense/coach/personality/presets.py (labels, icons,
descriptions, attribute vectors and sample replies) but never the prompt fragments, which
stay on the server (D50). Both sides test themselves against this file. --check exits 1 if
the file is out of date instead of writing it.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from shuttlesense.coach.personality.attributes import ORDER
from shuttlesense.coach.personality.presets import PRESETS, PREVIEW_QUESTIONS

OUT = Path(__file__).resolve().parents[2] / "docs" / "coach-personality" / "presets.json"


def export() -> str:
    data = {
        "attributes": list(ORDER),
        "previewQuestions": list(PREVIEW_QUESTIONS),
        "presets": [
            {
                "id": p.id,
                "label": p.label,
                "icon": p.icon,
                "description": p.description,
                "attributes": list(p.attributes),
                "previews": list(p.previews),
            }
            for p in PRESETS
        ],
    }
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    text = export()
    if args.check:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != text:
            print(f"{OUT} is out of date; run python scripts/export_presets.py")
            return 1
        return 0
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
