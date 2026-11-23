"""Coach LLM providers with fake SDK clients: no network, no key."""

from __future__ import annotations

import asyncio
from types import SimpleNamespace

import httpx
import pytest
from pydantic import BaseModel

from shuttlesense.api.settings import Settings
from shuttlesense.coach.llm import (
    TRUNCATED,
    AnthropicProvider,
    ChatError,
    FakeProvider,
    GeminiProvider,
    Refused,
    create_provider,
    describe_gemini_error,
    hash_embedding,
)


def _run(coro):
    return asyncio.run(coro)


async def _collect(stream) -> list[str]:
    return [t async for t in stream]


class FakeModels:
    """Stands in for genai.Client().aio.models."""

    def __init__(self, chunks=("Hi ", "there"), finish="STOP", error=None, json_text="{}"):
        self.chunks, self.finish, self.error, self.json_text = (
            list(chunks),
            finish,
            error,
            json_text,
        )
        self.calls: list[tuple[str, dict]] = []

    async def generate_content_stream(self, **kwargs):
        self.calls.append(("stream", kwargs))
        if self.error is not None:
            raise self.error

        async def gen():
            for i, text in enumerate(self.chunks):
                last = i == len(self.chunks) - 1
                cand = SimpleNamespace(
                    finish_reason=SimpleNamespace(name=self.finish) if last else None
                )
                yield SimpleNamespace(text=text, candidates=[cand])

        return gen()

    async def generate_content(self, **kwargs):
        self.calls.append(("json", kwargs))
        if self.error is not None:
            raise self.error
        return SimpleNamespace(parsed=None, text=self.json_text)

    async def embed_content(self, **kwargs):
        self.calls.append(("embed", kwargs))
        if self.error is not None:
            raise self.error
        n = len(kwargs["contents"])
        return SimpleNamespace(
            embeddings=[SimpleNamespace(values=[float(i), 1.0]) for i in range(n)]
        )


def _gemini(models: FakeModels, **kw) -> GeminiProvider:
    return GeminiProvider(client=SimpleNamespace(aio=SimpleNamespace(models=models)), **kw)


def test_gemini_streams_with_system_instruction_and_roles() -> None:
    models = FakeModels()
    provider = _gemini(models, model="gemini-x")
    messages = [
        {"role": "assistant", "text": "stray"},
        {"role": "user", "text": "q1"},
        {"role": "assistant", "text": "a1"},
        {"role": "user", "text": "q2"},
    ]
    assert _run(_collect(provider.stream("rules", messages))) == ["Hi ", "there"]
    kind, call = models.calls[0]
    assert call["model"] == "gemini-x"
    assert call["config"].system_instruction == "rules"
    assert [c.role for c in call["contents"]] == ["user", "model", "user"]


def test_gemini_uses_fast_model_on_initial_timeout() -> None:
    class SlowPrimary(FakeModels):
        async def generate_content_stream(self, **kwargs):
            if kwargs["model"] == "primary":
                raise httpx.ReadTimeout("busy")
            return await super().generate_content_stream(**kwargs)

    sdk = SlowPrimary()
    provider = _gemini(sdk, model="primary", fast_model="secondary")
    assert _run(_collect(provider.stream("rules", [_q()]))) == ["Hi ", "there"]
    assert sdk.calls[0][1]["model"] == "secondary"


def test_gemini_does_not_restart_a_partial_answer() -> None:
    class Interrupted(FakeModels):
        async def generate_content_stream(self, **kwargs):
            self.calls.append(("stream", kwargs))

            async def chunks():
                yield SimpleNamespace(text="First sentence.", candidates=[])
                raise httpx.ReadTimeout("disconnected")

            return chunks()

    models = Interrupted()
    provider = _gemini(models, model="primary", fast_model="secondary")
    with pytest.raises(ChatError):
        _run(_collect(provider.stream("rules", [_q()])))
    assert len(models.calls) == 1


def test_gemini_truncation_and_safety_stops() -> None:
    out = _run(_collect(_gemini(FakeModels(finish="MAX_TOKENS")).stream("s", [_q()])))
    assert out[-1] == TRUNCATED
    with pytest.raises(Refused):
        _run(_collect(_gemini(FakeModels(finish="SAFETY")).stream("s", [_q()])))


def _q() -> dict:
    return {"role": "user", "text": "q"}


class Out(BaseModel):
    intent: str


def test_gemini_json_uses_schema_and_fast_model() -> None:
    models = FakeModels(json_text='{"intent": "drills"}')
    provider = _gemini(models, model="big", fast_model="small")
    out = _run(provider.generate_json("sys", "prompt", Out, fast=True))
    assert out == Out(intent="drills")
    call = models.calls[0][1]
    assert call["model"] == "small"
    assert call["config"].response_mime_type == "application/json"
    assert call["config"].response_schema is Out


