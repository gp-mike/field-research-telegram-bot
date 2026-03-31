# Field Research Telegram Bot

Локальный Telegram-бот для полевых интервью:
- принимает текст, фото и голосовые сообщения;
- сохраняет вложения и структуру отчета в `data/reports/<report_id>/report.json`;
- пишет метаданные в SQLite (`data/reports.sqlite3`);
- при наличии `OPENAI_API_KEY` делает транскрибацию и AI-разбор;
- перед записью в БД отправляет менеджеру подтверждение (`/yes` сохранить, `/no` правки);
- отправляет итог обратно в Telegram после подтверждения.

AI-ответ записывается в двух местах:
- JSON-файл отчета: поле `ai_summary` в `data/reports/<report_id>/report.json`;
- SQLite: поле `ai_summary` в таблице `reports` (`data/reports.sqlite3`).

## Запуск

Основной рантайм:
```bash
cd /Users/mikhailsuchkov/codex_botan
./scripts/run_telegram_bot.sh
```

Рекомендуемый способ (управление фоновым процессом):
```bash
cd /Users/mikhailsuchkov/codex_botan
./scripts/botctl.sh run          # foreground-режим (самый надежный локально)
./scripts/botctl.sh start
./scripts/botctl.sh status
./scripts/botctl.sh logs 120
./scripts/botctl.sh restart
./scripts/botctl.sh stop
```

Если локально видите, что бот \"завис\":
```bash
cd /Users/mikhailsuchkov/codex_botan
./scripts/botctl.sh stop
./scripts/botctl.sh run
```
Оставьте этот процесс в открытом терминале и тестируйте в Telegram.

## Конфиг (`.env`)

Обязательное:
- `TELEGRAM_BOT_TOKEN`

Для AI-функций:
- `OPENAI_API_KEY`
- `OPENAI_TRANSCRIBE_MODEL` (default: `gpt-4o-mini-transcribe`)
- `OPENAI_SUMMARY_MODEL` (default: `gpt-5.4-mini`)
- `SUMMARY_PROMPT_FILE` (например, `prompts/salutips_prompt.txt`)
- `SUMMARY_PROMPT` (опционально, если хотите хранить prompt прямо в env)
- `CONFIRM_BEFORE_SAVE` (default: `1`)

Хранилище:
- `DATABASE_PATH` (default: `data/reports.sqlite3`)
- `STORAGE_DIR` (default: `data/reports`)
- `ALLOWED_USERNAMES` (опционально, через запятую)

Google Sheets (опционально, синхронизация после `/yes`):
- `GOOGLE_SHEETS_WEBHOOK_URL` (URL веб-приложения Apps Script)
- `GOOGLE_SHEETS_WEBHOOK_TOKEN` (секрет, если включили проверку в скрипте)

## Google Sheets Sync

1. Создайте проект Apps Script и вставьте код из `scripts/google_sheet_webhook.gs`.
2. В скрипте задайте:
   - `SPREADSHEET_ID` (ID вашей таблицы),
   - `WEBHOOK_TOKEN` (любой секрет, можно оставить пустым),
   - `DRIVE_FOLDER_ID` (опционально: папка Google Drive для фото).
3. Deploy -> Web app:
   - Execute as: `Me`
   - Who has access: `Anyone`
4. Скопируйте URL веб-приложения в `.env`:
   - `GOOGLE_SHEETS_WEBHOOK_URL=...`
   - `GOOGLE_SHEETS_WEBHOOK_TOKEN=...` (если используете токен)
5. Перезапустите бота.

После подтверждения `/yes` бот:
- сохранит отчет в SQLite и файлы;
- отправит копию отчета в Google Sheet;
- загрузит фото в Google Drive и запишет ссылки в таблицу.

## Команды бота

- `/start`
- `/help`
- `/done`
- `/yes`
- `/no`
- `/cancel`
