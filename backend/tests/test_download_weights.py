from __future__ import annotations

import hashlib
import importlib.util
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


@pytest.fixture()
def dw(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    spec = importlib.util.spec_from_file_location(
        "download_weights", SCRIPTS / "download_weights.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "WEIGHTS_DIR", tmp_path)
    return module


def fake_download(content: bytes):
    def download(_repo: str, name: str, *, local_dir: Path, force_download: bool) -> None:
        path = Path(local_dir) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    return download


def test_checksum_mismatch_raises(dw, tmp_path: Path) -> None:
    dw.CHECKSUMS["strokes/stroke_cnn.pt"] = hashlib.sha256(b"good").hexdigest()
    with pytest.raises(dw.ChecksumError):
        dw.fetch("strokes/stroke_cnn.pt", download=fake_download(b"tampered"))
    assert not (tmp_path / "strokes/stroke_cnn.pt").exists()


def test_checksum_match_and_unpinned(dw) -> None:
    dw.CHECKSUMS["strokes/stroke_cnn.pt"] = hashlib.sha256(b"good").hexdigest()
    assert dw.fetch("strokes/stroke_cnn.pt", download=fake_download(b"good")) == "fetched+verified"
    assert dw.fetch("strokes/stroke_cnn.pt") == "verified"
    del dw.CHECKSUMS["tracknet/TrackNet_best.pt"]
    status = dw.fetch("tracknet/TrackNet_best.pt", download=fake_download(b"x"))
    assert status.startswith("fetched (no checksum")


def test_invalid_tracknet_download_preserves_installed_weights(dw, tmp_path: Path) -> None:
    name = "tracknet/TrackNet_best.pt"
    target = tmp_path / name
    target.parent.mkdir()
    target.write_bytes(b"local checkpoint")

    with pytest.raises(dw.ChecksumError):
        dw.fetch(name)
    with pytest.raises(dw.ChecksumError):
        dw.fetch(name, force=True, download=fake_download(b"tampered"))
    assert target.read_bytes() == b"local checkpoint"