def test_gemini_embeds_one_content_per_text_with_task_prefix() -> None:
    models = FakeModels()
    provider = _gemini(models, embed_model="gemini-embedding-2")
    provider.EMBED_BATCH = 2
    vecs = _run(provider.embed(["a", "b", "c"], "query"))
    assert len(vecs) == 3 and len(models.calls) == 2  # batched
    first = models.calls[0][1]
    assert first["contents"][0].parts[0].text == "task: search result | query: a"
    assert first["config"].task_type is None and first["config"].output_dimensionality == 768
    doc = _gemini(FakeModels(), embed_model="gemini-embedding-2")
    doc_models = doc.client.aio.models
    _run(doc.embed(["Split step\nhop"], "document"))
    assert doc_models.calls[0][1]["contents"][0].parts[0].text.startswith("title: Split step |")
    legacy_models = FakeModels()
    legacy = _gemini(legacy_models, embed_model="gemini-embedding-001")
    _run(legacy.embed(["x"], "document"))
    call = legacy_models.calls[0][1]
    assert call["config"].task_type == "RETRIEVAL_DOCUMENT"
    assert call["contents"][0].parts[0].text == "x"


@pytest.mark.parametrize(
    ("code", "status", "words"),
    [(401, 503, "key was rejected"), (403, 503, "key was rejected"),
     (429, 429, "rate limit"), (400, 502, "400")],
)  # fmt: skip
def test_gemini_client_errors_are_readable(code: int, status: int, words: str) -> None:
    from google.genai import errors

    exc = errors.ClientError(code, {"error": {"code": code, "message": "m", "status": "X"}})
    mapped = describe_gemini_error(exc)
    assert mapped.status == status and words in mapped.detail and "Gemini" in mapped.detail
    with pytest.raises(ChatError) as info:
        _run(_collect(_gemini(FakeModels(error=exc)).stream("s", [_q()])))
    assert info.value.status == status


def test_gemini_server_and_network_errors() -> None:
    from google.genai import errors

    server = errors.ServerError(503, {"error": {"code": 503, "message": "m", "status": "X"}})
    assert describe_gemini_error(server).status == 503
    offline = httpx.ConnectError("down")
    mapped = describe_gemini_error(offline)
    assert mapped.status == 503 and "cannot reach the Gemini API" in mapped.detail
    with pytest.raises(ChatError):
        _run(_gemini(FakeModels(error=offline)).embed(["x"], "query"))


def test_fake_provider_is_deterministic() -> None:
    fake = FakeProvider(["one two", "three"], {"Out": {"intent": "x"}})
    assert _run(_collect(fake.stream("s", [_q()]))) == ["one ", "two"]
    assert _run(_collect(fake.stream("s", [_q()]))) == ["three"]
    assert _run(fake.generate_json("s", "p", Out)).intent == "x"
    a, b = _run(fake.embed(["smash power", "smash power"], "document"))
    assert a == b == hash_embedding("smash power")
    close = sum(x * y for x, y in zip(a, hash_embedding("smash"), strict=True))
    far = sum(x * y for x, y in zip(a, hash_embedding("serve rules"), strict=True))
    assert close > far


def test_provider_choice_follows_keys(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    from shuttlesense.api import settings as settings_module

    monkeypatch.setattr(settings_module, "BACKEND_DIR", tmp_path)
    monkeypatch.setitem(Settings.model_config, "env_file", tmp_path / ".env")
    monkeypatch.delenv("SHUTTLESENSE_GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("SHUTTLESENSE_ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert Settings().active_provider is None and Settings().chat_key is None
    assert create_provider(Settings()) is None
    claude_only = Settings(anthropic_api_key="a")
    assert claude_only.active_provider == "claude" and claude_only.chat_key == "a"
    both = Settings(anthropic_api_key="a", gemini_api_key="g")
    assert both.active_provider == "gemini" and both.chat_key == "g"
    assert (
        Settings(anthropic_api_key="a", gemini_api_key="g", coach_provider="claude").chat_key == "a"
    )
    assert Settings(gemini_api_key="g", coach_provider="off").active_provider is None
    monkeypatch.setenv("GEMINI_API_KEY", "env")
    assert Settings().gemini_key == "env"
    provider = create_provider(Settings())
    assert isinstance(provider, GeminiProvider) and provider.model == Settings().gemini_model
    fake_client = SimpleNamespace()
    assert isinstance(create_provider(Settings(), fake_client), AnthropicProvider)
