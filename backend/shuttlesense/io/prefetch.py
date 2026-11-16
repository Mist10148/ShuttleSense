"""Bounded decoded-frame prefetch for opt-in Watch sessions.

The worker owns and closes the source iterator. It may decode ahead but does not
perform inference or commit a frame.
"""
from __future__ import annotations

import queue
import threading
from collections.abc import Callable, Iterator
from typing import Any


class PrefetchFrames:
    def __init__(self, source: Callable[[], Iterator[Any]], depth: int = 2):
        if depth < 1:
            raise ValueError("prefetch depth must be positive")
        self._source = source
        self._items: queue.Queue[tuple[str, Any]] = queue.Queue(maxsize=depth)
        # Acquire before decoding, so queued plus currently decoding never exceed depth.
        self._slots = threading.BoundedSemaphore(depth)
        self._stop = threading.Event()
        self._finished = False
        self._thread = threading.Thread(target=self._produce, daemon=True)
        self._thread.start()

    def _produce(self):
        iterator = None
        try:
            try:
                iterator = iter(self._source())
            except Exception as exc:
                if not self._stop.is_set():
                    self._slots.acquire()
                    self._items.put_nowait(("error", exc))
                return
            while not self._stop.is_set():
                if not self._slots.acquire(timeout=0.05):
                    continue
                if self._stop.is_set():
                    self._slots.release()
                    break
                try:
                    item = ("frame", next(iterator))
                except StopIteration:
                    item = ("end", None)
                except Exception as exc:
                    item = ("error", exc)
                self._items.put_nowait(item)
                if item[0] != "frame":
                    break
        finally:
            close = getattr(iterator, "close", None)
            if close is not None:
                close()

    def __iter__(self):
        return self

    def __next__(self):
        if self._finished:
            raise StopIteration
        kind, item = self._items.get()
        self._slots.release()
        if kind == "end":
            self._finished = True
            raise StopIteration
        if kind == "error":
            self._finished = True
            raise item
        return item

    def close(self):
        self._stop.set()
        self._thread.join()
        self._finished = True
