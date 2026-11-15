"""Optional watch-only concurrent perception; the caller processes one frame at a time."""

from concurrent.futures import ThreadPoolExecutor


class ParallelWatchPerception:
    def __init__(self, perception):
        self.perception = perception
        self.available = perception.available
        self.pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="watch-perception")

    def __call__(self, frame, index):
        shuttle = self.pool.submit(self.perception._shuttle, frame)
        players = self.pool.submit(self.perception._players, frame)
        return shuttle.result(), players.result()

    def close(self):
        self.pool.shutdown(wait=True)
