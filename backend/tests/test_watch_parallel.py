from threading import Barrier

import pytest

from shuttlesense.stream.watch_parallel import ParallelWatchPerception


def test_parallel_watch_waits_for_both_models():
    class Perception:
        available = {"tracking": True, "pose": True}
        barrier = Barrier(2, timeout=2)

        def _shuttle(self, frame):
            self.barrier.wait()
            return ("shuttle", frame)

        def _players(self, frame):
            self.barrier.wait()
            return ("players", frame)

    parallel = ParallelWatchPerception(Perception())
    try:
        assert parallel("frame", 4) == (("shuttle", "frame"), ("players", "frame"))
        assert parallel.available == {"tracking": True, "pose": True}
    finally:
        parallel.close()


def test_parallel_watch_auto_uses_cuda_and_respects_explicit_override():
    from shuttlesense.api.watch_background import _parallel_watch_enabled

    assert _parallel_watch_enabled("auto", "cuda:0")
    assert not _parallel_watch_enabled("auto", "cpu")
    assert not _parallel_watch_enabled(False, "cuda")
    assert _parallel_watch_enabled(True, "cpu")


def test_parallel_cleanup_waits_for_other_model_after_failure():
    from threading import Event

    class Models:
        available = {"tracking": True, "pose": True}
        finished = Event()

        def _shuttle(self, _frame):
            raise RuntimeError("tracking failed")

        def _players(self, _frame):
            self.finished.set()
            return None

    models = Models()
    parallel = ParallelWatchPerception(models)
    try:
        with pytest.raises(RuntimeError, match="tracking failed"):
            parallel(None, 0)
    finally:
        parallel.close()
    assert models.finished.is_set()


@pytest.mark.parametrize("failing", ["shuttle", "players"])
def test_parallel_propagates_either_worker_error_and_closes(failing):
    class Models:
        available = {"tracking": True, "pose": True}

        def _shuttle(self, _frame):
            if failing == "shuttle":
                raise ValueError("shuttle failure")
            return "ok"

        def _players(self, _frame):
            if failing == "players":
                raise ValueError("players failure")
            return "ok"

    parallel = ParallelWatchPerception(Models())
    try:
        with pytest.raises(ValueError, match=f"{failing} failure"):
            parallel(None, 0)
    finally:
        parallel.close()
    with pytest.raises(RuntimeError, match="shutdown"):
        parallel(None, 1)


def test_close_waits_for_an_inflight_frame():
    from threading import Event, Thread

    started, release, returned = Event(), Event(), Event()

    class Models:
        available = {"tracking": True, "pose": True}

        def _shuttle(self, _frame):
            started.set()
            assert release.wait(3)
            return "shuttle"

        def _players(self, _frame):
            return "players"

    parallel = ParallelWatchPerception(Models())
    results = []
    caller = Thread(target=lambda: results.append(parallel(None, 0)))
    closer = Thread(target=lambda: (parallel.close(), returned.set()))
    try:
        caller.start()
        assert started.wait(3)
        closer.start()
        assert not returned.wait(0.05)
    finally:
        release.set()
        caller.join(3)
        if closer.ident is not None:
            closer.join(3)
        else:
            parallel.close()
    assert not caller.is_alive() and not closer.is_alive()
    assert returned.is_set() and results == [("shuttle", "players")]


def test_closing_one_session_does_not_close_another():
    class Models:
        available = {"tracking": True, "pose": True}

        def __init__(self, name):
            self.name = name

        def _shuttle(self, frame):
            return self.name, frame

        def _players(self, frame):
            return self.name, frame

    first = ParallelWatchPerception(Models("first"))
    second = ParallelWatchPerception(Models("second"))
    try:
        assert first(1, 0) == (("first", 1), ("first", 1))
        first.close()
        assert second(2, 0) == (("second", 2), ("second", 2))
    finally:
        first.close()
        second.close()
