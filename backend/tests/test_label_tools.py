"""The labelling tools' key handling and files (T7.1, T2.10); the OpenCV windows need a display."""

from __future__ import annotations

from pathlib import Path

from test_eval_scripts import load_script


def test_clip_labels_from_keys_round_trip_into_the_eval_scripts(tmp_path: Path) -> None:
    label_clip = load_script("label_clip")
    labels = label_clip.ClipLabels()
    keys = [
        ("r", 0.2),  # rally starts
        ("6", 0.5),  # near serves (near is the default hitter)
        ("2", 1.1),  # far clears: the hitter alternates
        ("x", 1.3),  # not a labelling key
        ("f", 1.6),
        ("1", 1.7),  # far smashes
        ("h", 2.0),  # near, no class
        ("u", 2.1),  # undo that hit
        ("r", 2.4),  # rally ends
        ("N", 2.5),
        ("o", 2.5),
    ]
    messages = [labels.handle_key(k, t) for k, t in keys]
    assert messages[3] is None and messages[7] == "removed last hit"
    assert [(h["player"], h["stroke"]) for h in labels.hits] == [
        ("near", "serve"), ("far", "clear"), ("far", "smash"),
    ]  # fmt: skip
    assert labels.rallies == [{"start_s": 0.2, "end_s": 2.4, "winner": "near", "in_out": "out"}]

    out = tmp_path / "labels" / "rally01.csv"
    labels.save(out)
    again = label_clip.ClipLabels.load(out)
    assert again.hits == labels.hits and again.rallies == labels.rallies

    eval_phone = load_script("eval_phone")
    hits, rallies = eval_phone.read_labels(out)
    assert [h["stroke"] for h in hits] == ["serve", "clear", "smash"]
    assert rallies == [{"start_s": 0.2, "end_s": 2.4, "winner": "near"}]
    eval_hits = load_script("eval_hits")
    assert eval_hits.read_hit_labels(out, fps=30) == [(15, "near"), (33, "far"), (51, "far")]
    eval_rallies = load_script("eval_rallies")
    assert eval_rallies.read_rally_labels(out)[0]["winner"] == "near"


def test_clip_labels_keep_other_tools_columns(tmp_path: Path) -> None:
    label_clip = load_script("label_clip")
    out = tmp_path / "rally01.csv"
    out.write_text(
        "time_s,player,stroke,start_s,end_s,winner,in_out,landing_x_m,landing_y_m\n"
        "0.500,near,serve,,,,,,\n"
        ",,,0.200,2.400,near,in,2.10,10.05\n",
        encoding="utf-8",
    )
    labels = label_clip.ClipLabels.load(out)
    labels.handle_key("6", 3.0)  # a new hit has no landing columns
    labels.save(out)
    rows = load_script("eval_line_calls").read_labels(out)
    assert rows[0]["landing"] == (2.10, 10.05) and rows[0]["call"] == "in"
    assert out.read_text(encoding="utf-8").splitlines()[2] == "3.000,near,serve,,,,,,"


def test_rally_end_before_start_is_refused() -> None:
    labels = load_script("label_clip").ClipLabels()
    labels.handle_key("r", 3.0)
    assert "after its start" in labels.handle_key("r", 2.0)
    assert labels.rallies == [] and labels.rally_start is None
    assert labels.handle_key("N", 4.0) == "no rally yet"


def test_shuttle_labels_round_trip_into_eval_tracking(tmp_path: Path) -> None:
    label_shuttle = load_script("label_shuttle")
    assert label_shuttle.frames_to_label(start=10, count=3, every=5, total=100) == [10, 15, 20]
    assert label_shuttle.frames_to_label(start=95, count=3, every=5, total=100) == [95]
    assert label_shuttle.to_source((450, 300), scale=0.5) == (900.0, 600.0)

    labels = label_shuttle.ShuttleLabels()
    labels.mark(10, 900.0, 600.0)
    labels.mark_invisible(15)
    labels.mark(20, 5.0, 5.0)
    labels.clear(20)
    out = tmp_path / "rally01_shuttle.csv"
    labels.save(out)
    assert out.read_text(encoding="utf-8").splitlines() == [
        "Frame,Visibility,X,Y", "10,1,900,600", "15,0,0,0",
    ]  # fmt: skip
    assert label_shuttle.ShuttleLabels.load(out).points == labels.points

    track = load_script("eval_tracking").read_track(out, height=1080)
    assert sorted(track) == [10, 15]
