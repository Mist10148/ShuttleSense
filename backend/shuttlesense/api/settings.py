"""Server settings from SHUTTLESENSE_* environment variables (docs/SETUP.md)."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

from shuttlesense.config import BACKEND_DIR, DEFAULT_CONFIG


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="SHUTTLESENSE_", env_file=BACKEND_DIR / ".env", extra="ignore"
    )

    storage_dir: Path = BACKEND_DIR / "storage"
    token: str | None = None
    device: str | None = None
    cors_origins: str = "*"
    max_upload_mb: int = 1024
    config: Path = DEFAULT_CONFIG
    fake_pipeline: bool = False
    practice_general: bool = False  # opt-in until the annotated tracking comparison passes
    live_session_ttl_s: float = 60.0  # a dropped live session waits this long for a resume
    # Coach chat (docs/PRIVACY.md). The key lives only here, never in the app or the repo;
    # ANTHROPIC_API_KEY is used when SHUTTLESENSE_ANTHROPIC_API_KEY is not set.
    anthropic_api_key: SecretStr | None = None
    chat_model: str = "claude-opus-5-5"
    chat_effort: str = "medium"
    chat_max_messages: int = 20  # questions per session
    chat_max_digest_chars: int = 24000  # longer sessions are summarized per rally
    # RAG coach (D42). GEMINI_API_KEY is used when SHUTTLESENSE_GEMINI_API_KEY is not set.
    # coach_provider: "gemini" prefers Gemini and falls back to Claude when only an Anthropic
    # key is set; "claude" prefers Claude; "off" turns the coach off.
    gemini_api_key: SecretStr | None = None
    coach_provider: Literal["gemini", "claude", "off"] = "gemini"
    gemini_model: str = "gemini-3.8-flash"
    gemini_fast_model: str = "gemini-3.5-flash-lite"  # intent routing
    gemini_embed_model: str = "gemini-embedding-2"
    coach_top_k: int = 6  # retrieved chunks per source (session, history, knowledge)

    @property
    def claude_key(self) -> str | None:
        import os

        if os.environ.get("SHUTTLESENSE_ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_API_KEY"):
            return os.environ.get("SHUTTLESENSE_ANTHROPIC_API_KEY") or os.environ.get(
                "ANTHROPIC_API_KEY"
            )
        if self.anthropic_api_key is not None:
            return self.anthropic_api_key.get_secret_value() or None
        from dotenv import dotenv_values

        return dotenv_values(BACKEND_DIR / ".env").get("ANTHROPIC_API_KEY") or None

    @property
    def gemini_key(self) -> str | None:
        import os

        if os.environ.get("SHUTTLESENSE_GEMINI_API_KEY") or os.environ.get("GEMINI_API_KEY"):
            return os.environ.get("SHUTTLESENSE_GEMINI_API_KEY") or os.environ.get("GEMINI_API_KEY")
        if self.gemini_api_key is not None:
            return self.gemini_api_key.get_secret_value() or None
        from dotenv import dotenv_values

        return dotenv_values(BACKEND_DIR / ".env").get("GEMINI_API_KEY") or None

    @property
    def active_provider(self) -> Literal["gemini", "claude"] | None:
        """The coach provider in use: the preferred one if its key is set, else the other."""
        if self.coach_provider == "off":
            return None
        keys = {"gemini": self.gemini_key, "claude": self.claude_key}
        other = "claude" if self.coach_provider == "gemini" else "gemini"
        for name in (self.coach_provider, other):
            if keys[name]:
                return name  # type: ignore[return-value]
        return None

    @property
    def chat_key(self) -> str | None:
        """The active coach provider's key (None: the coach is off)."""
        active = self.active_provider
        if active is None:
            return None
        return self.gemini_key if active == "gemini" else self.claude_key

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
