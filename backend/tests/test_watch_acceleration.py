from types import SimpleNamespace

from shuttlesense.pose import watch_acceleration


class Session:
    def __init__(self, result=None, fail=False):
        self.result, self.fail, self.calls = result, fail, 0

    def run(self, *args, **kwargs):
        self.calls += 1
        if self.fail:
            raise RuntimeError("inference failed")
        return self.result


def test_failed_inference_retries_cuda_and_stays_on_cuda():
    fast, cuda = Session(fail=True), Session(result=[123])
    diagnostic = {"active": "tensorrt_rtx"}
    session = watch_acceleration._FallbackSession(fast, cuda, diagnostic)
    assert session.run(None, {}) == [123]
    assert session.run(None, {}) == [123]
    assert fast.calls == 1 and cuda.calls == 2
    assert diagnostic["active"] == "cuda"
    assert "inference failed" in diagnostic["fallback_reason"]


def test_provider_sessions_do_not_mutate_shared_models(monkeypatch):
    detector, pose = SimpleNamespace(session=Session()), SimpleNamespace(session=Session())
    shared = SimpleNamespace(det_model=detector, pose_model=pose)
    monkeypatch.setattr(watch_acceleration, "_rtx_session",
                        lambda *args: (Session(result=[1]), [{"provider": "test"}]))
    clone, info = watch_acceleration.make_watch_body(shared, "pose", 8, "cuda")
    assert clone is not shared and clone.pose_model is not pose
    assert clone.det_model.session is detector.session
    assert isinstance(clone.pose_model.session, watch_acceleration._FallbackSession)
    assert pose.session is clone.pose_model.session.fallback
    assert info["models"]["pose"]["active"] == "tensorrt_rtx"
    assert info["models"]["detector"]["active"] == "cuda"


def test_initialization_failure_retains_original_session(monkeypatch):
    def fail(*args):
        raise RuntimeError("engine failed")
    monkeypatch.setattr(watch_acceleration, "_rtx_session", fail)
    body = SimpleNamespace(det_model=SimpleNamespace(session=Session()),
                           pose_model=SimpleNamespace(session=Session()))
    clone, info = watch_acceleration.make_watch_body(body, "both", 8, "cuda")
    assert clone.det_model.session is body.det_model.session
    assert clone.pose_model.session is body.pose_model.session
    assert all(x["active"] == "cuda" for x in info["models"].values())


def test_cpu_fallback_is_not_reported_as_cuda():
    body = SimpleNamespace(det_model=SimpleNamespace(session=Session()),
                           pose_model=SimpleNamespace(session=Session()))
    _, info = watch_acceleration.make_watch_body(body, "pose", 8, "cpu")
    assert info["models"]["detector"]["active"] == "cpu"
    assert info["models"]["pose"]["active"] == "cpu"
    assert "fallback_reason" in info["models"]["pose"]
