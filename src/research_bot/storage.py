from __future__ import annotations

from pathlib import Path

from .telegram_api import TelegramAPI


class FileStorage:
    def __init__(self, base_dir: Path, telegram_api: TelegramAPI) -> None:
        self.base_dir = base_dir
        self.telegram_api = telegram_api
        self.base_dir.mkdir(parents=True, exist_ok=True)

    def create_report_dir(self, report_id: str) -> Path:
        report_dir = self.base_dir / report_id
        report_dir.mkdir(parents=True, exist_ok=True)
        return report_dir

    def download_file(
        self,
        telegram_file_id: str,
        report_dir: Path,
        filename_prefix: str,
        fallback_extension: str,
    ) -> Path:
        local_path = report_dir / f"{filename_prefix}{fallback_extension}"
        return self.telegram_api.download_file(telegram_file_id, local_path)

