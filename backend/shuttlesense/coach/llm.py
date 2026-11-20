"""LLM providers for the coach (D42): Gemini by default, Claude optional, a fake for tests.

Every provider offers the three calls the RAG coach needs: a streamed answer, a JSON answer
validated against a pydantic model, and text embeddings. SDKs are imported lazily so the API
server starts without them. SDK failures become ChatError, whose detail the app shows as is.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from collections.abc import AsyncIterator, Callable
from typing import TYPE_CHECKING, Any, Literal, Protocol, TypeVar

from pydantic import BaseModel

if TYPE_CHECKING:
    from shuttlesense.api.settings import Settings

EmbedTask = Literal["query", "document"]
M = TypeVar("M", bound=BaseModel)

TRUNCATED = " (answer cut short)"


class ChatError(Exception):
    """A failure to show the user as is (no key, rate limit, network...)."""

    def __init__(self, detail: str, status: int = 502) -> None:
        super().__init__(detail)
        self.detail = detail
        self.status = status


class Refused(Exception):
    """The model declined to answer (safety or refusal stop)."""


class LLMProvider(Protocol):
    name: str  # "gemini", "claude" or "fake"
    embed_model: str | None  # None: no embeddings, retrieval is BM25 only
    fast_json: bool  # cheap enough to call for intent routing on every question

    def stream(self, system: str, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        """Answer text chunks. messages: [{"role": "user"|"assistant", "text": ...}]."""
        ...

    async def generate_json(
        self, system: str, prompt: str, schema: type[M], *, fast: bool = False
    ) -> M: ...

    async def embed(self, texts: list[str], task: EmbedTask) -> list[list[float]]: ...


def _alternating(messages: list[dict[str, str]]) -> list[dict[str, str]]:
    """Turns starting with the user, as both APIs want."""
    out = [m for m in messages if m.get("text")]
    while out and out[0]["role"] != "user":
        out.pop(0)
    return out


# Gemini -------------------------------------------------------------------------


def describe_gemini_error(exc: Exception) -> ChatError:
    """Map google-genai errors, most specific first, to messages the app can show."""
    import httpx
    from google.genai import errors

    if isinstance(exc, ChatError):
        return exc
    if isinstance(exc, errors.APIError):
        code = getattr(exc, "code", None) or 0
        if code in (401, 403):
            return ChatError("The backend's Gemini API key was rejected.", 503)
        if code == 429:
            return ChatError("The coach is busy (Gemini rate limit). Try again in a minute.", 429)
        if code == 400:
            return ChatError("The coach could not read this request (Gemini returned 400).", 502)
        if isinstance(exc, errors.ServerError):
            return ChatError(f"The Gemini API is unavailable right now ({code}).", 503)
        return ChatError(f"The Gemini API returned an error ({code}).", 502)
    if isinstance(exc, httpx.TransportError | ConnectionError | TimeoutError):
        return ChatError("The backend cannot reach the Gemini API (offline?).", 503)
    return ChatError("The coach failed to answer.", 500)


class GeminiProvider:
    """google-genai (`pip install google-genai`), async client."""

    name = "gemini"
    fast_json = True
    EMBED_BATCH = 100  # inputs per embed_content request

    def __init__(
        self,
        api_key: str | None = None,
        *,
        model: str = "gemini-3.8-flash",
        fast_model: str = "gemini-3.5-flash-lite",
        embed_model: str = "gemini-embedding-2",
        embed_dim: int = 768,
        temperature: float = 0.4,
        max_output_tokens: int = 2048,
        client: Any | None = None,
    ) -> None:
        if client is None:
            from google import genai

            client = genai.Client(api_key=api_key)
        self.client = client
        self.model, self.fast_model = model, fast_model
        self.embed_model, self.embed_dim = embed_model, embed_dim
        self.temperature, self.max_output_tokens = temperature, max_output_tokens

    @staticmethod
    def _contents(messages: list[dict[str, str]]) -> list[Any]:
        from google.genai import types

        return [
            types.Content(
                role="model" if m["role"] == "assistant" else "user",
                parts=[types.Part(text=m["text"])],
            )
            for m in _alternating(messages)
        ]

    async def stream(self, system: str, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        from google.genai import types

        config = types.GenerateContentConfig(
            system_instruction=system,
            temperature=self.temperature,
            max_output_tokens=self.max_output_tokens,
        )
        finish = None
        try:
            chunks = await self.client.aio.models.generate_content_stream(
                model=self.model, contents=self._contents(messages), config=config
            )
            async for chunk in chunks:
                for cand in chunk.candidates or []:
                    if cand.finish_reason is not None:
                        finish = str(getattr(cand.finish_reason, "name", cand.finish_reason))
                if chunk.text:
                    yield chunk.text
        except (ChatError, Refused):
            raise
        except Exception as exc:
            raise describe_gemini_error(exc) from exc
        if finish in ("SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION"):
            raise Refused(finish)
        if finish == "MAX_TOKENS":
            yield TRUNCATED

    async def generate_json(
        self, system: str, prompt: str, schema: type[M], *, fast: bool = False
    ) -> M:
        from google.genai import types

        config = types.GenerateContentConfig(
            system_instruction=system,
            temperature=0.2,
            max_output_tokens=self.max_output_tokens * 2,
            response_mime_type="application/json",
            response_schema=schema,
        )
        try:
            res = await self.client.aio.models.generate_content(
                model=self.fast_model if fast else self.model, contents=prompt, config=config
            )
        except Exception as exc:
            raise describe_gemini_error(exc) from exc
        parsed = getattr(res, "parsed", None)
        if isinstance(parsed, schema):
            return parsed
        return schema.model_validate_json(res.text or "{}")

    def _embed_input(self, text: str, task: EmbedTask) -> str:
        if "embedding-001" in (self.embed_model or ""):
            return text  # task_type in the config instead
        # gemini-embedding-2 takes the task as a text prefix, not task_type.
        if task == "query":
            return f"task: search result | query: {text}"
        title = text.splitlines()[0][:80] if text else "none"
        return f"title: {title} | text: {text}"

    async def embed(self, texts: list[str], task: EmbedTask) -> list[list[float]]:
        from google.genai import types

        legacy = "embedding-001" in (self.embed_model or "")
        config = types.EmbedContentConfig(
            output_dimensionality=self.embed_dim,
            task_type=("RETRIEVAL_QUERY" if task == "query" else "RETRIEVAL_DOCUMENT")
            if legacy
            else None,
        )
        out: list[list[float]] = []
        try:
            for i in range(0, len(texts), self.EMBED_BATCH):
                batch = texts[i : i + self.EMBED_BATCH]
                # One Content per input: a plain list would be aggregated into one vector.
                contents = [
                    types.Content(parts=[types.Part(text=self._embed_input(t, task))])
                    for t in batch
                ]
                res = await self.client.aio.models.embed_content(
                    model=self.embed_model, contents=contents, config=config
                )
                out += [list(e.values or []) for e in res.embeddings or []]
        except Exception as exc:
            raise describe_gemini_error(exc) from exc
        if len(out) != len(texts):
            raise ChatError("The Gemini API returned the wrong number of embeddings.", 502)
        return out


# Claude ---------------------------------------------------------------------------


def describe_error(exc: Exception) -> ChatError:
    """Map Anthropic SDK errors, most specific first, to messages the app can show."""
    import anthropic

    if isinstance(exc, ChatError):
        return exc
    if isinstance(exc, anthropic.AuthenticationError | anthropic.PermissionDeniedError):
        return ChatError("The backend's Claude API key was rejected.", 503)
    if isinstance(exc, anthropic.RateLimitError):
        return ChatError("The coach is busy (rate limited). Try again in a minute.", 429)
    if isinstance(exc, anthropic.BadRequestError):
        return ChatError("The coach could not read this session.", 502)
    if isinstance(exc, anthropic.APIStatusError):
        return ChatError(f"The Claude API returned an error ({exc.status_code}).", 502)
    if isinstance(exc, anthropic.APIConnectionError):
        return ChatError("The backend cannot reach the Claude API (offline?).", 503)
    return ChatError("The coach failed to answer.", 500)


class AnthropicProvider:
    """The original Claude path (D18), kept as an optional provider (coach_provider=claude).

    Claude has no embeddings API, so retrieval with this provider is BM25 only, and intent
    routing uses keywords (one Opus call per question just to route is not worth it).
    """

    name = "claude"
    embed_model = None
    fast_json = False

    def __init__(
        self,
        client: Any | None = None,
        *,
        api_key: str | None = None,
        model: str = "claude-opus-5-5",
        effort: str = "medium",
        max_tokens: int = 4000,
        fallbacks: bool = True,
    ) -> None:
        if client is None:
            import anthropic

            client = anthropic.AsyncAnthropic(api_key=api_key)
        self.client = client
        self.model, self.effort, self.max_tokens, self.fallbacks = (
            model,
            effort,
            max_tokens,
            fallbacks,
        )

    def _request(self, system: str, messages: list[dict[str, Any]]) -> dict[str, Any]:
        request: dict[str, Any] = {
            "model": self.model,
            "max_tokens": self.max_tokens,
            # Cached: the follow-up questions of one session share most of the prefix.
            "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
            "messages": messages,
            "output_config": {"effort": self.effort},
        }
        if self.fallbacks:
            request["betas"] = ["server-side-fallback-2026-07-01"]
            request["fallbacks"] = "default"
        return request

    async def stream(self, system: str, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        turns = [{"role": m["role"], "content": m["text"]} for m in _alternating(messages)]
        try:
            async with self.client.beta.messages.stream(**self._request(system, turns)) as s:
                async for text in s.text_stream:
                    yield text
                final = await s.get_final_message()
        except (ChatError, Refused):
            raise
        except Exception as exc:
            raise describe_error(exc) from exc
        if final.stop_reason == "refusal":
            raise Refused("refusal")
        if final.stop_reason == "max_tokens":
            yield TRUNCATED

    async def generate_json(
        self, system: str, prompt: str, schema: type[M], *, fast: bool = False
    ) -> M:
        request = self._request(system, [{"role": "user", "content": prompt}])
        request["output_config"] = {
            "effort": self.effort,
            "format": {"type": "json_schema", "schema": schema.model_json_schema()},
        }
        try:
            res = await self.client.beta.messages.create(**request)
        except Exception as exc:
            raise describe_error(exc) from exc
        text = "".join(getattr(b, "text", "") for b in res.content)
        return schema.model_validate_json(text)

    async def embed(self, texts: list[str], task: EmbedTask) -> list[list[float]]:
        raise NotImplementedError("Claude has no embeddings API")


# Fake (tests, demo) ---------------------------------------------------------------------


_TOKEN = re.compile(r"[a-z0-9]+")


def hash_embedding(text: str, dim: int = 64) -> list[float]:
    """Deterministic bag-of-words vector: texts sharing words point the same way."""
    vec = [0.0] * dim
    for tok in _TOKEN.findall(text.lower()):
        h = int.from_bytes(hashlib.blake2b(tok.encode(), digest_size=4).digest(), "little")
        vec[h % dim] += 1.0 if (h >> 16) & 1 else -1.0
    norm = math.sqrt(sum(v * v for v in vec)) or 1.0
    return [v / norm for v in vec]


class FakeProvider:
    """Scripted answers, canned or computed JSON and hash embeddings; records every call."""

    name = "fake"
    fast_json = True

    def __init__(
        self,
        answers: list[str] | None = None,
        json_responses: dict[str, Any] | None = None,
        *,
        embed_model: str | None = "fake-embed",
        error: Exception | None = None,
        refuse: bool = False,
    ) -> None:
        self.answers = list(answers or ["Keep your elbow high."])
        self.json_responses = dict(json_responses or {})
        self.embed_model = embed_model
        self.error, self.refuse = error, refuse
        self.streams: list[dict[str, Any]] = []
        self.json_calls: list[dict[str, Any]] = []
        self.embed_calls: list[tuple[list[str], str]] = []

    async def stream(self, system: str, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        self.streams.append({"system": system, "messages": messages})
        if self.error is not None:
            raise self.error
        answer = self.answers[min(len(self.streams), len(self.answers)) - 1]
        for word in re.findall(r"\S+\s*", answer):
            yield word
        if self.refuse:
            raise Refused("refusal")

    async def generate_json(
        self, system: str, prompt: str, schema: type[M], *, fast: bool = False
    ) -> M:
        self.json_calls.append({"system": system, "prompt": prompt, "schema": schema.__name__})
        response = self.json_responses.get(schema.__name__)
        if response is None:
            raise ChatError("no scripted response", 502)
        if isinstance(response, Exception):
            raise response
        if callable(response):
            response = response(prompt)
        if isinstance(response, str):
            return schema.model_validate_json(response)
        return schema.model_validate(json.loads(json.dumps(response)))

    async def embed(self, texts: list[str], task: EmbedTask) -> list[list[float]]:
        self.embed_calls.append((list(texts), task))
        if self.embed_model is None:
            raise NotImplementedError("embeddings off")
        return [hash_embedding(t) for t in texts]


# Factory ----------------------------------------------------------------------------


ProviderFactory = Callable[[], LLMProvider | None]


def create_provider(settings: Settings, chat_client: Any | None = None) -> LLMProvider | None:
    """The provider settings choose; `chat_client` (an Anthropic client, tests) forces Claude."""
    if chat_client is not None:
        return AnthropicProvider(
            chat_client, model=settings.chat_model, effort=settings.chat_effort
        )
    active = settings.active_provider
    if active == "gemini":
        return GeminiProvider(
            settings.gemini_key,
            model=settings.gemini_model,
            fast_model=settings.gemini_fast_model,
            embed_model=settings.gemini_embed_model,
        )
    if active == "claude":
        return AnthropicProvider(
            api_key=settings.claude_key, model=settings.chat_model, effort=settings.chat_effort
        )
    return None
