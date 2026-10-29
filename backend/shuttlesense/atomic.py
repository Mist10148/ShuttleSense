"""Write files so readers never see them half-written: write a temp file, then replace."""

from __future__ import annotations

import os
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import IO, Any


def partial_path(path: Path) -> Path:
    """Temp name next to `path` that keeps its suffix (ffmpeg picks the container from it)."""
    return path.with_name(f".{path.stem}.partial{path.suffix}")


def replace(src: Path, dst: Path, *, attempts: int = 20, delay_s: float = 0.1) -> None:
    """os.replace, retried briefly: on Windows it fails while a reader still has dst open."""
    for attempt in range(attempts):
        try:
            os.replace(src, dst)
            return
        except PermissionError:
            if attempt == attempts - 1:
                raise
            time.sleep(delay_s)


@contextmanager
def atomic_open(path: Path, mode: str = "w", **kwargs: Any) -> Iterator[IO[Any]]:
    """open() for writing; the file appears at `path` only once the block has finished."""
    path = Path(path)
    tmp = partial_path(path)
    try:
        with tmp.open(mode, **kwargs) as f:
            yield f
        replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def atomic_write_text(path: Path, text: str, encoding: str = "utf-8") -> None:
    with atomic_open(path, "w", encoding=encoding, newline="") as f:
        f.write(text)
