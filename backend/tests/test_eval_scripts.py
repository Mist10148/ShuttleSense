"""Smoke tests for the evaluation and benchmark scripts (T2.9, T2.10, T3.7, T3.13, T6.7, T7.2)."""

from __future__ import annotations

import csv
import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType

import pytest

from shuttlesense.fake import load_golden

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


def load_script(name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def write_csv(path: Path, header: list[str], rows: list[list]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows([header, *rows])
    return path


def test_benchmark_on_cpu_with_skipped_stages(tiny_video: Path, tmp_path: Path) -> None:
    benchmark = load_script("benchmark")
    # No TrackNet weights in tests: tracking skips itself, also on a machine that has the
    # real weights installed. Pose is off to stay fast.
    config = {
        "stages": {
            "pose": {"enabled": False},
            "tracking": {"tracknet_weights": str(tmp_path / "missing.pt")},
        }
    }
    result = benchmark.benchmark(tiny_video, runs=2, config=config, work_dir=tmp_path)
    assert result["runs"] == 2 and result["num_frames"] == 10
    assert "io" in result["stage_median_s"] and "tracking" in result["skipped_stages"]
    assert "pose" not in result["skipped_stages"]  # disabled, not skipped
    assert result["total_median_s"] >= 0 and len(result["raw_timings"]) == 2
    out = tmp_path / "results" / "benchmark.md"
    benchmark.write_report(result, out)
    assert "| io |" in out.read_text(encoding="utf-8")
    assert json.loads(out.with_suffix(".json").read_text())["runs"] == 2


def test_benchmark_times_court_and_referee_with_corners(tiny_video: Path, tmp_path: Path) -> None:
    benchmark = load_script("benchmark")
    config = {"stages": {"pose": {"enabled": False}}}
    corners = [[20, 80], [140, 80], [120, 20], [40, 20]]
    result = benchmark.benchmark(
        tiny_video, runs=1, config=config, work_dir=tmp_path, corners=corners, referee=True
    )
    assert {"court", "referee"} <= set(result["stage_median_s"])


def test_benchmark_rejects_unknown_stage(monkeypatch: pytest.MonkeyPatch, tiny_video: Path):
    benchmark = load_script("benchmark")
    argv = ["benchmark.py", "--video", str(tiny_video), "--disable", "posee"]
    monkeypatch.setattr("sys.argv", argv)
    with pytest.raises(SystemExit, match="unknown stage 'posee'"):
        benchmark.main()


def test_aggregate_takes_medians() -> None:
    benchmark = load_script("benchmark")
    runs = [{"io": 1.0, "render": 4.0}, {"io": 3.0, "render": 2.0}, {"io": 2.0}]
    agg = benchmark.aggregate(runs, num_frames=60)
    assert agg["stage_median_s"] == {"io": 2.0, "render": 3.0}
    assert agg["total_median_s"] == 5.0 and agg["fps"] == 12.0  # totals 5, 5, 2


def test_eval_tracking_scales_and_scores_labelled_frames(tmp_path: Path) -> None:
    eval_tracking = load_script("eval_tracking")
    # GT labelled at 1080p (x1.5), every other source frame kept (step 2); frame 6 unlabelled.
    gt = write_csv(tmp_path / "gt.csv", ["Frame", "Visibility", "X", "Y"],
                   [[0, 1, 15, 15], [2, 1, 30, 30], [4, 0, 0, 0], [8, 1, 60, 60]])  # fmt: skip
    pred = write_csv(tmp_path / "tracking.csv", ["frame", "visible", "x", "y", "source"],
                     [[0, 1, 12, 11, "tracknet"], [1, 1, 30, 20, "tracknet"],
                      [2, 0, 0, 0, ""], [3, 1, 5, 5, ""]])  # fmt: skip
    truth = eval_tracking.read_track(gt, step=2, height=1080)
    assert sorted(truth) == [0, 1, 2, 4] and truth[1] == (1, 20.0, 20.0)
    m = eval_tracking.evaluate(eval_tracking.read_track(pred), truth, tolerance_px=4)
    assert m["frames"] == 4 and m["accuracy"] == 0.5  # frames 0 and 2 are right
    assert m["precision"] == 0.5 and m["recall"] == pytest.approx(1 / 3)
    out = tmp_path / "tracking.md"
    eval_tracking.write_report(
        {"results": {"raw": m}}, eval_tracking.to_markdown({"raw": m}, 4), out
    )
    assert "| raw | 4 | 3 | 0.500 |" in out.read_text(encoding="utf-8")


def test_eval_hits_on_golden_record(tmp_path: Path) -> None:
    eval_hits = load_script("eval_hits")
    record = load_golden()
    # Labels in seconds (T7.1 style) with a rally row mixed in; one hit shifted by 2 frames,
    # one with the wrong player, one extra labelled hit that is never predicted.
    gt = write_csv(tmp_path / "labels.csv", ["time_s", "player", "stroke", "start_s", "end_s"],
                   [[5 / 30, "near", "serve", "", ""], [27 / 30, "near", "clear", "", ""],
                    [45 / 30, "near", "smash", "", ""], [55 / 30, "far", "lift", "", ""],
                    ["", "", "", 0, 1.8]])  # fmt: skip
    truth = eval_hits.read_hit_labels(gt, record.fps)
    assert truth == [(5, "near"), (27, "near"), (45, "near"), (55, "far")]
    result = eval_hits.pooled_metrics([(eval_hits.recorded_hits(record), truth)], tolerance=3)
    assert result["matched"] == 3 and result["precision"] == 1.0 and result["recall"] == 0.75
    assert result["player_accuracy"] == pytest.approx(2 / 3)
    out = tmp_path / "hits.md"
    eval_hits.write_report(result, eval_hits.to_markdown(result, ["golden"], 3), out)
    assert "| golden | 3 | 4 | 3 |" in out.read_text(encoding="utf-8")

    # ShuttleSet-style labels: source frames at 2x fps and A/B players (no player accuracy).
    ss = write_csv(tmp_path / "set1.csv", ["rally", "ball_round", "frame_num", "player", "type"],
                   [[1, 1, 10, "A", "short service"], [1, 2, 50, "B", "clear"]])  # fmt: skip
    ss_truth = eval_hits.read_hit_labels(ss, record.fps, step=2)
    assert ss_truth == [(5, ""), (25, "")]
    assert eval_hits.pooled_metrics([([(5, "near")], ss_truth)], 3)["player_accuracy"] is None
    # A clip cut from the match at source frame 40: earlier labels fall outside the record.
    clipped = eval_hits.read_hit_labels(ss, record.fps, step=2, offset=40)
    assert clipped == [(-15, ""), (5, "")]
    assert eval_hits.in_record(record, clipped) == [(5, "")]


def test_eval_hits_grid_search_logs_every_combination(tmp_path: Path) -> None:
    eval_hits = load_script("eval_hits")
    record = load_golden()
    truth = eval_hits.recorded_hits(record)
    grid = {"min_angle_deg": [45, 60], "max_wrist_distance_px": [120],
            "min_frames_between_hits": [8]}  # fmt: skip
    rows = eval_hits.grid_search([(record, truth)], {}, grid, tolerance=3)
    assert len(rows) == 2 and rows[0]["f1"] >= rows[1]["f1"]
    log = tmp_path / "hits_tuning.csv"
    eval_hits.append_tuning_log(log, rows, "val")
    eval_hits.append_tuning_log(log, rows[:1], "val")
    lines = list(csv.DictReader(log.open(encoding="utf-8")))
    assert len(lines) == 3 and lines[0]["tag"] == "val" and lines[0]["min_angle_deg"]


def test_dataset_stats_counts_and_flags(tmp_path: Path) -> None:
    dataset_stats = load_script("dataset_stats")
    clips, shuttleset = tmp_path / "clips", tmp_path / "shuttleset"
    header = ["clip", "match_id", "set", "rally", "stroke_no", "hit_frame_in_clip", "player",
              "shuttleset_type", "fps"]  # fmt: skip
    for match_id, types in {
        "m1": ["smash", "clear", "drive"],
        "m2": ["lob", "smash", "??"],
    }.items():
        rows = [[f"1_1_{i}.mp4", match_id, 1, 1, i, 16, "A" if i % 2 else "B", t, "30.000"]
                for i, t in enumerate(types)]  # fmt: skip
        write_csv(clips / match_id / "index.csv", header, rows)
        (clips / match_id / "1_1_0.mp4").write_bytes(b"")  # the other clips are "missing"
        write_csv(shuttleset / match_id / "set1.csv", ["rally", "type"], [[1, "x"]] * 5)
    stats = dataset_stats.collect(clips, {"train": ["m1"], "val": ["m2"]}, shuttleset)
    assert stats["by_split"] == {"train": {"smash": 1, "clear": 1}, "val": {"lift": 1, "smash": 1}}
    assert stats["excluded"] == {"drive": 1} and stats["unknown"] == {"??": 1}
    assert stats["by_player"]["m1:B"] == {"smash": 1}
    assert stats["extraction"]["m1"] == {"annotated": 5, "indexed": 3, "not_extracted": 2,
                                         "missing_files": 2}  # fmt: skip
    assert dataset_stats.low_classes(stats, 1) == ["drop", "net_shot", "lift", "serve"]
    out = tmp_path / "dataset.md"
    dataset_stats.write_report(stats, dataset_stats.to_markdown(stats, 500), out)
    text = out.read_text(encoding="utf-8")
    assert "Fewer than 500 training samples" in text and "| m1 | 5 | 3 | 2 | 2 |" in text


def test_eval_rallies_boundaries_and_score(tmp_path: Path) -> None:
    eval_rallies = load_script("eval_rallies")
    record = load_golden()  # one rally, frames 0-55 at 30 fps, won by near, score 1-0
    pred_path = tmp_path / "record.json"
    pred_path.write_text(record.model_dump_json(), encoding="utf-8")
    gt = write_csv(tmp_path / "rally01.csv",
                   ["time_s", "player", "stroke", "start_s", "end_s", "winner", "in_out"],
                   [[0.2, "near", "serve", "", "", "", ""], ["", "", "", 0.5, 2.5, "near", "in"],
                    ["", "", "", 5.0, 9.0, "far", "out"]])  # fmt: skip
    truth = eval_rallies.read_rally_labels(gt)
    assert [t["winner"] for t in truth] == ["near", "far"]
    predicted = eval_rallies.read_predicted(pred_path)
    result = eval_rallies.evaluate_clip(predicted, truth, tolerance_s=1.0)
    assert result["boundary_accuracy"] == 0.5 and result["winner_accuracy"] == 1.0
    assert result["score_sequence_true"] == [[1, 0], [1, 1]]
    assert result["final_score_true"] == [1, 1] and result["final_score_pred"] == [1, 0]
    # rallies.csv (UTF-8 with BOM, as exported) reads the same.
    csv_path = tmp_path / "rallies.csv"
    csv_path.write_text("index,start_s,end_s,winner,score_near,score_far\n0,0.0,1.833,near,1,0\n",
                        encoding="utf-8-sig")  # fmt: skip
    assert eval_rallies.read_predicted(csv_path)[0]["score"] == [1, 0]
    results = {"rally01": result}
    out = tmp_path / "rallies.md"
    md = eval_rallies.to_markdown(results, 1.0, eval_rallies.pooled(results))
    eval_rallies.write_report({"clips": results}, md, out)
    assert "| rally01 | 2 | 1 | 1 | 50.0% | 100.0% | 1-1 / 1-0 |" in out.read_text(encoding="utf-8")


def test_eval_phone_scores_hits_strokes_counts_and_rallies(tmp_path: Path) -> None:
    eval_phone = load_script("eval_phone")
    record = load_golden()  # hits: 5 near serve, 25 far clear, 45 near smash; rally 0-55
    gt = write_csv(tmp_path / "labels" / "rally01.csv",
                   ["time_s", "player", "stroke", "start_s", "end_s", "winner"],
                   [[5 / 30, "near", "serve", "", "", ""],
                    [26 / 30, "far", "clear", "", "", ""],  # 1 frame off: still matched
                    [45 / 30, "near", "drop", "", "", ""],  # matched, wrong stroke
                    [52 / 30, "far", "", "", "", ""],  # missed by the detector, no stroke
                    ["", "", "", 0.0, 1.8, "near"]])  # fmt: skip
    hits, rallies = eval_phone.read_labels(gt)
    assert len(hits) == 4 and hits[3]["stroke"] is None and rallies[0]["winner"] == "near"
    result = eval_phone.evaluate_clip(record, hits, rallies)
    assert result["tolerance_frames"] == 3
    assert result["hits"]["matched"] == 3 and result["hits"]["recall"] == pytest.approx(0.75)
    assert result["stroke"]["accuracy"] == pytest.approx(2 / 3)
    assert result["stroke"]["confusion"]["drop->smash"] == 1
    assert result["count_error"]["per_rally"] == [1]
    assert result["rallies"]["boundary_accuracy"] == 1.0

    overall = eval_phone.pooled({"rally01": result})
    assert overall["stroke_accuracy"] == pytest.approx(2 / 3)
    assert overall["count_error_mean"] == 1.0 and overall["boundary_accuracy"] == 1.0
    out = tmp_path / "results" / "phone.md"
    eval_phone.write_report(overall, eval_phone.to_markdown({"rally01": result}, overall), out)
    assert "| rally01 | 3 / 4 |" in out.read_text(encoding="utf-8")


def test_bench_strokes_times_a_random_model_on_cpu(tmp_path: Path) -> None:
    pytest.importorskip("torch")
    bench = load_script("bench_strokes")
    record = bench.synthetic_record(duration_s=10, hits_per_min=60)
    assert record.num_frames == 300 and len(record.hits) == 10
    assert [f.frame for f in record.frames[:3]] == [0, 1, 2]
    assert {h.player for h in record.hits} == {"near", "far"}
    timing = bench.time_device(record, "cpu", runs=2)
    assert timing["device"] == "cpu" and timing["median_s"] > 0 and timing["load_s"] is None
    assert bench.available_devices(["cpu", "tpu"]) == ["cpu"]
    text = bench.to_markdown(
        {"model": "random", "hits": 10, "duration_s": 10.0, "devices": [timing]}
    )
    assert "| cpu |" in text and "< 30 s" in text


def test_eval_line_calls_counts_certain_calls_and_near_line(tmp_path: Path) -> None:
    eval_line_calls = load_script("eval_line_calls")
    from shuttlesense.config import load_config
    from shuttlesense.stream.analyzer import StreamAnalyzer
    from shuttlesense.stream.synthetic import synthetic_record

    # The synthetic clip: rally 0 lands IN, rally 1 OUT, rally 2 just inside (UNCERTAIN).
    clip, _ = synthetic_record()
    a = StreamAnalyzer(clip_id="c", fps=clip.fps, width=clip.width, height=clip.height,
                       court=clip.court, config=load_config())  # fmt: skip
    for f in clip.frames:
        a.add_frame(f.shuttle, f.players)
    pred = tmp_path / "record.json"
    pred.write_text(a.finalize().model_dump_json(), encoding="utf-8")
    header = ["start_s", "end_s", "winner", "in_out", "landing_x_m", "landing_y_m"]
    rows = [
        [0.0, 2.1, "near", "in", 2.0, 10.0],
        [4.4, 6.8, "near", "in", 5.10, 3.0],
        [9.1, 10.9, "", "in", 5.15, 10.5],
        [20.0, 22.0, "", "out", "", ""],
    ]
    gt = write_csv(tmp_path / "rally01.csv", header, rows)
    result = eval_line_calls.evaluate(
        eval_line_calls.read_predicted(pred), eval_line_calls.read_labels(gt)
    )
    # Rally 1 was labelled IN on purpose: the automated OUT call is a false call near the line.
    assert result["labelled"] == 4 and result["called"] == 3 and result["certain"] == 2
    assert result["precision_in"] == 1.0 and result["recall_in"] == 0.5
    assert result["precision_out"] == 0.0 and result["uncertain_share"] == 1 / 3
    near = result["near_line"]
    assert near["basis"] == "labelled landing" and near["certain_calls"] == 1
    assert near["false_call_rate"] == 1.0
    md = eval_line_calls.to_markdown({"rally01": result}, result,
                                     type("A", (), {"tolerance": 1.0})())  # fmt: skip
    assert "| rally01 | 4 | 3 | 2 |" in md
    empty = eval_line_calls.summarize([], 20)
    assert "no accuracy is reported" in eval_line_calls.to_markdown({}, empty, None)


def test_near_line_keeps_calls_without_a_labelled_landing() -> None:
    summarize = load_script("eval_line_calls").summarize
    rows = [
        {"label": "in", "call": "in", "uncertain": False, "margin_cm_pred": 10.0,
         "margin_cm_true": None},
        {"label": "in", "call": "out", "uncertain": False, "margin_cm_pred": -5.0,
         "margin_cm_true": 3.0},
    ]  # fmt: skip
    near = summarize(rows, 20)["near_line"]
    assert near["certain_calls"] == 2 and near["false_call_rate"] == 0.5
    assert near["basis"] == "labelled landing (1) and predicted margin (1)"


def test_shuttleset_lose_reason_gives_labels(tmp_path: Path) -> None:
    eval_line_calls = load_script("eval_line_calls")
    gt = write_csv(tmp_path / "set1.csv", ["rally", "ball_round", "frame_num", "lose_reason"],
                   [[1, 1, 30, ""], [1, 2, 90, "出界"], [2, 1, 300, ""], [2, 2, 360, "掛網"],
                    [3, 1, 600, "對手落地致勝"]])  # fmt: skip
    rallies = eval_line_calls.read_shuttleset(gt, fps=30)
    assert [(r["start_s"], r["end_s"], r["call"]) for r in rallies] == [
        (1.0, 3.0, "out"), (10.0, 12.0, None), (20.0, 20.0, "in"),
    ]  # fmt: skip


def test_shuttleset_landing_pixels_become_court_meters(tmp_path: Path) -> None:
    """T8.12: with a calibrated record the landing pixel is projected onto the court."""
    import numpy as np

    from shuttlesense.court.homography import court_to_image
    from shuttlesense.fake import load_golden

    eval_line_calls = load_script("eval_line_calls")
    record = load_golden()
    assert record.court is not None
    pred = tmp_path / "record.json"
    pred.write_text(record.model_dump_json(), encoding="utf-8")
    # A landing 3 m across and 1 m up the court, annotated on a frame twice the record's size.
    px = court_to_image(np.asarray(record.court.homography), np.array([[3.0, 1.0]]))[0]
    size = (record.width * 2, record.height * 2)
    gt = write_csv(tmp_path / "set1.csv",
                   ["rally", "ball_round", "frame_num", "landing_x", "landing_y", "lose_reason"],
                   [[1, 1, 30, 10, 10, ""], [1, 2, 90, px[0] * 2, px[1] * 2, "出界"]])  # fmt: skip
    mapper = eval_line_calls.court_mapper(pred, size)
    landing = eval_line_calls.read_shuttleset(gt, 30, mapper)[0]["landing"]
    assert landing == pytest.approx((3.0, 1.0), abs=0.01)
    assert eval_line_calls.read_shuttleset(gt, 30)[0]["landing"] is None
    record.court = None
    pred.write_text(record.model_dump_json(), encoding="utf-8")
    assert eval_line_calls.court_mapper(pred) is None


def test_shuttleset_landing_at_the_horizon_is_dropped(tmp_path: Path, monkeypatch) -> None:
    """A pixel the homography sends to infinity has no landing (JSON cannot hold NaN)."""
    import numpy as np

    from shuttlesense.fake import load_golden

    eval_line_calls = load_script("eval_line_calls")
    pred = tmp_path / "record.json"
    pred.write_text(load_golden().model_dump_json(), encoding="utf-8")
    monkeypatch.setattr(eval_line_calls, "image_to_court",
                        lambda h, pts: np.array([[np.inf, np.nan]]))  # fmt: skip
    assert eval_line_calls.court_mapper(pred)(10.0, 10.0) is None


def test_shuttleset_rallies_match_on_their_start(tmp_path: Path) -> None:
    """ShuttleSet ends at the last stroke, a predicted rally at the landing: match the start."""
    eval_line_calls = load_script("eval_line_calls")
    truth = [{"start_s": 1.0, "end_s": 3.0, "call": "out", "landing": None},
             {"start_s": 20.0, "end_s": 25.0, "call": "in", "landing": None}]  # fmt: skip
    predicted = [{"start_s": 1.2, "end_s": 4.6, "call": "out", "uncertain": False,
                  "margin_cm": -30.0, "court": "singles", "bounds": None}]  # fmt: skip
    by_both = eval_line_calls.evaluate(predicted, truth)
    assert by_both["called"] == 0 and by_both["unmatched"] == 2
    by_start = eval_line_calls.evaluate(predicted, truth, match_end=False)
    assert by_start["called"] == 1 and by_start["unmatched"] == 1
    assert by_start["accuracy_certain"] == 1.0


def test_eval_doubles_scores_hitters_service_and_slot_jumps(tmp_path: Path) -> None:
    """T9.12 on the doubles golden record with labels written by label_clip.py."""
    import argparse

    from shuttlesense.fake import load_golden

    label_clip = load_script("label_clip")
    eval_doubles = load_script("eval_doubles")
    record = load_golden("doubles")
    fps = record.fps
    labels = label_clip.ClipLabels()
    # Hits at the golden frames 5 (near_1), 25 (far_1), 45: labelled near_1, so the record's
    # near_2 is wrong there.
    for frame, keys in ((5, "na6"), (25, "fa2"), (45, "na1")):
        for key in keys[:-1]:
            labels.handle_key(key, frame / fps)
        labels.handle_key(keys[-1], frame / fps)
    labels.handle_key("r", 0.0)
    labels.handle_key("r", 55 / fps)
    out = tmp_path / "doubles.csv"
    labels.save(out)
    rows = out.read_text(encoding="utf-8").splitlines()
    assert rows[0].endswith(",server,receiver") and rows[-1].endswith(",near_1,far_1")
    args = argparse.Namespace(tolerance=3, rally_tolerance=1.0, max_step_m=1.5)
    result = eval_doubles.evaluate(record, out, args)
    assert result["matched_hits"] == 3 and result["hitter_named"] == 3
    assert result["hitter_accuracy"] == 2 / 3 and result["hitter_unknown_rate"] == 0
    assert result["matched_rallies"] == 1 and result["service_accuracy"] == 1.0
    assert result["slot_steps"] > 0 and result["slot_jumps"] == 0
    assert "| golden_doubles | 3 | 66.7% |" in eval_doubles.markdown([result])


def test_speed_report_on_the_golden_record(tmp_path: Path) -> None:
    """T10.5: one row per stroke class with a speed, Markdown + JSON, and a box plot."""
    import json

    from shuttlesense.fake import load_golden

    speed_report = load_script("speed_report")
    record = load_golden()
    record.hits[0].speed_kmh = None  # a hit without a speed is left out
    record.hits[1].stroke = None
    path = tmp_path / "record.json"
    path.write_text(record.model_dump_json(), encoding="utf-8")
    speeds = speed_report.speeds_by_class([path])
    rows = speed_report.summarize(speeds)
    assert [(r["stroke"], r["hits"], r["median_kmh"]) for r in rows] == [
        ("smash", 1, 241.0), ("unlabelled", 1, 118.0),
    ]  # fmt: skip
    md = speed_report.to_markdown(rows, ["record.json"])
    assert "| smash | 1 | 241.0 |" in md
    assert "No hit had a speed" in speed_report.to_markdown([], [])
    assert speed_report._percentile([10.0, 20.0, 30.0, 40.0], 0.5) == 25.0
    out = tmp_path / "speed.md"
    png = tmp_path / "speed.png"
    import sys
    from unittest import mock

    # The box plot needs matplotlib (requirements/ml.txt), which CI does not install.
    plot = importlib.util.find_spec("matplotlib") is not None
    argv = ["speed_report.py", str(path), "--out", str(out)] + (
        ["--plot", str(png)] if plot else []
    )
    with mock.patch.object(sys, "argv", argv):
        speed_report.main()
    assert json.loads(out.with_suffix(".json").read_text(encoding="utf-8"))["rows"] == rows
    assert not plot or png.stat().st_size > 0


def test_check_links_finds_missing_files_and_headings(tmp_path: Path) -> None:
    links = load_script("check_links")
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "b.md").write_text(
        '# Title\n\n## Stroke models (D28)\n\n<a id="t111"></a>\n', encoding="utf-8"
    )
    (tmp_path / "a.md").write_text(
        "[ok](docs/b.md) [ok](docs/b.md#stroke-models-d28) [ok](docs/b.md#t111) [self](#top)\n"
        "# Top\n"
        "[web](https://example.com/x.md) `[code](missing.md)`\n"
        "```\n[fenced](missing.md)\n```\n"
        "[gone](docs/c.md) and [bad](docs/b.md#nope)\n",
        encoding="utf-8",
    )
    problems = links.check(tmp_path)
    assert len(problems) == 2
    assert "a.md:7: docs/c.md (file not found)" in problems[0]
    assert "docs/b.md#nope (no such heading)" in problems[1]
    assert links.slug("Phase 11 — Selectable stroke models") == "phase-11--selectable-stroke-models"


def test_box_labels_give_id_switches_and_idf1(tmp_path: Path) -> None:
    """T9.2 box labels (label_clip.py --boxes) and T9.12 ID switches and IDF1."""
    import argparse

    from shuttlesense.fake import load_golden
    from shuttlesense.schema import slot_attr

    label_clip = load_script("label_clip")
    eval_doubles = load_script("eval_doubles")
    record = load_golden("doubles")
    boxes = label_clip.BoxLabels(fps=record.fps)
    assert boxes.frames_to_label(60, 10) == [0, 10, 20, 30, 40, 50]
    for frame in range(0, 60, 10):
        players = record.frames[frame].players
        for slot in label_clip.SLOTS:
            box = getattr(players, slot_attr(slot)).bbox
            # From frame 30 on the labeller says the two near partners swapped boxes.
            if frame >= 30 and slot.startswith("near"):
                other = "near_2" if slot == "near_1" else "near_1"
                box = getattr(players, slot_attr(other)).bbox
            boxes.set(frame, slot, tuple(box))
    boxes.set(50, "far_2", None)  # not in view: left out of the counts
    path = tmp_path / "doubles_boxes.csv"
    boxes.save(path)
    again = label_clip.BoxLabels.load(path, record.fps)
    assert again.boxes == boxes.boxes and again.frames_to_label(60, 10) == []

    rallies = [{"start_s": 0.0, "end_s": 55 / record.fps}]
    metrics = eval_doubles.identity_metrics(record, eval_doubles.read_boxes(path), rallies)
    assert metrics["box_frames"] == 6 and metrics["labelled_boxes"] == 23
    assert metrics["id_switches"] == 2 and metrics["id_switches_per_rally"] == 2.0
    # Best fixed assignment: 17 of 23 labelled boxes; 24 tracked boxes on those frames.
    assert metrics["idf1"] == pytest.approx(2 * 17 / (2 * 17 + 7 + 6))

    labels = tmp_path / "doubles.csv"
    label_clip.ClipLabels().save(labels)
    args = argparse.Namespace(tolerance=3, rally_tolerance=1.0, max_step_m=1.5, min_iou=0.5)
    assert eval_doubles.evaluate(record, labels, args)["idf1"] is None
    assert eval_doubles.evaluate(record, labels, args, path)["id_switches"] == 2
