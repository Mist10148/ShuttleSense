"""Report what is installed and what is missing for the backend (task T0.11).

Usage: python scripts/check_env.py

Exit code 0 when the base stack (Python, requirements/base.txt) is OK, even if ffmpeg, the
optional ML pieces, weights or the TrackNetV3 submodule are missing.
"""

from __future__ import annotations

import importlib
import importlib.metadata as metadata
import shutil
import subprocess
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
REPO_DIR = BACKEND_DIR.parent
BASE_REQUIREMENTS = BACKEND_DIR / "requirements" / "base.txt"
WEIGHTS_DIR = BACKEND_DIR / "weights"
TRACKNET_DIR = BACKEND_DIR / "third_party" / "TrackNetV3"
MIN_PYTHON = (3, 11)
MIN_FREE_GB = 20

# Distribution name -> import name, where they differ.
IMPORT_NAMES = {
    "opencv-python-headless": "cv2",
    "pyyaml": "yaml",
    "python-multipart": "python_multipart",
    "pydantic-settings": "pydantic_settings",
    "google-genai": "google.genai",
}
OPTIONAL_ML = ("torch", "onnxruntime", "rtmlib", "scipy")

OK, BAD, WARN = "✓", "✗", "!"


def _line(mark: str, text: str) -> None:
    print(f"  {mark} {text}")


def parse_requirements(path: Path) -> list[tuple[str, str | None]]:
    """(distribution, pinned version or None) for each line of a requirements file."""
    pins = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("-"):
            continue
        name, _, version = line.partition("==")
        pins.append((name.split("[", 1)[0].strip().lower(), version.strip() or None))
    return pins


def check_python() -> bool:
    ok = sys.version_info[:2] >= MIN_PYTHON
    want = ".".join(map(str, MIN_PYTHON))
    _line(OK if ok else BAD, f"Python {sys.version.split()[0]} (need >= {want})")
    return ok


def check_base_packages() -> bool:
    ok = True
    for dist, pinned in parse_requirements(BASE_REQUIREMENTS):
        try:
            installed = metadata.version(dist)
            importlib.import_module(IMPORT_NAMES.get(dist, dist.replace("-", "_")))
        except (metadata.PackageNotFoundError, ImportError):
            _line(BAD, f"{dist} not installed (pip install -r requirements/base.txt)")
            ok = False
            continue
        if pinned and installed != pinned:
            _line(WARN, f"{dist} {installed} (pinned {pinned})")
        else:
            _line(OK, f"{dist} {installed}")
    return ok


def check_ffmpeg() -> bool:
    exe = shutil.which("ffmpeg")
    if not exe:
        _line(WARN, "ffmpeg not on PATH (H.264 export falls back to OpenCV mp4v)")
        return True
    try:
        out = subprocess.run(
            [exe, "-version"], capture_output=True, text=True, timeout=10, check=False
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        _line(BAD, f"ffmpeg at {exe} does not run")
        return False
    first = out.splitlines()[0] if out else "ffmpeg"
    mark = OK if "--enable-libx264" in out else WARN
    note = "" if mark == OK else " (no libx264; OpenCV fallback will be used)"
    _line(mark, f"{first}{note}")
    return True


def check_ml() -> None:
    for name in OPTIONAL_ML:
        try:
            module = importlib.import_module(name)
        except ImportError:
            _line(WARN, f"{name} not installed (see docs/SETUP.md for the ML stack)")
            continue
        version = getattr(module, "__version__", "?")
        extra = ""
        if name == "torch":
            extra = " CUDA available" if module.cuda.is_available() else " CPU only"
        elif name == "onnxruntime":
            providers = module.get_available_providers()
            extra = " CUDA available" if "CUDAExecutionProvider" in providers else " CPU only"
        _line(OK, f"{name} {version}{extra}")


def check_weights() -> None:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from download_weights import FILES

    for group, names in FILES.items():
        for name in names:
            path = WEIGHTS_DIR / name
            if path.exists():
                _line(OK, f"weights/{name}")
            else:
                _line(
                    WARN,
                    f"weights/{name} missing (python scripts/download_weights.py --only {group})",
                )


def check_submodule() -> None:
    if (TRACKNET_DIR / ".git").exists() or any(TRACKNET_DIR.glob("*.py")):
        _line(OK, "TrackNetV3 submodule present")
    else:
        _line(WARN, "TrackNetV3 submodule missing (git submodule update --init --recursive)")


def check_disk() -> None:
    free_gb = shutil.disk_usage(BACKEND_DIR).free / 1e9
    mark = OK if free_gb >= MIN_FREE_GB else WARN
    _line(mark, f"{free_gb:.0f} GB free (recommend >= {MIN_FREE_GB} GB)")


def main() -> int:
    print("Base stack")
    ok = check_python()
    ok = check_base_packages() and ok
    ok = check_ffmpeg() and ok
    print("Optional ML stack")
    check_ml()
    print("Weights and models")
    check_weights()
    check_submodule()
    print("Machine")
    check_disk()
    print("Base stack OK" if ok else "Base stack incomplete: fix the ✗ lines above")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
