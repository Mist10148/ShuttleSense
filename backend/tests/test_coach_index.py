"""Coach retrieval: chunking, BM25, rank fusion and the embedding cache."""

from __future__ import annotations

import asyncio
from pathlib import Path

import numpy as np

from shuttlesense.coach.index import (
    BM25,
    MAX_CHARS,
    Chunk,
    EmbeddingCache,
    Retriever,
    chunk_markdown,
    cosine_rank,
    load_knowledge,
    rrf,
)
from shuttlesense.coach.llm import FakeProvider


def test_markdown_is_chunked_by_heading_with_source_ids() -> None:
    long = " ".join(f"Sentence number {i} about lunges." for i in range(80))
    chunks = chunk_markdown(
        "footwork", f"# Footwork\n\nIntro text.\n\n## Split step\nHop.\n\n## Long one\n{long}"
    )
    ids = [c.id for c in chunks]
    assert ids[:2] == ["kb:footwork#intro", "kb:footwork#split-step"]
    assert ids[2] == "kb:footwork#long-one" and ids[3] == "kb:footwork#long-one-2"
    assert chunks[1].title == "Footwork: Split step"
    assert all(len(c.text) <= MAX_CHARS for c in chunks)
    # Consecutive pieces overlap, so a sentence cut at the edge is still found.
    assert chunks[2].text[-40:].split()[-1] in chunks[3].text[:200]


def test_knowledge_base_is_packaged_and_covers_the_topics() -> None:
    chunks = load_knowledge()
    sources = {c.id.split("#")[0] for c in chunks}
    assert {"kb:rules", "kb:footwork", "kb:drills", "kb:safety", "kb:doubles_tactics"} <= sources
    assert len(sources) >= 8 and len({c.id for c in chunks}) == len(chunks)
    assert all(c.text.strip() and len(c.text) <= MAX_CHARS for c in chunks)


def test_bm25_ranks_the_relevant_chunk_first() -> None:
    chunks = load_knowledge()
    bm25 = BM25(chunks)
    top = lambda q: chunks[bm25.rank(q)[0]].id  # noqa: E731
    assert top("When should I do my split step?") == "kb:footwork#split-step"
    assert top("what happens at 29-all in scoring") == "kb:rules#scoring-system"
    assert top("lunge knee drill") in ("kb:drills#lunge-ladder", "kb:net_and_midcourt#lunge")
    assert bm25.rank("zzzz qqqq") == []


def test_rrf_rewards_agreement() -> None:
    fused = rrf([[3, 1, 2], [1, 3]])
    assert set(fused[:2]) == {1, 3} and fused[-1] == 2
    assert rrf([[5], [7, 5]])[0] == 5  # in both lists beats first in one


def test_cosine_rank() -> None:
    m = np.array([[1, 0], [0, 1], [0.7, 0.7]], dtype=np.float32)
    assert cosine_rank(m, [1, 0.1])[0] == 0
    assert cosine_rank(m, [-1, -1]) == []


def test_cache_re_embeds_only_changed_chunks(tmp_path: Path) -> None:
    path = tmp_path / "coach_index.npz"
    kb = [Chunk("kb:a#x", "A", "smash power"), Chunk("kb:b#y", "B", "serve rules")]
    fake = FakeProvider()
    r = Retriever(fake, path, knowledge=kb)
    hits = asyncio.run(r.search_knowledge("smash", 2, asyncio.run(r.query_vector("smash"))))
    assert hits[0].id == "kb:a#x" and path.exists()
    docs_embedded = [t for t, task in fake.embed_calls if task == "document"]
    assert [len(t) for t in docs_embedded] == [2]

    # A new process: same chunks are read from the cache, one edited chunk is embedded.
    fake2 = FakeProvider()
    kb2 = [kb[0], Chunk("kb:b#y", "B", "serve rules, edited")]
    r2 = Retriever(fake2, path, knowledge=kb2)
    asyncio.run(r2.search_knowledge("serve", 2, asyncio.run(r2.query_vector("serve"))))
    docs_embedded = [t for t, task in fake2.embed_calls if task == "document"]
    assert docs_embedded == [["B\nserve rules, edited"]]
    assert len(EmbeddingCache(path).vectors) == 2  # the stale vector was dropped

    # Another embedding model: everything is embedded again.
    fake3 = FakeProvider(embed_model="other")
    r3 = Retriever(fake3, path, knowledge=kb2)
    asyncio.run(r3.search_knowledge("serve", 2, asyncio.run(r3.query_vector("serve"))))
    assert [len(t) for t, task in fake3.embed_calls if task == "document"] == [2]


def test_bm25_only_without_embeddings(tmp_path: Path) -> None:
    kb = [Chunk("kb:a#x", "A", "smash power"), Chunk("kb:b#y", "B", "serve rules")]
    no_embed = FakeProvider(embed_model=None)
    r = Retriever(no_embed, tmp_path / "i.npz", knowledge=kb)
    assert asyncio.run(r.query_vector("serve")) is None
    assert [c.id for c in asyncio.run(r.search_knowledge("serve", 1))] == ["kb:b#y"]
    assert not (tmp_path / "i.npz").exists()

    class Broken(FakeProvider):
        async def embed(self, texts, task):
            raise RuntimeError("offline")

    r = Retriever(Broken(), tmp_path / "i.npz", knowledge=kb)
    assert asyncio.run(r.query_vector("serve")) is None
    hits = asyncio.run(r.search_knowledge("serve", 1, qvec=[1.0] * 64))
    assert [c.id for c in hits] == ["kb:b#y"]
    r0 = Retriever(None, None, knowledge=kb)
    assert [c.id for c in asyncio.run(r0.search_docs(kb, "smash", 1))] == ["kb:a#x"]
