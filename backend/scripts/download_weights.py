"""Download pretrained weights into backend/weights/ and verify their checksums (task T1.4).

Usage: python scripts/download_weights.py [--only tracknet|strokes] [--force]
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

WEIGHTS_DIR = Path(__file__).resolve().parent.parent / "weights"

# Hugging Face Hub repo holding the team's copies of the checkpoints (task T0.9).
HF_REPO = "shuttlesense/weights"

FILES = {
    "tracknet": ["tracknet/TrackNet_best.pt", "tracknet/InpaintNet_best.pt"],
    "strokes": ["strokes/stroke_cnn.pt"],
}

# SHA-256 of each file. Fill in when the file is uploaded to HF_REPO
# (`sha256sum FILE`, or `certutil -hashfile FILE SHA256` on Windows).
# A missing entry means "not pinned yet": the file is downloaded but not verified.
CHECKSUMS: dict[str, str] = {}


class ChecksumError(RuntimeError):
    pass


def sha256(path: Path, chunk: int = 1 << 20) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        while block := f.read(chunk):
            digest.update(block)
    return digest.hexdigest()


def verify(path: Path, name: str) -> bool:
    """True if verified, False if no checksum is pinned. Deletes the file on mismatch."""
    expected = CHECKSUMS.get(name)
    if expected is None:
        return False
    actual = sha256(path)
    if actual != expected:
        path.unlink(missing_ok=True)
        raise ChecksumError(f"{name}: sha256 {actual} != expected {expected}; file deleted")
    return True


def fetch(name: str, *, force: bool = False, download=None) -> str:
    """Download one file if needed and verify it. Returns a status word for the log."""
    target = WEIGHTS_DIR / name
    if target.exists() and not force:
        return "verified" if verify(target, name) else "exists"
    if download is None:
        from huggingface_hub import hf_hub_download  # requirements/ml.txt

        download = hf_hub_download
    download(HF_REPO, name, local_dir=WEIGHTS_DIR, force_download=force)
    return "fetched+verified" if verify(target, name) else "fetched (no checksum pinned)"


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
