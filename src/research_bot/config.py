from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    telegram_bot_token: str
    openai_api_key: str | None
    openai_transcribe_model: str
    openai_summary_model: str
    summary_prompt: str
    database_path: Path
    storage_dir: Path
    allowed_usernames: tuple[str, ...]

    @classmethod
    def from_env(cls) -> "Settings":
        bot_token = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
        if not bot_token:
            raise ValueError("TELEGRAM_BOT_TOKEN is required in environment.")

        openai_api_key = os.getenv("OPENAI_API_KEY", "").strip() or None

        database_path = Path(os.getenv("DATABASE_PATH", "data/reports.sqlite3")).expanduser()
        if not database_path.is_absolute():
            database_path = (Path.cwd() / database_path).resolve()

        storage_dir = Path(os.getenv("STORAGE_DIR", "data/reports")).expanduser()
        if not storage_dir.is_absolute():
            storage_dir = (Path.cwd() / storage_dir).resolve()

        raw_allowed = os.getenv("ALLOWED_USERNAMES", "")
        allowed_usernames = tuple(
            username.strip().lstrip("@")
            for username in raw_allowed.split(",")
            if username.strip()
        )

        return cls(
            telegram_bot_token=bot_token,
            openai_api_key=openai_api_key,
            openai_transcribe_model=os.getenv("OPENAI_TRANSCRIBE_MODEL", "gpt-4o-mini-transcribe"),
            openai_summary_model=os.getenv("OPENAI_SUMMARY_MODEL", "gpt-4o-mini"),
            summary_prompt=os.getenv(
                "SUMMARY_PROMPT",
                "Выдели основные идеи из сказанного текста. Ответ дай кратко, по пунктам.",
            ),
            database_path=database_path,
            storage_dir=storage_dir,
            allowed_usernames=allowed_usernames,
        )
