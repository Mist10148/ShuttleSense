"""Download pretrained weights into backend/weights/ (task T1.4).

Usage: python scripts/download_weights.py [--only tracknet|strokes]
"""

from __future__ import annotations

import argparse
from pathlib import Path

WEIGHTS_DIR = Path(__file__).resolve().parent.parent / "weights"

# Hugging Face Hub repo holding the team's copies of the checkpoints (task T0.9).
HF_REPO = "shuttlesense/weights"

FILES = {
    "tracknet": ["tracknet/TrackNet_best.pt", "tracknet/InpaintNet_best.pt"],
    "strokes": ["strokes/stroke_cnn.pt"],
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", choices=sorted(FILES), help="download one group only")
    args = parser.parse_args()

    from huggingface_hub import hf_hub_download  # requirements/ml.txt

    groups = [args.only] if args.only else list(FILES)
    for group in groups:
        for name in FILES[group]:
            target = WEIGHTS_DIR / name
            if target.exists():
                print(f"exists   {name}")
                continue
            # TODO(T1.4): verify checksums after download.
            hf_hub_download(HF_REPO, name, local_dir=WEIGHTS_DIR)
            print(f"fetched  {name}")


if __name__ == "__main__":
    main()
