"""Local, single-client Watch batch benchmark with a fixed TensorRT RTX profile.

Set BENCH_BATCH_FILE and BENCH_CACHE_ROOT to isolated paths before launching. The
cache root must not already exist. This is diagnostic-only, not a production server.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

import uvicorn
from bench_watch_complete import ResourceSampler

import shuttlesense.pose.watch_acceleration as acceleration
from shuttlesense.api.main import create_app

inner = create_app()
choice = Path(os.environ["BENCH_BATCH_FILE"])
cache_root = Path(os.environ["BENCH_CACHE_ROOT"])
cache_root.mkdir(parents=True, exist_ok=False)
original_rtx_session = acceleration._rtx_session
original_fallback_run = acceleration._FallbackSession.run
current = {}
trial = 0


def fixed_profile_session(original, batch_size, is_pose, cache_dir, opt_batch=4):
    if not is_pose:
        return original_rtx_session(original, batch_size, is_pose, cache_dir, opt_batch)
    # Keep min=1, opt=4, max=16 for all tested application batch limits.
    cache = cache_root / f"batch_{current['batch']}"
    existed = cache.exists() and any(cache.iterdir())
    started = time.perf_counter()
    try:
        return original_rtx_session(original, 16, True, cache, 4)
    finally:
        current["rtx_session_init_s"] = round(time.perf_counter() - started, 4)
        current["cache_nonempty_before"] = existed


def observe_first_pose(self, *args, **kwargs):
    if "first_pose_call_ms" in current:
        return original_fallback_run(self, *args, **kwargs)
    started = time.perf_counter()
    try:
        return original_fallback_run(self, *args, **kwargs)
    finally:
        current["first_pose_call_ms"] = round((time.perf_counter() - started) * 1000, 3)
        current["provider_after_first_call"] = dict(self.diagnostic)
        current["provider_final"] = self.diagnostic


acceleration._rtx_session = fixed_profile_session
acceleration._FallbackSession.run = observe_first_pose


async def app(scope, receive, send):
    global trial
    if scope["type"] != "websocket" or scope["path"] != "/watch":
        await inner(scope, receive, send)
        return
    batch = int(choice.read_text(encoding="utf8").strip())
    if batch not in (4, 8, 16):
        raise ValueError("batch must be 4, 8, or 16")
    trial += 1
    current.clear()
    current.update(trial=trial, batch=batch, profile_min=1, profile_opt=4, profile_max=16)
    watch = inner.state.jobs.config.setdefault("watch", {})
    watch.update(pose_batch_size=batch, pose_opt_batch=4, player_provider="pose")
    print("BATCH_BENCH_START " + json.dumps(current), flush=True)
    with ResourceSampler() as sampler:
        try:
            await inner(scope, receive, send)
        finally:
            current["resources"] = sampler.summary()
            print("BATCH_BENCH_END " + json.dumps(current), flush=True)


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8002)
