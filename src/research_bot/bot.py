from __future__ import annotations

import json
import logging
import time
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from .ai import AIProcessor
from .config import Settings
from .db import ReportRepository
from .models import DraftReport, FinalizedReport, ReportAttachment
from .storage import FileStorage
from .telegram_api import TelegramAPI

logger = logging.getLogger(__name__)


class ResearchReportBot:
    def __init__(
        self,
        settings: Settings,
        repository: ReportRepository,
        storage: FileStorage,
        ai_processor: AIProcessor,
        telegram_api: TelegramAPI,
    ) -> None:
        self.settings = settings
        self.repository = repository
        self.storage = storage
        self.ai_processor = ai_processor
        self.telegram_api = telegram_api
        self._drafts: dict[tuple[int, int], DraftReport] = {}
        self._allowed_usernames = {username.lower() for username in settings.allowed_usernames}

    def run(self) -> None:
        logger.info("Starting Telegram long polling loop...")
        offset: int | None = None
        while True:
            try:
                updates = self.telegram_api.get_updates(offset=offset, timeout=30)
                for update in updates:
                    update_id = update.get("update_id")
                    if isinstance(update_id, int):
                        offset = update_id + 1
                    self._process_update(update)
            except Exception as exc:
                logger.warning("Polling iteration failed; retrying in 3 seconds. Error: %s", exc)
                time.sleep(3)

    def _process_update(self, update: dict) -> None:
        message = update.get("message")
        if not isinstance(message, dict):
            return

        chat = message.get("chat")
        sender = message.get("from")
        if not isinstance(chat, dict) or not isinstance(sender, dict):
            return

        chat_id = chat.get("id")
        user_id = sender.get("id")
        username = sender.get("username")
        if not isinstance(chat_id, int) or not isinstance(user_id, int):
            return

        text = message.get("text")
        if isinstance(text, str) and text.strip().startswith("/"):
            self._handle_command(chat_id, user_id, username, text.strip())
            return

        if isinstance(text, str) and text.strip():
            self.handle_text(chat_id, user_id, username, text.strip())
            return

        voice = message.get("voice")
        if isinstance(voice, dict):
            self.handle_voice(chat_id, user_id, username, voice)
            return

        photos = message.get("photo")
        if isinstance(photos, list) and photos:
            caption = message.get("caption")
            if not isinstance(caption, str):
                caption = None
            self.handle_photo(chat_id, user_id, username, photos, caption)
            return

    def _handle_command(
        self,
        chat_id: int,
        user_id: int,
        username: str | None,
        raw_text: str,
    ) -> None:
        command = raw_text.split()[0]
        if "@" in command:
            command = command.split("@", 1)[0]
        command = command.lower()

        if command == "/start":
            self.handle_start(chat_id, username)
        elif command == "/help":
            self.handle_help(chat_id, username)
        elif command == "/done":
            self.handle_done(chat_id, user_id, username)
        elif command == "/cancel":
            self.handle_cancel(chat_id, user_id, username)

    def handle_start(self, chat_id: int, username: str | None) -> None:
        if not self._is_allowed(chat_id, username):
            return
        text = (
            "Бот готов принимать отчеты.\n\n"
            "Сценарий:\n"
            "1) Отправьте название (опционально)\n"
            "2) Пришлите голосовое и/или фото\n"
            "3) Отправьте /done, когда отчет завершен\n\n"
            "Команды: /done, /cancel, /help"
        )
        self.telegram_api.send_message(chat_id, text)

    def handle_help(self, chat_id: int, username: str | None) -> None:
        if not self._is_allowed(chat_id, username):
            return
        self.telegram_api.send_message(
            chat_id,
            "Пришлите материалы в любом порядке: текст, фото, голосовые. "
            "После этого отправьте /done. "
            "Бот сохранит файлы, расшифрует голос и добавит AI-сводку.",
        )

    def handle_text(self, chat_id: int, user_id: int, username: str | None, text: str) -> None:
        if not self._is_allowed(chat_id, username):
            return

        if text.lower() in {"done", "готово"}:
            self.handle_done(chat_id, user_id, username)
            return

        draft = self._get_or_create_draft(chat_id, user_id, username)
        if draft.title is None:
            draft.title = text
            self.telegram_api.send_message(chat_id, "Название отчета сохранено.")
        else:
            draft.notes.append(text)
            self.telegram_api.send_message(chat_id, "Текстовая заметка добавлена в черновик.")

    def handle_photo(
        self,
        chat_id: int,
        user_id: int,
        username: str | None,
        photos: list[dict],
        caption: str | None,
    ) -> None:
        if not self._is_allowed(chat_id, username):
            return

        file_id = _extract_largest_photo_file_id(photos)
        if not file_id:
            return

        draft = self._get_or_create_draft(chat_id, user_id, username)
        clean_caption = (caption or "").strip() or None
        draft.photo_file_ids.append(file_id)
        draft.photo_captions.append(clean_caption)
        if clean_caption and draft.title is None:
            draft.title = clean_caption.splitlines()[0][:150]
        self.telegram_api.send_message(chat_id, "Фото добавлено в черновик.")

    def handle_voice(
        self,
        chat_id: int,
        user_id: int,
        username: str | None,
        voice: dict,
    ) -> None:
        if not self._is_allowed(chat_id, username):
            return

        file_id = voice.get("file_id")
        if not isinstance(file_id, str):
            return

        draft = self._get_or_create_draft(chat_id, user_id, username)
        draft.voice_file_ids.append(file_id)
        self.telegram_api.send_message(chat_id, "Голосовое добавлено. Отправьте /done, когда закончите.")

    def handle_cancel(self, chat_id: int, user_id: int, username: str | None) -> None:
        if not self._is_allowed(chat_id, username):
            return
        key = (chat_id, user_id)
        self._drafts.pop(key, None)
        self.telegram_api.send_message(chat_id, "Черновик удален.")

    def handle_done(self, chat_id: int, user_id: int, username: str | None) -> None:
        if not self._is_allowed(chat_id, username):
            return

        key = (chat_id, user_id)
        draft = self._drafts.get(key)
        if not draft or not draft.has_content():
            self.telegram_api.send_message(chat_id, "Черновик пуст. Отправьте материалы для отчета.")
            return

        self.telegram_api.send_message(chat_id, "Обрабатываю отчет. Это может занять до минуты.")
        try:
            finalized_report, report_dir = self._finalize_draft(draft)
            self.repository.save_report(finalized_report)
            self._write_report_json(finalized_report, report_dir)
            self._drafts.pop(key, None)
        except Exception:
            logger.exception("Report finalization failed.")
            self.telegram_api.send_message(
                chat_id,
                "Ошибка во время обработки отчета. Черновик сохранен, попробуйте /done еще раз.",
            )
            return

        summary_preview = finalized_report.ai_summary[:1200]
        self.telegram_api.send_message(
            chat_id,
            f"Отчет сохранен: {finalized_report.report_id}\n\nAI-сводка:\n{summary_preview}",
        )

    def _is_allowed(self, chat_id: int, username: str | None) -> bool:
        if not self._allowed_usernames:
            return True
        normalized = (username or "").lower()
        if normalized in self._allowed_usernames:
            return True
        self.telegram_api.send_message(chat_id, "У вас нет доступа к этому боту.")
        return False

    def _get_or_create_draft(self, chat_id: int, user_id: int, username: str | None) -> DraftReport:
        key = (chat_id, user_id)
        existing = self._drafts.get(key)
        if existing:
            return existing
        draft = DraftReport(
            chat_id=chat_id,
            user_id=user_id,
            username=username,
        )
        self._drafts[key] = draft
        return draft

    def _finalize_draft(self, draft: DraftReport) -> tuple[FinalizedReport, Path]:
        report_id = f"{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}-{uuid4().hex[:8]}"
        report_dir = self.storage.create_report_dir(report_id)

        attachments: list[ReportAttachment] = []
        transcript_chunks: list[str] = []

        for index, voice_file_id in enumerate(draft.voice_file_ids, start=1):
            voice_path = self.storage.download_file(
                telegram_file_id=voice_file_id,
                report_dir=report_dir,
                filename_prefix=f"voice_{index}",
                fallback_extension=".ogg",
            )
            try:
                transcript = self.ai_processor.transcribe_audio(voice_path)
            except Exception as exc:
                logger.exception("Voice transcription failed for %s", voice_path)
                transcript = f"[Ошибка транскрибации: {exc}]"

            transcript_chunks.append(f"[Голосовое {index}]\n{transcript.strip()}")
            attachments.append(
                ReportAttachment(
                    attachment_type="voice",
                    telegram_file_id=voice_file_id,
                    stored_path=str(voice_path),
                )
            )

        for index, photo_file_id in enumerate(draft.photo_file_ids, start=1):
            photo_path = self.storage.download_file(
                telegram_file_id=photo_file_id,
                report_dir=report_dir,
                filename_prefix=f"photo_{index}",
                fallback_extension=".jpg",
            )
            caption = draft.photo_captions[index - 1] if index - 1 < len(draft.photo_captions) else None
            attachments.append(
                ReportAttachment(
                    attachment_type="photo",
                    telegram_file_id=photo_file_id,
                    stored_path=str(photo_path),
                    caption=caption,
                )
            )

        transcript_text = "\n\n".join(transcript_chunks).strip()
        if not transcript_text:
            transcript_text = "Голосовых сообщений не было."
        notes_text = "\n".join(draft.notes).strip() or None

        try:
            ai_summary = self.ai_processor.summarize(transcript_text, draft.title, notes_text)
        except Exception as exc:
            logger.exception("AI summary failed for report %s", report_id)
            ai_summary = f"Не удалось получить AI-сводку: {exc}"

        finalized_report = FinalizedReport(
            report_id=report_id,
            chat_id=draft.chat_id,
            user_id=draft.user_id,
            username=draft.username,
            title=draft.title,
            notes=notes_text,
            transcript=transcript_text,
            ai_summary=ai_summary,
            created_at=datetime.now(timezone.utc),
            attachments=tuple(attachments),
        )
        return finalized_report, report_dir

    @staticmethod
    def _write_report_json(report: FinalizedReport, report_dir: Path) -> None:
        payload = {
            "report_id": report.report_id,
            "chat_id": report.chat_id,
            "user_id": report.user_id,
            "username": report.username,
            "title": report.title,
            "notes": report.notes,
            "transcript": report.transcript,
            "ai_summary": report.ai_summary,
            "created_at": report.created_at.isoformat(),
            "attachments": [
                {
                    "attachment_type": attachment.attachment_type,
                    "telegram_file_id": attachment.telegram_file_id,
                    "stored_path": attachment.stored_path,
                    "caption": attachment.caption,
                }
                for attachment in report.attachments
            ],
        }
        output_path = report_dir / "report.json"
        output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def _extract_largest_photo_file_id(photos: list[dict]) -> str | None:
    best_file_id: str | None = None
    best_area = -1
    for photo in photos:
        if not isinstance(photo, dict):
            continue
        file_id = photo.get("file_id")
        width = photo.get("width", 0)
        height = photo.get("height", 0)
        if not isinstance(file_id, str):
            continue
        if not isinstance(width, int) or not isinstance(height, int):
            width = 0
            height = 0
        area = width * height
        if area >= best_area:
            best_area = area
            best_file_id = file_id
    return best_file_id
