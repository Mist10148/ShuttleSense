from __future__ import annotations

import json
from pathlib import Path

import pytest

from shuttlesense import pipeline
from shuttlesense.pipeline import StageSpec, run_pipeline
from shuttlesense.schema import Shuttle


@pytest.fixture()
def counting_stages(monkeypatch: pytest.MonkeyPatch) -> dict[str, int]:
    """Replace tracking with a counter stage that marks every shuttle visible."""
    calls = {"tracking": 0}

    def fake_tracking(record, ctx):
        calls["tracking"] += 1
        for f in record.frames:
            f.shuttle = Shuttle(x=1.0, y=2.0, visible=1)
        return record

    stages = tuple(
        StageSpec("tracking", fake_tracking) if s.name == "tracking" else s for s in pipeline.STAGES
    )
    monkeypatch.setattr(pipeline, "STAGES", stages)
    return calls


def test_cached_stage_is_skipped(counting_stages, tiny_video: Path, tmp_path: Path) -> None:
    events = []
    run_pipeline(tiny_video, tmp_path, clip_id="c", overlays=["trail"])
    record = run_pipeline(
        tiny_video, tmp_path, clip_id="c", overlays=["boxes"],
        on_event=lambda n, s, p: events.append((n, s)),
    )  # fmt: skip
    assert counting_stages["tracking"] == 1
    assert record.frames[3].shuttle.visible == 1  # restored from the cache
    assert ("tracking", "done") in events and ("tracking", "running") not in events
    assert ("render", "running") in events
    timings = json.loads((tmp_path / "timings.json").read_text())
    assert {"io", "tracking", "render"} <= set(timings)


def test_config_change_invalidates_cache(counting_stages, tiny_video: Path, tmp_path: Path):
    run_pipeline(tiny_video, tmp_path, clip_id="c")
    run_pipeline(tiny_video, tmp_path, clip_id="c", config={"stages": {"tracking": {"x": 1}}})
    assert counting_stages["tracking"] == 2
    run_pipeline(tiny_video, tmp_path, clip_id="c", config={"stages": {"tracking": {"x": 1}}})
    assert counting_stages["tracking"] == 2  # same config again: cache hit
    # Upstream change: a different io config invalidates tracking too.
    run_pipeline(
        tiny_video, tmp_path, clip_id="c",
        config={"stages": {"io": {"max_fps": 20}, "tracking": {"x": 1}}},
    )  # fmt: skip
    assert counting_stages["tracking"] == 3
