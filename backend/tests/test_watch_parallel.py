from threading import Barrier

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
