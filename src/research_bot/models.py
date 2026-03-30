from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone


@dataclass
class DraftReport:
    chat_id: int
    user_id: int
    username: str | None
    title: str | None = None
    notes: list[str] = field(default_factory=list)
    voice_file_ids: list[str] = field(default_factory=list)
    photo_file_ids: list[str] = field(default_factory=list)
    photo_captions: list[str | None] = field(default_factory=list)
    started_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    def has_content(self) -> bool:
        return bool(self.title or self.notes or self.voice_file_ids or self.photo_file_ids)


@dataclass(frozen=True)
class ReportAttachment:
    attachment_type: str
    telegram_file_id: str
    stored_path: str
    caption: str | None = None


@dataclass(frozen=True)
class FinalizedReport:
    report_id: str
    chat_id: int
    user_id: int
    username: str | None
    title: str | None
    notes: str | None
    transcript: str
    ai_summary: str
    created_at: datetime
    attachments: tuple[ReportAttachment, ...]

