"""Server settings from SHUTTLESENSE_* environment variables (docs/SETUP.md)."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

from shuttlesense.config import BACKEND_DIR, DEFAULT_CONFIG


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SHUTTLESENSE_")

    storage_dir: Path = BACKEND_DIR / "storage"
    token: str | None = None
    device: str | None = None
    cors_origins: str = "*"
    max_upload_mb: int = 1024
    config: Path = DEFAULT_CONFIG
    fake_pipeline: bool = False
    live_session_ttl_s: float = 60.0  # a dropped live session waits this long for a resume

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
