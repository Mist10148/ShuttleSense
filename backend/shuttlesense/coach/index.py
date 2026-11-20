"""Retrieval for the RAG coach (D42): chunking, BM25, embeddings and rank fusion.

The knowledge base is the Markdown in coach/knowledge/, split at `##` headings into chunks
with ids like `kb:footwork#split-step`. Retrieval is hybrid: a pure-Python BM25 ranking and,
when the provider has embeddings, a cosine ranking, merged by reciprocal-rank fusion.
Knowledge embeddings are cached in <storage_dir>/coach_index.npz per chunk content hash, so
editing one file re-embeds only its changed chunks. Without a provider, or when embedding
fails, retrieval is BM25 only.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import math
import re
import time
from collections import Counter, OrderedDict
from collections.abc import Sequence
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

if TYPE_CHECKING:
    from shuttlesense.coach.llm import LLMProvider

log = logging.getLogger(__name__)

MAX_CHARS = 800
OVERLAP = 120
RRF_K = 60
RETRY_S = 300.0  # wait this long before embedding the knowledge base again

_WORD = re.compile(r"[a-z0-9]+")
_STOP = """a an and are as at be but by can do does for from how i if in into is it its me my
of on or so than that the their them then there these they this to was we were what when
where which who why will with you your"""
STOPWORDS = frozenset(_STOP.split())


@dataclass(frozen=True)
class Chunk:
    id: str  # kb:footwork#split-step, session:rally-3, history:trends...
    title: str
    text: str

    @property
    def content_hash(self) -> str:
        return hashlib.sha256(f"{self.id}\n{self.title}\n{self.text}".encode()).hexdigest()[:24]


def tokenize(text: str) -> list[str]:
    out = []
    for tok in _WORD.findall(text.lower().replace("_", " ")):
        if tok in STOPWORDS:
            continue
        # A crude stemmer: smashes/smash, lunging/lunge, clears/clear.
        for suffix in ("ing", "es", "s"):
            if len(tok) > len(suffix) + 3 and tok.endswith(suffix):
                tok = tok[: -len(suffix)]
                break
        out.append(tok)
    return out


def slugify(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def _split(text: str, max_chars: int = MAX_CHARS, overlap: int = OVERLAP) -> list[str]:
    """Paragraph-then-sentence packing into pieces of at most ~max_chars, with overlap."""
    if len(text) <= max_chars:
        return [text]
    units: list[str] = []
    for para in re.split(r"\n\s*\n", text):
        if len(para) <= max_chars:
            units.append(para)
        else:
            units += re.split(r"(?<=[.!?])\s+", para)
    pieces: list[str] = []
    current = ""
    for unit in units:
        if current and len(current) + len(unit) + 1 > max_chars:
            pieces.append(current)
            tail = current[-overlap:]
            current = tail[tail.find(" ") + 1 :] if " " in tail else ""
        current = f"{current} {unit}".strip() if current else unit
    if current:
        pieces.append(current)
    return pieces


def chunk_markdown(source: str, markdown: str, max_chars: int = MAX_CHARS) -> list[Chunk]:
    """One chunk per `##` section (longer ones split with overlap); ids kb:<source>#<slug>."""
    lines = markdown.strip().splitlines()
    doc_title = source
    if lines and lines[0].startswith("# "):
        doc_title = lines.pop(0)[2:].strip()
    sections: list[tuple[str, list[str]]] = [("", [])]
    for line in lines:
        if line.startswith("## "):
            sections.append((line[3:].strip(), []))
        else:
            sections[-1][1].append(line)
    chunks: list[Chunk] = []
    for heading, body in sections:
        text = "\n".join(body).strip()
        if not text:
            continue
        slug = slugify(heading) or "intro"
        title = f"{doc_title}: {heading}" if heading else doc_title
        for i, piece in enumerate(_split(text, max_chars)):
            cid = f"kb:{source}#{slug}" + (f"-{i + 1}" if i else "")
            chunks.append(Chunk(cid, title, piece))
    return chunks


def load_knowledge() -> list[Chunk]:
    """Every chunk of the packaged knowledge base, in file then heading order."""
    folder = resources.files("shuttlesense.coach") / "knowledge"
    chunks: list[Chunk] = []
    for entry in sorted(folder.iterdir(), key=lambda e: e.name):
        if entry.name.endswith(".md"):
            chunks += chunk_markdown(entry.name[:-3], entry.read_text(encoding="utf-8"))
    return chunks


