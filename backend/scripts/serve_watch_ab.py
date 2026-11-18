"""Local-only Watch benchmark server; not for normal serving or shared use.

Read BENCH_DEPTH_FILE on each /watch connection and set the experimental queue depth.
Run only one Watch session at a time, and use a separate SHUTTLESENSE_STORAGE_DIR.
"""

from __future__ import annotations

import os
from pathlib import Path

import uvicorn

from shuttlesense.api.main import create_app

inner = create_app()
choice = Path(os.environ["BENCH_DEPTH_FILE"])


async def app(scope, receive, send):
    if scope["type"] == "websocket" and scope["path"] == "/watch":
        depth = int(choice.read_text(encoding="utf-8").strip())
        if depth not in (0, 2):
            raise ValueError("benchmark queue depth must be 0 or 2")
        inner.state.jobs.config.setdefault("watch", {})["frame_prefetch_depth"] = depth
        print(f"BENCH_QUEUE_DEPTH {depth}", flush=True)
    await inner(scope, receive, send)


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8002)
