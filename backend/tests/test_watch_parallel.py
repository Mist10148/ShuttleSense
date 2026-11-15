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