class BM25:
    def __init__(self, docs: Sequence[Chunk], k1: float = 1.5, b: float = 0.75) -> None:
        self.k1, self.b = k1, b
        self.tfs = [Counter(tokenize(f"{d.title} {d.text}")) for d in docs]
        self.lengths = [sum(tf.values()) for tf in self.tfs]
        self.avg = (sum(self.lengths) / len(self.lengths)) if self.lengths else 0.0
        df: Counter[str] = Counter()
        for tf in self.tfs:
            df.update(tf.keys())
        n = len(docs)
        self.idf = {t: math.log(1 + (n - f + 0.5) / (f + 0.5)) for t, f in df.items()}

    def scores(self, query: str) -> list[float]:
        terms = tokenize(query)
        out = []
        for tf, length in zip(self.tfs, self.lengths, strict=True):
            s = 0.0
            norm = self.k1 * (1 - self.b + self.b * length / (self.avg or 1.0))
            for t in terms:
                f = tf.get(t)
                if f:
                    s += self.idf[t] * f * (self.k1 + 1) / (f + norm)
            out.append(s)
        return out

    def rank(self, query: str) -> list[int]:
        """Indices of documents with a positive score, best first."""
        scores = self.scores(query)
        return [i for i in sorted(range(len(scores)), key=lambda i: -scores[i]) if scores[i] > 0]


def cosine_rank(matrix: np.ndarray, query: Sequence[float], min_score: float = 0.0) -> list[int]:
    if matrix.size == 0:
        return []
    q = np.asarray(query, dtype=np.float32)
    q = q / (np.linalg.norm(q) or 1.0)
    norms = np.linalg.norm(matrix, axis=1)
    norms[norms == 0] = 1.0
    sims = (matrix @ q) / norms
    order = np.argsort(-sims, kind="stable")
    return [int(i) for i in order if sims[i] > min_score]


def rrf(rankings: Sequence[Sequence[int]], k: int = RRF_K) -> list[int]:
    """Reciprocal-rank fusion: sum of 1/(k + rank) over rankings; ties keep first-seen order."""
    scores: dict[int, float] = {}
    for ranking in rankings:
        for rank, idx in enumerate(ranking):
            scores[idx] = scores.get(idx, 0.0) + 1.0 / (k + rank + 1)
    return sorted(scores, key=lambda i: -scores[i])


class EmbeddingCache:
    """Vectors by content hash, persisted to an .npz (knowledge) or kept in memory (LRU)."""

    def __init__(self, path: Path | None = None, max_items: int = 4096) -> None:
        self.path, self.max_items = path, max_items
        self.vectors: OrderedDict[str, np.ndarray] = OrderedDict()
        self.model: str | None = None
        if path is not None and path.exists():
            try:
                with np.load(path, allow_pickle=False) as data:
                    self.model = str(data["model"])
                    for h, v in zip(data["hashes"], data["vectors"], strict=True):
                        self.vectors[str(h)] = v
            except (OSError, ValueError, KeyError) as exc:
                log.warning("ignoring unreadable coach index %s: %s", path, exc)
                self.vectors.clear()

    def use_model(self, model: str) -> None:
        if self.model != model:  # vectors of another model are not comparable
            self.vectors.clear()
            self.model = model

    def get(self, key: str) -> np.ndarray | None:
        v = self.vectors.get(key)
        if v is not None:
            self.vectors.move_to_end(key)
        return v

    def put(self, key: str, vector: Sequence[float]) -> None:
        self.vectors[key] = np.asarray(vector, dtype=np.float32)
        self.vectors.move_to_end(key)
        while len(self.vectors) > self.max_items:
            self.vectors.popitem(last=False)

    def keep_only(self, keys: set[str]) -> None:
        for k in [k for k in self.vectors if k not in keys]:
            del self.vectors[k]

    def save(self) -> None:
        if self.path is None or not self.vectors:
            return
        from shuttlesense.atomic import atomic_open

        self.path.parent.mkdir(parents=True, exist_ok=True)
        with atomic_open(self.path, "wb") as f:
            np.savez(
                f,
                model=np.array(self.model or ""),
                hashes=np.array(list(self.vectors)),
                vectors=np.stack(list(self.vectors.values())),
            )


