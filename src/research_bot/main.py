from __future__ import annotations

import logging
from pathlib import Path

from .ai import AIProcessor
from .bot import ResearchReportBot
from .config import Settings
from .db import ReportRepository
from .env import load_dotenv_file
from .storage import FileStorage
from .telegram_api import TelegramAPI


def configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def main() -> None:
    load_dotenv_file(".env")
    project_root_env = Path(__file__).resolve().parents[2] / ".env"
    load_dotenv_file(project_root_env)
    configure_logging()

    settings = Settings.from_env()
    telegram_api = TelegramAPI(settings.telegram_bot_token)
    repository = ReportRepository(settings.database_path)
    storage = FileStorage(settings.storage_dir, telegram_api=telegram_api)
    ai_processor = AIProcessor(
        api_key=settings.openai_api_key,
        transcribe_model=settings.openai_transcribe_model,
        summary_model=settings.openai_summary_model,
        summary_prompt=settings.summary_prompt,
    )

    bot = ResearchReportBot(
        settings=settings,
        repository=repository,
        storage=storage,
        ai_processor=ai_processor,
        telegram_api=telegram_api,
    )
    bot.run()


if __name__ == "__main__":
    main()
