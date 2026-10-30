"""Server settings from SHUTTLESENSE_* environment variables (docs/SETUP.md)."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import SecretStr
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
    # Coach chat (docs/PRIVACY.md). The key lives only here, never in the app or the repo;
    # ANTHROPIC_API_KEY is used when SHUTTLESENSE_ANTHROPIC_API_KEY is not set.
    anthropic_api_key: SecretStr | None = None
    chat_model: str = "claude-opus-5-5"
    chat_effort: str = "medium"
    chat_max_messages: int = 20  # questions per session
    chat_max_digest_chars: int = 24000  # longer sessions are summarized per rally

    @property
    def chat_key(self) -> str | None:
        import os

        if self.anthropic_api_key is not None:
            return self.anthropic_api_key.get_secret_value() or None
        return os.environ.get("ANTHROPIC_API_KEY") or None

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
