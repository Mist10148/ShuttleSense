"""Single-client local Flutter experiment; never use for normal serving.

The existing BENCH_DEPTH_FILE harness selects 0 for normal TrackNet or 2 for
an artificial shuttle bypass. The bypass deliberately changes analysis results.
"""

from __future__ import annotations

import os
from pathlib import Path

import uvicorn

from shuttlesense.api.main import create_app
from shuttlesense.schema import Shuttle
from shuttlesense.stream.perception import ModelPerception

inner = create_app()
choice = Path(os.environ["BENCH_DEPTH_FILE"])
original_shuttle = ModelPerception._shuttle
skip_shuttle = False


def measured_shuttle(self, frame):
    return Shuttle() if skip_shuttle else original_shuttle(self, frame)


ModelPerception._shuttle = measured_shuttle


async def app(scope, receive, send):
    global skip_shuttle
    if scope["type"] == "websocket" and scope["path"] == "/watch":
        mode = int(choice.read_text(encoding="utf-8").strip())
        if mode not in (0, 2):
            raise ValueError("benchmark mode must be 0 (normal) or 2 (bypass)")
        skip_shuttle = mode == 2
        print(f"BENCH_TRACKNET_MODE {mode}", flush=True)
    await inner(scope, receive, send)


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8002)
