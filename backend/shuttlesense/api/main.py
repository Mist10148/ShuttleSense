"""FastAPI application: uvicorn shuttlesense.api.main:app --host 0.0.0.0 --port 8000"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from shuttlesense import __version__
from shuttlesense.api.jobs import JobManager, PipelineFn
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


def create_app(settings: Settings | None = None, pipeline: PipelineFn | None = None) -> FastAPI:
    settings = settings or get_settings()
    if pipeline is None:
        pipeline = run_pipeline
        if settings.fake_pipeline:
            from shuttlesense.fake import fake_pipeline as pipeline

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        storage = Storage(settings.storage_dir)
        device = detect_device(settings.device)
        jobs = JobManager(
            storage, config=load_config(settings.config), device=device, pipeline=pipeline
        )
        app.state.storage = storage
        app.state.jobs = jobs
        app.state.device = device
        app.state.available_stages = (
            list(STAGE_NAMES) if settings.fake_pipeline else available_stages(jobs.config)
        )
        jobs.start()
        yield
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
    return app


app = create_app()