async def embed_chunks(
    chunks: Sequence[Chunk], provider: LLMProvider, cache: EmbeddingCache
) -> np.ndarray | None:
    """A matrix of document vectors, embedding only chunks missing from the cache.

    None when the provider has no embeddings or the call fails (BM25 only then).
    """
    if not chunks or provider is None or not provider.embed_model:
        return None
    cache.use_model(provider.embed_model)
    missing = [c for c in chunks if cache.get(c.content_hash) is None]
    if missing:
        try:
            vectors = await provider.embed([f"{c.title}\n{c.text}" for c in missing], "document")
        except Exception as exc:  # noqa: BLE001 - retrieval falls back to BM25
            log.warning("coach embeddings unavailable, BM25 only: %s", exc)
            return None
        for c, v in zip(missing, vectors, strict=True):
            cache.put(c.content_hash, v)
    rows = [cache.get(c.content_hash) for c in chunks]
    if any(r is None for r in rows):
        return None
    return np.stack(rows)  # type: ignore[arg-type]


def hybrid_rank(
    chunks: Sequence[Chunk], query: str, matrix: np.ndarray | None, qvec: list[float] | None
) -> list[int]:
    bm25 = BM25(chunks).rank(query)
    if matrix is None or qvec is None:
        return bm25
    return rrf([bm25, cosine_rank(matrix, qvec)])


class Retriever:
    """Knowledge index plus per-request ranking of session and history documents."""

    def __init__(
        self,
        provider: LLMProvider | None,
        cache_path: Path | None = None,
        knowledge: list[Chunk] | None = None,
    ) -> None:
        self.provider = provider
        self.knowledge = knowledge if knowledge is not None else load_knowledge()
        self.by_id = {c.id: c for c in self.knowledge}
        self.kb_cache = EmbeddingCache(cache_path)
        self.doc_cache = EmbeddingCache(None, max_items=2048)  # session and history docs
        self.kb_matrix: np.ndarray | None = None
        self._kb_ready = False
        self._kb_failed_at: float | None = None  # embedding failed: BM25 only for a while
        self._lock = asyncio.Lock()

    async def _knowledge_matrix(self) -> np.ndarray | None:
        if self._kb_ready or self.provider is None or not self.provider.embed_model:
            return self.kb_matrix
        if self._kb_failed_at is not None and time.monotonic() - self._kb_failed_at < RETRY_S:
            return None
        async with self._lock:
            if not self._kb_ready:
                before = dict.fromkeys(self.kb_cache.vectors)
                matrix = await embed_chunks(self.knowledge, self.provider, self.kb_cache)
                if matrix is not None:
                    self.kb_cache.keep_only({c.content_hash for c in self.knowledge})
                    if set(self.kb_cache.vectors) != set(before):
                        try:
                            self.kb_cache.save()
                        except OSError as exc:
                            log.warning("could not save the coach index: %s", exc)
                    self.kb_matrix = matrix
                    self._kb_ready = True
                else:
                    self._kb_failed_at = time.monotonic()
        return self.kb_matrix

    async def query_vector(self, query: str) -> list[float] | None:
        if self.provider is None or not self.provider.embed_model:
            return None
        try:
            return (await self.provider.embed([query], "query"))[0]
        except Exception as exc:  # noqa: BLE001
            log.warning("query embedding failed, BM25 only: %s", exc)
            return None

    async def search_knowledge(
        self, query: str, k: int, qvec: list[float] | None = None
    ) -> list[Chunk]:
        matrix = await self._knowledge_matrix() if qvec is not None else None
        order = hybrid_rank(self.knowledge, query, matrix, qvec)
        return [self.knowledge[i] for i in order[:k]]

    async def search_docs(
        self, docs: Sequence[Chunk], query: str, k: int, qvec: list[float] | None = None
    ) -> list[Chunk]:
        """Rank small per-request documents; their vectors stay in an in-memory LRU."""
        if not docs:
            return []
        matrix = None
        if qvec is not None and self.provider is not None:
            matrix = await embed_chunks(docs, self.provider, self.doc_cache)
        order = hybrid_rank(docs, query, matrix, qvec)
        return [docs[i] for i in order[:k]]
