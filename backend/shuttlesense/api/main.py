"""FastAPI application: uvicorn shuttlesense.api.main:app --host 0.0.0.0 --port 8000"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from shuttlesense import __version__
from shuttlesense.api.jobs import JobManager, PipelineFn
from shuttlesense.api.routes import public, router
from shuttlesense.api.settings import Settings, get_settings
from shuttlesense.api.storage import Storage
from shuttlesense.config import detect_device, load_config
from shuttlesense.pipeline import STAGE_NAMES, available_stages, run_pipeline


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
    app.include_router(public)
    app.include_router(router)
    return app


app = create_app()
