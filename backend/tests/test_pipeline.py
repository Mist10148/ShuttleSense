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


def test_display_only_keys_keep_the_cache(counting_stages, tiny_video: Path, tmp_path: Path):
    run_pipeline(tiny_video, tmp_path, clip_id="c")
    display = {"tracking": {"trail_length": 15, "weight": 9}, "hits": {"marker_duration_s": 2}}
    run_pipeline(tiny_video, tmp_path, clip_id="c", config={"stages": display})
    assert counting_stages["tracking"] == 1


def test_pose_key_includes_court_block() -> None:
    from shuttlesense import cache

    singles = {"court": {"court_size_m": [5.18, 13.4]}}
    doubles = {"court": {"court_size_m": [6.1, 13.4]}}
    assert cache.key_config("pose", singles) != cache.key_config("pose", doubles)
    assert cache.key_config("tracking", singles) == cache.key_config("tracking", doubles)


def test_referee_cache_keeps_line_calls_and_events(tmp_path: Path) -> None:
    """A re-render that hits the referee cache must not drop line calls (and their overrides)."""
    from shuttlesense import cache
    from shuttlesense.schema import ClipRecord

    golden = Path(__file__).parent / "fixtures" / "golden_record.json"
    record = ClipRecord.model_validate_json(golden.read_text(encoding="utf-8"))
    assert record.line_calls and record.rally_events
    cache.save(tmp_path, "referee", "k", record)
    empty = record.model_copy(update={"line_calls": [], "rally_events": [], "rallies": []})
    restored = cache.load(tmp_path, "referee", "k", empty)
    assert restored is not None
    assert restored.line_calls == record.line_calls
    assert restored.rally_events == record.rally_events


def test_file_changed_in_place_invalidates_cache(
    counting_stages, tiny_video: Path, tmp_path: Path
) -> None:
    import os

    csv_path = tmp_path / "track.csv"
    csv_path.write_text("Frame,Visibility,X,Y\n", encoding="utf-8")
    config = {"stages": {"tracking": {"precomputed_csv": str(csv_path)}}}
    out = tmp_path / "out"
    run_pipeline(tiny_video, out, clip_id="c", config=config)
    run_pipeline(tiny_video, out, clip_id="c", config=config)
    assert counting_stages["tracking"] == 1
    # Same path, new content (e.g. predict.py run again into the same CSV).
    csv_path.write_text("Frame,Visibility,X,Y\n0,1,5,5\n", encoding="utf-8")
    stat = csv_path.stat()
    os.utime(csv_path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000))
    run_pipeline(tiny_video, out, clip_id="c", config=config)
    assert counting_stages["tracking"] == 2


def test_health_tracking_requires_submodule_or_precomputed_csv(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from shuttlesense.tracking import tracknet

    weights = tmp_path / "track.pt"
    weights.write_bytes(b"weight fixture")
    submodule = tmp_path / "TrackNetV3"
    monkeypatch.setattr(tracknet, "TRACKNET_DIR", submodule)
    monkeypatch.setattr(pipeline, "_installed", lambda _module: True)
    config = {"stages": {"tracking": {"tracknet_weights": str(weights)}}}
    assert "tracking" not in pipeline.available_stages(config)
    submodule.mkdir()
    (submodule / "model.py").write_text("# fixture")
    assert "tracking" in pipeline.available_stages(config)
    (submodule / "model.py").unlink()
    csv_path = tmp_path / "tracking.csv"
    csv_path.write_text("Frame,Visibility,X,Y\n")
    config["stages"]["tracking"]["precomputed_csv"] = str(csv_path)
    assert "tracking" in pipeline.available_stages(config)


def test_stage_that_becomes_available_reruns_downstream(
    monkeypatch: pytest.MonkeyPatch, tiny_video: Path, tmp_path: Path
) -> None:
    from shuttlesense.stage import StageSkipped

    weights = tmp_path / "stroke.pt"
    calls = {"strokes": 0, "feedback": 0}

    def strokes(record, ctx):
        calls["strokes"] += 1
        if not weights.exists():
            raise StageSkipped("no weights")
        return record

    def feedback(record, ctx):
        calls["feedback"] += 1
        return record

    replace = {
        "strokes": StageSpec("strokes", strokes, weights=("weights",)),
        "feedback": StageSpec("feedback", feedback),
    }
    monkeypatch.setattr(pipeline, "STAGES", tuple(replace.get(s.name, s) for s in pipeline.STAGES))
    config = {"stages": {"strokes": {"weights": str(weights)}}}
    out = tmp_path / "out"
    events = []

    run_pipeline(tiny_video, out, clip_id="c", config=config)
    run_pipeline(
        tiny_video, out, clip_id="c", config=config, on_event=lambda n, s, p: events.append((n, s))
    )
    assert calls == {"strokes": 1, "feedback": 1}  # the skip itself is cached
    assert ("strokes", "skipped") in events

    weights.write_bytes(b"trained")
    run_pipeline(tiny_video, out, clip_id="c", config=config)
    assert calls == {"strokes": 2, "feedback": 2}  # strokes runs, so feedback is redone


def test_a_failed_cache_write_keeps_the_old_file(tmp_path: Path, monkeypatch) -> None:
    from shuttlesense import atomic, cache

    cache.save_skipped(tmp_path, "referee", "old")
    path = cache.cache_path(tmp_path, "referee")
    before = path.read_text(encoding="utf-8")

    def fail(src: Path, dst: Path, **_: float) -> None:
        raise OSError("disk full")

    monkeypatch.setattr(atomic, "replace", fail)
    with pytest.raises(OSError):
        cache.save_skipped(tmp_path, "referee", "new")
    assert path.read_text(encoding="utf-8") == before
    assert [p.name for p in path.parent.iterdir()] == [path.name]  # no temp file left
    assert cache.is_skipped(tmp_path, "referee", "old")
