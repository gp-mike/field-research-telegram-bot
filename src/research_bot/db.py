from __future__ import annotations

import sqlite3
from pathlib import Path

from .models import FinalizedReport


class ReportRepository:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.db_path)
        connection.execute("PRAGMA foreign_keys = ON;")
        return connection

    def _init_schema(self) -> None:
        with self._connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS reports (
                    report_id TEXT PRIMARY KEY,
                    chat_id INTEGER NOT NULL,
                    user_id INTEGER NOT NULL,
                    username TEXT,
                    title TEXT,
                    notes TEXT,
                    transcript TEXT NOT NULL,
                    ai_summary TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS report_attachments (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    report_id TEXT NOT NULL,
                    attachment_type TEXT NOT NULL,
                    telegram_file_id TEXT NOT NULL,
                    stored_path TEXT NOT NULL,
                    caption TEXT,
                    FOREIGN KEY(report_id) REFERENCES reports(report_id) ON DELETE CASCADE
                );
                """
            )
            connection.commit()

    def save_report(self, report: FinalizedReport) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO reports (
                    report_id, chat_id, user_id, username, title, notes, transcript, ai_summary, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                (
                    report.report_id,
                    report.chat_id,
                    report.user_id,
                    report.username,
                    report.title,
                    report.notes,
                    report.transcript,
                    report.ai_summary,
                    report.created_at.isoformat(),
                ),
            )

            connection.executemany(
                """
                INSERT INTO report_attachments (
                    report_id, attachment_type, telegram_file_id, stored_path, caption
                ) VALUES (?, ?, ?, ?, ?);
                """,
                [
                    (
                        report.report_id,
                        attachment.attachment_type,
                        attachment.telegram_file_id,
                        attachment.stored_path,
                        attachment.caption,
                    )
                    for attachment in report.attachments
                ],
            )
            connection.commit()

