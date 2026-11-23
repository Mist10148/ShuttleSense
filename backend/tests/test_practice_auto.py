from shuttlesense.practice.auto import analyze_strokes
from shuttlesense.schema import ClipRecord, Frame, Hit


def record():
    return ClipRecord(
        clip_id="p",
        mode="practice",
        fps=30,
        width=100,
        height=100,
        num_frames=40,
        frames=[Frame(frame=i) for i in range(40)],
    )


def test_unobserved_hits_are_never_classified(monkeypatch):
    def detect(rec, ctx):
        rec.hits = [Hit(id=1, frame=10, time_s=1 / 3, player="near")]

    monkeypatch.setattr("shuttlesense.practice.auto.hits.run", detect)
    assert analyze_strokes(record(), {}, "cpu", {10}) == []


def test_missing_model_returns_unclassified_candidates(monkeypatch):
    from shuttlesense.stage import StageSkipped

    def detect(rec, ctx):
        rec.hits = [Hit(id=1, frame=10, time_s=1 / 3, player="near")]

    def missing(*args):
        raise StageSkipped("not installed")

    monkeypatch.setattr("shuttlesense.practice.auto.hits.run", detect)
    monkeypatch.setattr("shuttlesense.practice.auto.load_classifier", missing)
    result = analyze_strokes(record(), {}, "cpu", set())
    assert len(result) == 1
    assert result[0]["stroke"] is None
    assert result[0]["confidence"] is None
    assert result[0]["source"] == "automatic"
