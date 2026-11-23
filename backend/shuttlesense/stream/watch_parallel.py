"""Optional watch-only concurrent perception; the caller processes one frame at a time."""

from concurrent.futures import ThreadPoolExecutor


def parallel_watch_enabled(setting, device: str) -> bool:
    """Auto mode uses concurrent models only for CUDA; booleans remain overrides."""
    return setting is True or (setting == "auto" and str(device).startswith("cuda"))


class ParallelWatchPerception:
    def __init__(self, perception):
        self.perception = perception
        self.available = perception.available
        self.pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="watch-perception")

    def __call__(self, frame, index):
        shuttle = self.pool.submit(self.perception._shuttle, frame)
        selected = getattr(self.perception, "players_for_frame", None)
        players = (
            self.pool.submit(selected, frame, index)
            if selected
            else self.pool.submit(self.perception._players, frame)
        )
        return shuttle.result(), players.result()

    @property
    def unobserved(self):
        return getattr(self.perception, "unobserved", set())

    @property
    def player_hold_safe(self):
        return getattr(self.perception, "player_hold_safe", None)

    def close(self):
        self.pool.shutdown(wait=True)
        close = getattr(self.perception, "close", None)
        if close:
            close()
