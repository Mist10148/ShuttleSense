"""FastAPI application: uvicorn shuttlesense.api.main:app --host 0.0.0.0 --port 8000"""

from __future__ import annotations

import logging
import re
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from shuttlesense import __version__
from shuttlesense.api.jobs import JobManager, PipelineFn
from shuttlesense.api.live import LiveManager, ws_router
from shuttlesense.api.routes import public, router
from shuttlesense.api.settings import Settings, get_settings
from shuttlesense.api.storage import Storage
from shuttlesense.config import detect_device, load_config
from shuttlesense.pipeline import STAGE_NAMES, available_stages, run_pipeline


class UploadLimit:
    """Stops an upload as soon as its body passes `limit` bytes.

    The route's Content-Length check misses chunked uploads, and FastAPI spools the whole
    multipart body to disk before the route runs. Raising HTTPException from receive() is
    passed through by FastAPI's body parsing as a 413 response.
    """

    def __init__(self, app: ASGIApp, limit: int) -> None:
        self.app = app
        self.limit = limit

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["method"] != "POST" or scope["path"] != "/videos":
            await self.app(scope, receive, send)
            return
        received = 0

        async def limited() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.limit:
                    raise HTTPException(status_code=413, detail="upload too large")
            return message

        await self.app(scope, limited, send)


_TOKEN_PARAM = re.compile(r"([?&]token=)[^&\s\"]+")


class RedactToken(logging.Filter):
    """Keeps the access token out of the logs: media, export and frame URLs and WS /live
    carry it in the query string, and uvicorn logs the full URL."""

    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.msg, str):
            record.msg = _TOKEN_PARAM.sub(r"\1***", record.msg)
        if isinstance(record.args, tuple):
            record.args = tuple(
                _TOKEN_PARAM.sub(r"\1***", a) if isinstance(a, str) else a for a in record.args
            )
        return True


def redact_tokens_in_logs() -> None:
    """Safe to call again: each logger gets the filter once."""
    # uvicorn logs HTTP requests on uvicorn.access and WebSocket connections on uvicorn.error.
    for name in ("uvicorn.access", "uvicorn.error"):
        logger = logging.getLogger(name)
        if not any(isinstance(f, RedactToken) for f in logger.filters):
            logger.addFilter(RedactToken())


def create_app(
    settings: Settings | None = None,
    pipeline: PipelineFn | None = None,
    chat_client: Any | None = None,
) -> FastAPI:
    """`chat_client` replaces the Claude API client (tests); otherwise one is made from the key."""
    settings = settings or get_settings()
    redact_tokens_in_logs()
    if pipeline is None:
        pipeline = run_pipeline
        if settings.fake_pipeline:
            from shuttlesense.fake import fake_pipeline as pipeline

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        redact_tokens_in_logs()  # again: uvicorn has set up its loggers by now
        storage = Storage(settings.storage_dir)
        device = detect_device(settings.device)
        jobs = JobManager(
            storage, config=load_config(settings.config), device=device, pipeline=pipeline
        )
        app.state.storage = storage
        app.state.jobs = jobs
        app.state.settings = settings
        app.state.chat_client = chat_client
        if chat_client is None and settings.chat_key:
            import anthropic

            app.state.chat_client = anthropic.AsyncAnthropic(api_key=settings.chat_key)
        app.state.chat_answering = {}  # job id -> monotonic start of the answer streaming
        app.state.live = LiveManager(
            app.state, fake=settings.fake_pipeline, ttl_s=settings.live_session_ttl_s
        )
        app.state.device = device
        app.state.available_stages = (
            list(STAGE_NAMES) if settings.fake_pipeline else available_stages(jobs.config)
        )
        jobs.start()
        yield
        await app.state.live.shutdown()
        jobs.stop()

    app = FastAPI(title="ShuttleSense API", version=__version__, lifespan=lifespan)
    app.dependency_overrides[get_settings] = lambda: settings
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_methods=["*"],
        allow_headers=["*"],
        expose_headers=["X-Frame-Width", "X-Frame-Height", "Content-Disposition"],
    )
    # Allow for the multipart framing around the file, as the route does.
    app.add_middleware(UploadLimit, limit=settings.max_upload_mb * 1024 * 1024 + 64 * 1024)
    app.include_router(public)
    app.include_router(router)
    app.include_router(ws_router)
    return app


app = create_app()
