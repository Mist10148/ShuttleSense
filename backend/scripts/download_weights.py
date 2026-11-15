"""Download pretrained weights into backend/weights/ and verify their checksums (task T1.4).

Usage: python scripts/download_weights.py [--only tracknet|strokes] [--force]

The three stroke models (CNN, LSTM, Random Forest) are committed under weights/strokes/
(D30), so for them this only checks the files against the pinned checksums. A stroke file
that differs is reported and kept: it is most likely a model you retrained.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
from tempfile import TemporaryDirectory

WEIGHTS_DIR = Path(__file__).resolve().parent.parent / "weights"

# Hugging Face Hub repo holding the team's copies of the checkpoints (task T0.9).
HF_REPO = "shuttlesense/weights"

FILES = {
    "tracknet": ["tracknet/TrackNet_best.pt", "tracknet/InpaintNet_best.pt"],
    "strokes": ["strokes/stroke_cnn.pt", "strokes/stroke_lstm.pt", "strokes/stroke_rf.npz"],
}
# Committed with the repo (D30): checked, never downloaded or deleted.
IN_REPO = frozenset(FILES["strokes"])

# TrackNetV3 hashes are from the public ckpts archive linked in the pinned submodule.
# The stroke entries are the files trained on Nov 14 (docs/results/strokes.md).
CHECKSUMS: dict[str, str] = {
    "tracknet/TrackNet_best.pt": "df867641a02712b021f04548ff4b1208ddfdb47f629ab2094ceb978667e83b1a",
    "tracknet/InpaintNet_best.pt": (
        "5749b66b8002f3ad9e0af841604004706fc796df30599e6bf01952696009688c"
    ),
    "strokes/stroke_cnn.pt": "c9176cc6780f0f390888454ae70064303a61379e9d69ec2e5b3d8c07578cb6c3",
    "strokes/stroke_lstm.pt": "58e0eba4c6208280c0e3624032146f530044c9e50e639e4225020aafd6e2eb2e",
    "strokes/stroke_rf.npz": "e773350e92e2000cdb43578c3b19dd0c39696431f54e213788f8847b72420782",
}


class ChecksumError(RuntimeError):
    pass


def sha256(path: Path, chunk: int = 1 << 20) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        while block := f.read(chunk):
            digest.update(block)
    return digest.hexdigest()


def verify(path: Path, name: str) -> bool:
    """True if verified, False if no checksum is pinned. Raises on mismatch."""
    expected = CHECKSUMS.get(name)
    if expected is None:
        return False
    actual = sha256(path)
    if actual != expected:
        raise ChecksumError(f"{name}: sha256 {actual} != expected {expected} for {path.name}")
    return True


def fetch(name: str, *, force: bool = False, download=None) -> str:
    """Download one file if needed and verify it. Returns a status word for the log."""
    target = WEIGHTS_DIR / name
    if name in IN_REPO and download is None:
        if not target.exists():
            return "missing: restore it with git, or train it (docs/SETUP.md)"
        if CHECKSUMS.get(name) in (None, sha256(target)):
            return "verified" if name in CHECKSUMS else "exists"
        return "differs from the committed file (retrained?)"
    if target.exists() and not force:
        return "verified" if verify(target, name) else "exists"
    if download is None:
        from huggingface_hub import hf_hub_download  # requirements/ml.txt

        download = hf_hub_download
    target.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=target.parent) as staging:
        local_dir = Path(staging)
        download(HF_REPO, name, local_dir=local_dir, force_download=force)
        downloaded = local_dir / name
        verified = verify(downloaded, name)
        downloaded.replace(target)
    return "fetched+verified" if verified else "fetched (no checksum pinned)"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", choices=sorted(FILES), help="download one group only")
    parser.add_argument("--force", action="store_true", help="re-download existing files")
    args = parser.parse_args()

    groups = [args.only] if args.only else list(FILES)
    for group in groups:
        for name in FILES[group]:
            print(f"{fetch(name, force=args.force):<28} {name}")


if __name__ == "__main__":
    main()
