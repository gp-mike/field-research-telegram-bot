#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
DATA_DIR="${ROOT_DIR}/data"
DRAFTS_DIR="${DATA_DIR}/drafts"

mkdir -p "${DATA_DIR}" "${DRAFTS_DIR}"

load_env_file() {
  local file_path="$1"
  if [[ ! -f "${file_path}" ]]; then
    return
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" != *=* ]] && continue

    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi

    export "${key}=${value}"
  done < "${file_path}"
}

load_env_file "${ENV_FILE}"

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required in .env}"

BOT_INSTANCE_ID="${BOT_INSTANCE_ID:-$(printf '%s' "${TELEGRAM_BOT_TOKEN}" | shasum | awk '{print substr($1,1,8)}')}"
RUNTIME_PREFIX="${DATA_DIR}/bot_${BOT_INSTANCE_ID}"
HEARTBEAT_FILE="${RUNTIME_PREFIX}.heartbeat"
STOP_FILE="${RUNTIME_PREFIX}.stop"

OPENAI_API_KEY="${OPENAI_API_KEY:-}"
OPENAI_TRANSCRIBE_MODEL="${OPENAI_TRANSCRIBE_MODEL:-gpt-4o-mini-transcribe}"
OPENAI_SUMMARY_MODEL="${OPENAI_SUMMARY_MODEL:-gpt-5.4-mini}"
DEFAULT_SUMMARY_PROMPT="$(cat <<'PROMPT'
Ты помогаешь команде SaluTips проводить кастдев в ресторанах Ниццы.
Контекст продукта SaluTips: QR-решение для безналичных чаевых в заведениях (официанты, бармены, рестораторы, отели/рестораны).

Твоя задача: из расшифровки встречи менеджера с потенциальным пользователем собрать структурированный отчет.
Не придумывай факты. Если данных нет, используй "unknown" или "Нет данных".
Верни СТРОГО JSON (без markdown и пояснений), на русском языке, со схемой:
{
  "restaurant_name": "string",
  "city": "string",
  "contact_name": "string",
  "contact_role": "waiter|bartender|owner|manager|other|unknown",
  "meeting_result": "connected_now|follow_up|declined|unknown",
  "interest_level": "high|medium|low|unknown",
  "interest_score_1_5": 1,
  "decision_drivers": ["string"],
  "main_objections": ["string"],
  "main_risks": ["string"],
  "requested_features": ["string"],
  "questions_from_prospect": ["string"],
  "next_steps": ["string"],
  "summary_for_team": ["string"],
  "manager_action_priority": "hot|warm|cold|unknown",
  "short_confirmation_ru": "2-4 коротких предложения, что мы правильно поняли"
}

Требования:
- interest_score_1_5: целое 1..5, либо 0 если unknown;
- списки максимум по 5 пунктов;
- формулировки короткие и практичные;
- если респондент отказался подключаться, явно заполни main_objections и main_risks.
- Нулевая толерантность к выдумкам: не добавляй пункты, которых нет в исходном тексте.
- Для полей decision_drivers, main_objections, main_risks, requested_features, questions_from_prospect, next_steps, summary_for_team:
  если явного упоминания нет, верни ["Нет данных"].
- Для requested_features особенно: если респондент ничего не просил добавить/изменить, верни ["Нет данных"].
PROMPT
)"
SUMMARY_PROMPT_FILE="${SUMMARY_PROMPT_FILE:-}"
if [[ -n "${SUMMARY_PROMPT_FILE}" ]]; then
  if [[ "${SUMMARY_PROMPT_FILE}" != /* ]]; then
    SUMMARY_PROMPT_FILE="${ROOT_DIR}/${SUMMARY_PROMPT_FILE}"
  fi
  if [[ -f "${SUMMARY_PROMPT_FILE}" ]]; then
    SUMMARY_PROMPT="$(cat "${SUMMARY_PROMPT_FILE}")"
  else
    SUMMARY_PROMPT="${SUMMARY_PROMPT:-${DEFAULT_SUMMARY_PROMPT}}"
  fi
else
  SUMMARY_PROMPT="${SUMMARY_PROMPT:-${DEFAULT_SUMMARY_PROMPT}}"
fi
CONFIRM_BEFORE_SAVE="${CONFIRM_BEFORE_SAVE:-1}"
DATABASE_PATH="${DATABASE_PATH:-${DATA_DIR}/reports.sqlite3}"
STORAGE_DIR="${STORAGE_DIR:-${DATA_DIR}/reports}"
ALLOWED_USERNAMES="${ALLOWED_USERNAMES:-}"
GOOGLE_SHEETS_WEBHOOK_URL="${GOOGLE_SHEETS_WEBHOOK_URL:-}"
GOOGLE_SHEETS_WEBHOOK_TOKEN="${GOOGLE_SHEETS_WEBHOOK_TOKEN:-}"

if [[ "${DATABASE_PATH}" != /* ]]; then
  DATABASE_PATH="${ROOT_DIR}/${DATABASE_PATH}"
fi
if [[ "${STORAGE_DIR}" != /* ]]; then
  STORAGE_DIR="${ROOT_DIR}/${STORAGE_DIR}"
fi

mkdir -p "$(dirname "${DATABASE_PATH}")" "${STORAGE_DIR}" "${DRAFTS_DIR}"

trim_ws() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

API_BASE="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
FILE_BASE="https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}"
TELEGRAM_RESOLVE_TARGETS="${TELEGRAM_RESOLVE_TARGETS:-[2001:67c:4e8:f004::9],149.154.167.220,149.154.167.91,149.154.167.40}"
TG_LAST_CURL_ERROR=""
TG_LAST_RESPONSE=""
POLL_DEBUG="${POLL_DEBUG:-0}"
LAST_SENT_FILE="${RUNTIME_PREFIX}.last_sent"

init_schema() {
  sqlite3 "${DATABASE_PATH}" <<'SQL'
PRAGMA foreign_keys = ON;
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
SQL
}

tg_call_json() {
  local url="$1"
  local payload="$2"
  local response target
  local -a targets
  IFS=',' read -ra targets <<< "${TELEGRAM_RESOLVE_TARGETS}"

  response="$(curl -sS --max-time 120 --connect-timeout 10 \
    --retry 2 --retry-delay 1 --retry-all-errors \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${url}" 2>/dev/null || true)"
  if [[ -n "${response}" ]]; then
    echo "${response}"
    return 0
  fi

  for target in "${targets[@]}"; do
    target="$(trim_ws "${target}")"
    [[ -z "${target}" ]] && continue
    response="$(curl -sS --max-time 120 --connect-timeout 10 \
      --resolve "api.telegram.org:443:${target}" \
      --retry 2 --retry-delay 1 --retry-all-errors \
      -H "Content-Type: application/json" \
      -d "${payload}" \
      "${url}" 2>/dev/null || true)"
    if [[ -n "${response}" ]]; then
      echo "${response}"
      return 0
    fi
  done

  echo ""
}

tg_post_json() {
  local method="$1"
  local payload="$2"
  tg_call_json "${API_BASE}/${method}" "${payload}"
}

tg_download_file() {
  local remote_path="$1"
  local destination="$2"
  local target
  local -a targets
  IFS=',' read -ra targets <<< "${TELEGRAM_RESOLVE_TARGETS}"

  if curl -sS --max-time 120 --connect-timeout 10 \
    --retry 2 --retry-delay 1 --retry-all-errors \
    -o "${destination}" \
    "${FILE_BASE}/${remote_path}" >/dev/null 2>&1; then
    return 0
  fi

  for target in "${targets[@]}"; do
    target="$(trim_ws "${target}")"
    [[ -z "${target}" ]] && continue
    if curl -sS --max-time 120 --connect-timeout 10 \
      --resolve "api.telegram.org:443:${target}" \
      --retry 2 --retry-delay 1 --retry-all-errors \
      -o "${destination}" \
      "${FILE_BASE}/${remote_path}" >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

send_message() {
  local chat_id="$1"
  local text="$2"
  local payload now msg_hash last_ts last_hash dedupe_window
  now="$(date +%s)"
  msg_hash="$(printf '%s\n%s' "${chat_id}" "${text}" | shasum | awk '{print $1}')"
  dedupe_window=8
  if [[ "${text}" == Спасибо\!\ Отчет\ сохранен\ в\ базу:* ]]; then
    dedupe_window=180
  fi

  if [[ -f "${LAST_SENT_FILE}" ]]; then
    last_ts="$(cut -d'|' -f1 "${LAST_SENT_FILE}" 2>/dev/null || true)"
    last_hash="$(cut -d'|' -f2 "${LAST_SENT_FILE}" 2>/dev/null || true)"
    if [[ "${last_ts}" =~ ^[0-9]+$ ]] && [[ -n "${last_hash}" ]] && [[ "${last_hash}" == "${msg_hash}" ]]; then
      if (( now - last_ts <= dedupe_window )); then
        return 0
      fi
    fi
  fi

  printf '%s|%s\n' "${now}" "${msg_hash}" > "${LAST_SENT_FILE}"
  payload="$(jq -n --argjson chat_id "${chat_id}" --arg text "${text}" '{chat_id:$chat_id,text:$text}')"
  curl -sS --max-time 35 --connect-timeout 8 \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${API_BASE}/sendMessage" >/dev/null 2>&1 || true
}

write_heartbeat() {
  local offset="$1"
  local state="$2"
  local now
  now="$(date +%s)"
  local tmp="${HEARTBEAT_FILE}.tmp"
  printf '%s|%s|%s\n' "${now}" "${offset}" "${state}" > "${tmp}" && mv "${tmp}" "${HEARTBEAT_FILE}"
}

heartbeat_age_seconds() {
  local ts now
  [[ -f "${HEARTBEAT_FILE}" ]] || { echo "-1"; return 0; }
  ts="$(cut -d'|' -f1 "${HEARTBEAT_FILE}" 2>/dev/null || true)"
  [[ "${ts}" =~ ^[0-9]+$ ]] || { echo "-1"; return 0; }
  now="$(date +%s)"
  echo $((now - ts))
}

is_recent_heartbeat() {
  local max_age="${1:-60}"
  local age
  age="$(heartbeat_age_seconds)"
  [[ "${age}" =~ ^-?[0-9]+$ ]] || return 1
  (( age >= 0 && age <= max_age ))
}

tg_get_updates() {
  local payload="$1"
  local response target err_file err_line
  local -a targets
  IFS=',' read -ra targets <<< "${TELEGRAM_RESOLVE_TARGETS}"
  TG_LAST_CURL_ERROR=""
  TG_LAST_RESPONSE=""

  err_file="$(mktemp "${DATA_DIR}/tg_curl_getupdates_err.XXXXXX")"

  response="$(curl -sS --max-time 40 --connect-timeout 8 \
    --retry 2 --retry-delay 1 --retry-all-errors \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${API_BASE}/getUpdates" 2>"${err_file}" || true)"
  if [[ -n "${response}" ]]; then
    rm -f "${err_file}"
    TG_LAST_RESPONSE="${response}"
    return 0
  fi

  err_line="$(tr '\n' ' ' < "${err_file}" 2>/dev/null | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')"
  if [[ -n "${err_line}" ]]; then
    TG_LAST_CURL_ERROR="${err_line}"
  fi

  for target in "${targets[@]}"; do
    target="$(trim_ws "${target}")"
    [[ -z "${target}" ]] && continue
    response="$(curl -sS --max-time 40 --connect-timeout 8 \
      --resolve "api.telegram.org:443:${target}" \
      --retry 2 --retry-delay 1 --retry-all-errors \
      -H "Content-Type: application/json" \
      -d "${payload}" \
      "${API_BASE}/getUpdates" 2>"${err_file}" || true)"
    if [[ -n "${response}" ]]; then
      rm -f "${err_file}"
      TG_LAST_RESPONSE="${response}"
      return 0
    fi

    err_line="$(tr '\n' ' ' < "${err_file}" 2>/dev/null | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')"
    if [[ -n "${err_line}" ]]; then
      TG_LAST_CURL_ERROR="${err_line}"
    fi
  done

  rm -f "${err_file}"
  return 0
}

is_allowed_user() {
  local username="${1:-}"
  if [[ -z "${ALLOWED_USERNAMES}" ]]; then
    return 0
  fi

  local normalized
  normalized="$(echo "${username}" | tr '[:upper:]' '[:lower:]')"
  local token
  IFS=',' read -ra _users <<< "${ALLOWED_USERNAMES}"
  for token in "${_users[@]}"; do
    token="$(trim_ws "${token}")"
    token="${token#@}"
    token="$(echo "${token}" | tr '[:upper:]' '[:lower:]')"
    if [[ -n "${token}" && "${normalized}" == "${token}" ]]; then
      return 0
    fi
  done
  return 1
}

draft_path() {
  local chat_id="$1"
  local user_id="$2"
  echo "${DRAFTS_DIR}/${chat_id}_${user_id}.json"
}

ensure_draft() {
  local path="$1"
  local chat_id="$2"
  local user_id="$3"
  local username="$4"
  if [[ -f "${path}" ]]; then
    return
  fi
  jq -n \
    --argjson chat_id "${chat_id}" \
    --argjson user_id "${user_id}" \
    --arg username "${username}" \
    '{
      chat_id:$chat_id,
      user_id:$user_id,
      username:($username|select(length>0)),
      title:null,
      notes:[],
      voice_file_ids:[],
      photo_file_ids:[],
      photo_captions:[]
    }' > "${path}"
}

set_draft_title_or_note() {
  local path="$1"
  local text="$2"
  local tmp="${path}.tmp"
  jq --arg text "${text}" '
    if .title == null or .title == "" then
      .title = $text
    else
      .notes += [$text]
    end
    | del(.pending_report_json_path, .pending_report_id, .awaiting_confirmation)
  ' "${path}" > "${tmp}" && mv "${tmp}" "${path}"
}

append_photo_to_draft() {
  local path="$1"
  local file_id="$2"
  local caption="$3"
  local tmp="${path}.tmp"
  jq --arg file_id "${file_id}" --arg caption "${caption}" '
    .photo_file_ids += [$file_id]
    | .photo_captions += [($caption | if . == "" then null else . end)]
    | if (.title == null or .title == "") and ($caption != "") then
        .title = ($caption | split("\n")[0] | .[0:150])
      else
        .
      end
    | del(.pending_report_json_path, .pending_report_id, .awaiting_confirmation)
  ' "${path}" > "${tmp}" && mv "${tmp}" "${path}"
}

append_voice_to_draft() {
  local path="$1"
  local file_id="$2"
  local tmp="${path}.tmp"
  jq --arg file_id "${file_id}" '
    .voice_file_ids += [$file_id]
    | del(.pending_report_json_path, .pending_report_id, .awaiting_confirmation)
  ' "${path}" > "${tmp}" && mv "${tmp}" "${path}"
}

draft_has_content() {
  local path="$1"
  jq -e '
    (.title != null and .title != "") or
    (.notes | length > 0) or
    (.voice_file_ids | length > 0) or
    (.photo_file_ids | length > 0)
  ' "${path}" >/dev/null
}

append_note_to_draft() {
  local path="$1"
  local text="$2"
  local tmp="${path}.tmp"
  jq --arg text "${text}" '
    .notes += [$text]
    | del(.pending_report_json_path, .pending_report_id, .awaiting_confirmation)
  ' "${path}" > "${tmp}" && mv "${tmp}" "${path}"
}

draft_has_pending_report() {
  local path="$1"
  [[ -f "${path}" ]] || return 1
  jq -e '(.awaiting_confirmation == true) and (.pending_report_json_path // "") != ""' "${path}" >/dev/null
}

set_draft_pending_report() {
  local path="$1"
  local report_json_path="$2"
  local report_id="$3"
  local tmp="${path}.tmp"
  jq --arg report_json_path "${report_json_path}" --arg report_id "${report_id}" '
    .pending_report_json_path = $report_json_path
    | .pending_report_id = $report_id
    | .awaiting_confirmation = true
  ' "${path}" > "${tmp}" && mv "${tmp}" "${path}"
}

clear_draft_pending_report() {
  local path="$1"
  [[ -f "${path}" ]] || return 0
  local tmp="${path}.tmp"
  jq 'del(.pending_report_json_path, .pending_report_id, .awaiting_confirmation)' "${path}" > "${tmp}" && mv "${tmp}" "${path}"
}

download_telegram_file() {
  local file_id="$1"
  local destination="$2"
  local file_payload file_resp file_path

  file_payload="$(jq -n --arg file_id "${file_id}" '{file_id:$file_id}')"
  file_resp="$(tg_post_json "getFile" "${file_payload}" || true)"
  file_path="$(echo "${file_resp}" | jq -r '.result.file_path // empty')"

  if [[ -z "${file_path}" ]]; then
    return 1
  fi

  tg_download_file "${file_path}" "${destination}"
}

transcribe_audio() {
  local audio_path="$1"
  if [[ -z "${OPENAI_API_KEY}" ]]; then
    echo "[OPENAI_API_KEY не задан, транскрибация отключена]"
    return 0
  fi

  local resp text
  resp="$(curl -sS --max-time 240 --connect-timeout 15 \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -F "model=${OPENAI_TRANSCRIBE_MODEL}" \
    -F "file=@${audio_path}" \
    "https://api.openai.com/v1/audio/transcriptions" || true)"
  text="$(echo "${resp}" | jq -r '.text // empty' 2>/dev/null || true)"
  if [[ -z "${text}" ]]; then
    echo "[Ошибка транскрибации]"
  else
    echo "${text}"
  fi
}

build_summary() {
  local transcript="$1"
  local title="$2"
  local notes="$3"

  if [[ -z "${OPENAI_API_KEY}" ]]; then
    echo "OPENAI_API_KEY не задан, AI-сводка отключена."
    return 0
  fi

  local user_payload=""
  if [[ -n "${title}" ]]; then
    user_payload+="Название интервью: ${title}"$'\n\n'
  fi
  if [[ -n "${notes}" ]]; then
    user_payload+="Дополнительные заметки:"$'\n'"${notes}"$'\n\n'
  fi
  user_payload+="Транскрипт:"$'\n'"${transcript}"

  local req resp summary
  req="$(jq -n \
    --arg model "${OPENAI_SUMMARY_MODEL}" \
    --arg prompt "${SUMMARY_PROMPT}" \
    --arg user_payload "${user_payload}" \
    '{
      model:$model,
      input:[
        {role:"system",content:$prompt},
        {role:"user",content:$user_payload}
      ],
      max_output_tokens:1100
    }')"

  resp="$(curl -sS --max-time 60 --connect-timeout 10 \
    --retry 1 --retry-delay 1 --retry-all-errors \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${req}" \
    "https://api.openai.com/v1/responses" || true)"

  summary="$(echo "${resp}" | jq -r '
    if (.output_text // "") != "" then
      .output_text
    else
      ([.output[]?.content[]?.text // empty] | join("\n"))
    end
  ' 2>/dev/null || true)"

  if [[ -z "${summary}" ]]; then
    echo "Не удалось получить краткое резюме по транскрипту."
  else
    echo "${summary}"
  fi
}

extract_json_payload() {
  local raw="$1"
  local normalized=""
  if [[ -z "${raw}" ]]; then
    return 0
  fi

  normalized="$(python3 -c 'import json,re,sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
candidates = [raw, raw.strip()]
s = raw.strip()
if s.startswith("```"):
    s = re.sub(r"^```(?:json)?\\s*", "", s, flags=re.IGNORECASE)
    s = re.sub(r"\\s*```$", "", s)
    candidates.append(s)
for item in list(candidates):
    t = item.strip()
    i = t.find("{")
    j = t.rfind("}")
    if i != -1 and j != -1 and j > i:
        candidates.append(t[i:j+1])
for item in candidates:
    try:
        json.loads(item)
        print(item)
        raise SystemExit(0)
    except Exception:
        pass
print("")' "${raw}")"

  if [[ -z "${normalized}" ]]; then
    echo ""
    return 0
  fi
  echo "${normalized}"
}

format_summary_confirmation() {
  local raw="$1"
  local normalized=""
  normalized="$(extract_json_payload "${raw}")"
  if [[ -z "${normalized}" ]]; then
    local preview
    preview="$(printf '%s' "${raw}" | cut -c1-1400)"
    echo "Не удалось полностью структурировать ответ. Проверьте краткий вариант ниже:

${preview}

Если всё верно — отправьте /yes.
Если нужны правки — отправьте /no и затем текстом, что исправить."
    return 0
  fi

  echo "${normalized}" | jq -r '
    def as_text(v; d):
      if (v|type) == "string" and (v|length) > 0 then v else d end;

    def list_block(title; arr):
      if (arr | type) == "array" and (arr | length) > 0 then
        title + "\n" + (arr | to_entries | map((.key + 1 | tostring) + ". " + (.value | tostring)) | join("\n"))
      else
        title + "\n1. Нет данных"
      end;

    "Проверьте, правильно ли я понял встречу:\n\n" +
    "Ресторан: " + as_text(.restaurant_name; "Не указано") + "\n" +
    "Город: " + as_text(.city; "Не указано") + "\n" +
    "Контакт: " + as_text(.contact_name; "Не указано") + "\n" +
    "Роль: " + as_text(.contact_role; "unknown") + "\n" +
    "Итог встречи: " + as_text(.meeting_result; "unknown") + "\n" +
    "Интерес: " + as_text(.interest_level; "unknown") + " (score: " + ((.interest_score_1_5 // 0) | tostring) + ")\n" +
    "Приоритет: " + as_text(.manager_action_priority; "unknown") + "\n\n" +
    "Кратко:\n" + as_text(.short_confirmation_ru; "Нет данных") + "\n\n" +
    list_block("Что зашло:"; .decision_drivers) + "\n\n" +
    list_block("Основные возражения:"; .main_objections) + "\n\n" +
    list_block("Риски:"; .main_risks) + "\n\n" +
    list_block("Запрошенные функции:"; .requested_features) + "\n\n" +
    list_block("Вопросы от респондента:"; .questions_from_prospect) + "\n\n" +
    list_block("Следующие шаги:"; .next_steps) + "\n\n" +
    "Если всё верно — отправьте /yes.\nЕсли нужны правки — отправьте /no и затем текстом, что исправить."
  ' 2>/dev/null || true
}

store_report_to_db() {
  local report_json_path="$1"
  python3 - "${DATABASE_PATH}" "${report_json_path}" <<'PY'
import json
import sqlite3
import sys

db_path, report_path = sys.argv[1], sys.argv[2]
payload = json.loads(open(report_path, encoding="utf-8").read())

con = sqlite3.connect(db_path)
con.execute("PRAGMA foreign_keys = ON;")
con.execute(
    """
    INSERT INTO reports (
      report_id, chat_id, user_id, username, title, notes, transcript, ai_summary, created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """,
    (
        payload["report_id"],
        payload["chat_id"],
        payload["user_id"],
        payload.get("username"),
        payload.get("title"),
        payload.get("notes"),
        payload["transcript"],
        payload["ai_summary"],
        payload["created_at"],
    ),
)
con.executemany(
    """
    INSERT INTO report_attachments (
      report_id, attachment_type, telegram_file_id, stored_path, caption
    ) VALUES (?, ?, ?, ?, ?)
    """,
    [
        (
            payload["report_id"],
            item["attachment_type"],
            item["telegram_file_id"],
            item["stored_path"],
            item.get("caption"),
        )
        for item in payload.get("attachments", [])
    ],
)
con.commit()
con.close()
PY
}

sync_report_to_google_sheet() {
  local report_json_path="$1"
  [[ -n "${GOOGLE_SHEETS_WEBHOOK_URL}" ]] || return 0

  local payload response status body ok msg preview
  payload="$(jq -c --arg token "${GOOGLE_SHEETS_WEBHOOK_TOKEN}" \
    '{token: ($token | if . == "" then null else . end), report: .}' \
    "${report_json_path}" 2>/dev/null || true)"
  if [[ -z "${payload}" ]]; then
    echo "Sheet sync error: failed to build payload from ${report_json_path}"
    return 1
  fi

  response="$(curl -sS --max-time 45 --connect-timeout 10 \
    --retry 1 --retry-delay 1 --retry-all-errors \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    -w $'\nHTTP_STATUS:%{http_code}' \
    "${GOOGLE_SHEETS_WEBHOOK_URL}" 2>/dev/null || true)"

  status="$(echo "${response}" | awk -F: '/^HTTP_STATUS:/{print $2}' | tail -n 1)"
  body="$(echo "${response}" | sed '/^HTTP_STATUS:/d')"

  if [[ ! "${status}" =~ ^[23][0-9][0-9]$ ]]; then
    preview="$(printf '%s' "${body}" | tr '\n' ' ' | cut -c1-240)"
    echo "Sheet sync error: webhook status=${status:-n/a}, body=${preview}"
    return 1
  fi

  if [[ "${status}" != "200" ]]; then
    # Google Apps Script web apps often return redirects after successful doPost.
    return 0
  fi

  ok="$(echo "${body}" | jq -r '.ok // empty' 2>/dev/null || true)"
  if [[ -n "${ok}" && "${ok}" != "true" ]]; then
    msg="$(echo "${body}" | jq -r '.error // .message // "unknown error"' 2>/dev/null || true)"
    echo "Sheet sync error: ${msg:-unknown error}"
    return 1
  fi

  return 0
}

sanitize_summary_json() {
  local summary_json="$1"
  local source_text="$2"
  local summary_file source_file
  summary_file="$(mktemp "${DATA_DIR}/summary_json.XXXXXX")"
  source_file="$(mktemp "${DATA_DIR}/summary_source.XXXXXX")"
  printf '%s' "${summary_json}" > "${summary_file}"
  printf '%s' "${source_text}" > "${source_file}"

  python3 - "${summary_file}" "${source_file}" <<'PY'
import json
import re
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
source_path = Path(sys.argv[2])

try:
    payload = json.loads(summary_path.read_text(encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)

source = source_path.read_text(encoding="utf-8", errors="ignore").lower()
source = re.sub(r"\s+", " ", source).strip()

list_fields = [
    "decision_drivers",
    "main_objections",
    "main_risks",
    "requested_features",
    "questions_from_prospect",
    "next_steps",
    "summary_for_team",
]

fallback_values = {"нет данных", "unknown", "не указано", "n/a"}

field_intents = {
    "requested_features": [
        r"\b(просил|просили|просит|запросил|запросили|запрос|нужн[аоы]?|добав(ить|ьте|ка)|функц(ия|ии)|хотел(ось|и)?\b)",
        r"\b(feature|features|request)\b",
    ],
    "questions_from_prospect": [
        r"\b(спросил|спросили|вопрос|вопросы|интересовался|уточнил|уточнили)\b",
        r"\?",
    ],
    "main_objections": [
        r"\b(возраж|отказ|не готов|неинтерес|дорого|сложн|не нужно|неудобно|не подходит|не хотят?)\b",
    ],
    "main_risks": [
        r"\b(риск|опасен|опасение|сомнен|проблем|тревог|боязн|страх)\b",
    ],
    "next_steps": [
        r"\b(следующ|дальше|созвон|контакт|написать|вернуться|договорил|план|сделать)\b",
    ],
}

def has_intent(field: str) -> bool:
    patterns = field_intents.get(field, [])
    if not patterns:
        return True
    return any(re.search(p, source) for p in patterns)

def keep_item(item: str) -> bool:
    txt = re.sub(r"\s+", " ", (item or "").strip().lower())
    if not txt:
        return False
    if txt in fallback_values:
        return True
    if source and txt in source:
        return True
    tokens = [t for t in re.findall(r"[a-zа-я0-9]{4,}", txt) if t not in {"salu", "salutips"}]
    if not tokens:
        return False
    matched = sum(1 for t in tokens[:8] if t in source)
    needed = max(1, min(3, (len(tokens) + 1) // 2))
    return matched >= needed

for field in list_fields:
    raw = payload.get(field)
    items = raw if isinstance(raw, list) else []
    cleaned = []
    if not has_intent(field):
        payload[field] = ["Нет данных"]
        continue
    for item in items:
        if isinstance(item, str):
            normalized = item.strip()
            if keep_item(normalized):
                cleaned.append(normalized)
    cleaned = cleaned[:5]
    if not cleaned:
        cleaned = ["Нет данных"]
    payload[field] = cleaned

score = payload.get("interest_score_1_5", 0)
try:
    score = int(score)
except Exception:
    score = 0
if score < 0 or score > 5:
    score = 0
payload["interest_score_1_5"] = score

for key in ("restaurant_name", "city", "contact_name", "short_confirmation_ru"):
    value = payload.get(key)
    if not isinstance(value, str):
        payload[key] = "Нет данных"
    else:
        payload[key] = value.strip() or "Нет данных"

enum_defaults = {
    "contact_role": {"waiter", "bartender", "owner", "manager", "other", "unknown"},
    "meeting_result": {"connected_now", "follow_up", "declined", "unknown"},
    "interest_level": {"high", "medium", "low", "unknown"},
    "manager_action_priority": {"hot", "warm", "cold", "unknown"},
}
for key, allowed in enum_defaults.items():
    value = payload.get(key)
    if not isinstance(value, str) or value not in allowed:
        payload[key] = "unknown"

print(json.dumps(payload, ensure_ascii=False))
PY

  local status=$?
  rm -f "${summary_file}" "${source_file}"
  return "${status}"
}

finalize_draft() {
  local chat_id="$1"
  local user_id="$2"
  local path="$3"

  if [[ ! -f "${path}" ]]; then
    send_message "${chat_id}" "Черновик пуст. Отправьте материалы для отчета."
    return
  fi

  if draft_has_pending_report "${path}"; then
    send_message "${chat_id}" "У вас уже есть отчет на подтверждении. Отправьте /yes для сохранения или /no для правок."
    return
  fi

  if ! draft_has_content "${path}"; then
    send_message "${chat_id}" "Черновик пуст. Отправьте материалы для отчета."
    return
  fi

  send_message "${chat_id}" "Обрабатываю отчет. Это может занять до минуты."

  local report_id
  report_id="$(date -u +%Y%m%d-%H%M%S)-$(openssl rand -hex 4)"
  local report_dir="${STORAGE_DIR}/${report_id}"
  mkdir -p "${report_dir}"

  local draft_json
  draft_json="$(cat "${path}")"

  local attachments='[]'
  local transcript_chunks='[]'
  local i=0

  while IFS= read -r voice_id; do
    [[ -z "${voice_id}" ]] && continue
    i=$((i + 1))
    local voice_path="${report_dir}/voice_${i}.ogg"
    if download_telegram_file "${voice_id}" "${voice_path}"; then
      :
    else
      echo "" > "${voice_path}"
    fi
    local transcript
    transcript="$(transcribe_audio "${voice_path}")"
    local chunk="[Голосовое ${i}]
${transcript}"
    transcript_chunks="$(echo "${transcript_chunks}" | jq --arg chunk "${chunk}" '. + [$chunk]')"
    attachments="$(echo "${attachments}" | jq \
      --arg fid "${voice_id}" \
      --arg path "${voice_path}" \
      '. + [{attachment_type:"voice",telegram_file_id:$fid,stored_path:$path,caption:null}]')"
  done < <(echo "${draft_json}" | jq -r '.voice_file_ids[]?')

  i=0
  local photo_ids_json captions_json
  photo_ids_json="$(echo "${draft_json}" | jq '.photo_file_ids')"
  captions_json="$(echo "${draft_json}" | jq '.photo_captions')"
  local photo_count
  photo_count="$(echo "${photo_ids_json}" | jq 'length')"
  while [[ "${i}" -lt "${photo_count}" ]]; do
    local photo_id caption photo_path
    photo_id="$(echo "${photo_ids_json}" | jq -r ".[$i] // empty")"
    caption="$(echo "${captions_json}" | jq -r ".[$i] // empty")"
    photo_path="${report_dir}/photo_$((i + 1)).jpg"
    download_telegram_file "${photo_id}" "${photo_path}" || true
    attachments="$(echo "${attachments}" | jq \
      --arg fid "${photo_id}" \
      --arg path "${photo_path}" \
      --arg caption "${caption}" \
      '. + [{attachment_type:"photo",telegram_file_id:$fid,stored_path:$path,caption:($caption|if .=="" then null else . end)}]')"
    i=$((i + 1))
  done

  local transcript_text
  transcript_text="$(echo "${transcript_chunks}" | jq -r 'if length==0 then "Голосовых сообщений не было." else join("\n\n") end')"
  local title notes
  title="$(echo "${draft_json}" | jq -r '.title // empty')"
  notes="$(echo "${draft_json}" | jq -r '(.notes // []) | join("\n")')"
  if [[ -z "${notes}" ]]; then
    notes=""
  fi

  local ai_summary_raw ai_summary_json ai_summary summary_source
  ai_summary_raw="$(build_summary "${transcript_text}" "${title}" "${notes}")"
  ai_summary_json="$(extract_json_payload "${ai_summary_raw}")"
  if [[ -n "${ai_summary_json}" ]]; then
    summary_source="${title}"$'\n'"${notes}"$'\n'"${transcript_text}"
    ai_summary="$(sanitize_summary_json "${ai_summary_json}" "${summary_source}" || true)"
    if [[ -z "${ai_summary}" ]]; then
      ai_summary="${ai_summary_json}"
    fi
  else
    ai_summary="${ai_summary_raw}"
  fi

  local created_at
  created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local report_json_path="${report_dir}/report.json"
  jq -n \
    --arg report_id "${report_id}" \
    --argjson chat_id "${chat_id}" \
    --argjson user_id "${user_id}" \
    --arg username "$(echo "${draft_json}" | jq -r '.username // empty')" \
    --arg title "${title}" \
    --arg notes "${notes}" \
    --arg transcript "${transcript_text}" \
    --arg ai_summary "${ai_summary}" \
    --arg created_at "${created_at}" \
    --argjson attachments "${attachments}" \
    '{
      report_id:$report_id,
      chat_id:$chat_id,
      user_id:$user_id,
      username:($username | if .=="" then null else . end),
      title:($title | if .=="" then null else . end),
      notes:($notes | if .=="" then null else . end),
      transcript:$transcript,
      ai_summary:$ai_summary,
      created_at:$created_at,
      attachments:$attachments
    }' > "${report_json_path}"

  set_draft_pending_report "${path}" "${report_json_path}" "${report_id}"

  local confirmation_text
  confirmation_text="$(format_summary_confirmation "${ai_summary}")"
  if [[ -z "${confirmation_text}" ]]; then
    confirmation_text="Не удалось собрать подтверждение автоматически. Отправьте /yes для сохранения или /no для правок."
  fi

  local preview
  preview="$(printf '%s' "${confirmation_text}" | cut -c1-3600)"
  send_message "${chat_id}" "Черновик отчета готов: ${report_id}

${preview}"
}

confirm_pending_report() {
  local chat_id="$1"
  local path="$2"
  if ! draft_has_pending_report "${path}"; then
    send_message "${chat_id}" "Нет отчета на подтверждении. Отправьте материалы и /done."
    return
  fi

  local report_json_path report_id
  report_json_path="$(jq -r '.pending_report_json_path // empty' "${path}")"
  report_id="$(jq -r '.pending_report_id // empty' "${path}")"
  if [[ -z "${report_json_path}" || ! -f "${report_json_path}" ]]; then
    clear_draft_pending_report "${path}"
    send_message "${chat_id}" "Черновик подтверждения поврежден. Отправьте /done, чтобы собрать заново."
    return
  fi

  if store_report_to_db "${report_json_path}"; then
    local sync_suffix=""
    if [[ -n "${GOOGLE_SHEETS_WEBHOOK_URL}" ]]; then
      if sync_report_to_google_sheet "${report_json_path}"; then
        sync_suffix=$'\nGoogle Sheet: синхронизировано.'
      else
        sync_suffix=$'\nGoogle Sheet: ошибка синхронизации (см. логи рантайма).'
      fi
    fi
    rm -f "${path}"
    send_message "${chat_id}" "Спасибо! Отчет сохранен в базу: ${report_id}${sync_suffix}"
  else
    send_message "${chat_id}" "Не удалось сохранить отчет в базу. Повторите /yes или отправьте /no для правок."
  fi
}

reject_pending_report() {
  local chat_id="$1"
  local path="$2"
  local correction="${3:-}"
  if ! draft_has_pending_report "${path}"; then
    send_message "${chat_id}" "Сейчас нет отчета на подтверждении. Просто отправьте /done после материалов."
    return
  fi

  if [[ -n "${correction}" ]]; then
    append_note_to_draft "${path}" "Правка менеджера: ${correction}"
  else
    clear_draft_pending_report "${path}"
  fi

  clear_draft_pending_report "${path}"
  send_message "${chat_id}" "Принял правки. Дополните детали и отправьте /done для новой версии отчета."
}

is_affirmative_text() {
  local raw="${1:-}"
  local t
  t="$(echo "${raw}" | tr '[:upper:]' '[:lower:]')"
  t="$(trim_ws "${t}")"
  case "${t}" in
    "/yes"|"/confirm"|"yes"|"y"|"ok"|"да"|"верно"|"подтверждаю"|"согласен")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_negative_text() {
  local raw="${1:-}"
  local t
  t="$(echo "${raw}" | tr '[:upper:]' '[:lower:]')"
  t="$(trim_ws "${t}")"
  case "${t}" in
    "/no"|"/reject"|"no"|"n"|"нет"|"неверно"|"исправить"|"правки")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

handle_start() {
  local chat_id="$1"
  send_message "${chat_id}" "Бот готов принимать отчеты.

Сценарий:
1) Отправьте название заведения и имя/роль контакта
2) Пришлите голосовое и/или фото
3) Отправьте /done, когда отчет завершен
4) Подтвердите итог: /yes (сохранить) или /no (исправить)

Коротко, что сказать в голосовом:
- кто был на встрече и какая роль
- был ли интерес и подключение (да/нет/позже)
- ключевые возражения/риски
- какие функции или условия попросили
- какие следующие шаги

Команды: /done, /yes, /no, /cancel, /help"
}

handle_help() {
  local chat_id="$1"
  send_message "${chat_id}" "Пришлите материалы в любом порядке: текст, фото, голосовые. Затем /done.

Чтобы отчет был точным, в голосовом закройте 5 пунктов:
1) Контакт и роль
2) Интерес/результат (подключили или нет)
3) Возражения и риски
4) Запрошенные функции/условия
5) Следующие шаги

После этого бот соберет черновик и попросит подтверждение: /yes или /no."
}

process_update() {
  local update_json="$1"
  local msg_json chat_id user_id username

  msg_json="$(echo "${update_json}" | jq -c '.message // empty')"
  [[ -z "${msg_json}" ]] && return

  chat_id="$(echo "${msg_json}" | jq -r '.chat.id // empty')"
  user_id="$(echo "${msg_json}" | jq -r '.from.id // empty')"
  username="$(echo "${msg_json}" | jq -r '.from.username // empty')"

  [[ -z "${chat_id}" || -z "${user_id}" ]] && return

  if ! is_allowed_user "${username}"; then
    send_message "${chat_id}" "У вас нет доступа к этому боту."
    return
  fi

  local text command draft_file
  text="$(echo "${msg_json}" | jq -r '.text // empty')"
  draft_file="$(draft_path "${chat_id}" "${user_id}")"

  local has_pending="0"
  if draft_has_pending_report "${draft_file}"; then
    has_pending="1"
  fi

  if [[ -n "${text}" && "${text}" == /* ]]; then
    command="${text%% *}"
    command="${command%%@*}"
    command="$(echo "${command}" | tr '[:upper:]' '[:lower:]')"
    local command_tail=""
    if [[ "${text}" == *" "* ]]; then
      command_tail="$(trim_ws "${text#* }")"
    fi
    case "${command}" in
      /start) handle_start "${chat_id}" ;;
      /help) handle_help "${chat_id}" ;;
      /cancel)
        rm -f "${draft_file}"
        send_message "${chat_id}" "Черновик удален."
        ;;
      /done)
        if [[ "${has_pending}" == "1" ]]; then
          send_message "${chat_id}" "У вас уже есть отчет на подтверждении. Отправьте /yes для сохранения или /no для правок."
        else
          finalize_draft "${chat_id}" "${user_id}" "${draft_file}"
        fi
        ;;
      /yes|/confirm) confirm_pending_report "${chat_id}" "${draft_file}" ;;
      /no|/reject) reject_pending_report "${chat_id}" "${draft_file}" "${command_tail}" ;;
      *) ;;
    esac
    return
  fi

  if [[ "${has_pending}" == "1" ]]; then
    if is_affirmative_text "${text}"; then
      confirm_pending_report "${chat_id}" "${draft_file}"
    elif is_negative_text "${text}"; then
      reject_pending_report "${chat_id}" "${draft_file}" ""
    elif [[ -n "${text}" ]]; then
      reject_pending_report "${chat_id}" "${draft_file}" "${text}"
    else
      send_message "${chat_id}" "Отправьте /yes для сохранения или /no и текст правок."
    fi
    return
  fi

  local lower_text
  lower_text="$(echo "${text}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${lower_text}" == "done" || "${lower_text}" == "готово" ]]; then
    finalize_draft "${chat_id}" "${user_id}" "${draft_file}"
    return
  fi

  local voice_id photo_id caption
  voice_id="$(echo "${msg_json}" | jq -r '.voice.file_id // empty')"
  photo_id="$(echo "${msg_json}" | jq -r '.photo | if type=="array" and length>0 then .[-1].file_id else empty end')"
  caption="$(echo "${msg_json}" | jq -r '.caption // empty')"

  if [[ -n "${text}" ]]; then
    ensure_draft "${draft_file}" "${chat_id}" "${user_id}" "${username}"
    local had_title
    had_title="$(jq -r 'if .title == null or .title == "" then "0" else "1" end' "${draft_file}")"
    set_draft_title_or_note "${draft_file}" "${text}"
    if [[ "${had_title}" == "0" ]]; then
      send_message "${chat_id}" "Название отчета сохранено."
    else
      send_message "${chat_id}" "Текстовая заметка добавлена в черновик."
    fi
    return
  fi

  if [[ -n "${photo_id}" ]]; then
    ensure_draft "${draft_file}" "${chat_id}" "${user_id}" "${username}"
    append_photo_to_draft "${draft_file}" "${photo_id}" "${caption}"
    send_message "${chat_id}" "Фото добавлено в черновик."
    return
  fi

  if [[ -n "${voice_id}" ]]; then
    ensure_draft "${draft_file}" "${chat_id}" "${user_id}" "${username}"
    append_voice_to_draft "${draft_file}" "${voice_id}"
    send_message "${chat_id}" "Голосовое добавлено. Отправьте /done, когда закончите."
    return
  fi
}

main_loop() {
  init_schema
  local lock_dir="${RUNTIME_PREFIX}.lock"
  local pid_file="${RUNTIME_PREFIX}.pid"

  if ! mkdir "${lock_dir}" 2>/dev/null; then
    local existing_pid=""
    local existing_pid_alive="0"
    if [[ -f "${pid_file}" ]]; then
      existing_pid="$(cat "${pid_file}" 2>/dev/null || true)"
      if [[ "${existing_pid}" =~ ^[0-9]+$ ]] && kill -0 "${existing_pid}" 2>/dev/null; then
        existing_pid_alive="1"
      fi
    fi

    if [[ "${existing_pid_alive}" == "1" ]] && is_recent_heartbeat 60; then
      local hb_age
      hb_age="$(heartbeat_age_seconds)"
      echo "Another bot process is likely running (lock=${lock_dir}, pid=${existing_pid}, heartbeat_age=${hb_age}s)."
      exit 1
    fi

    # Stale lock recovery after unclean exit or forced termination.
    rm -f "${pid_file}"
    rmdir "${lock_dir}" 2>/dev/null || true
    if ! mkdir "${lock_dir}" 2>/dev/null; then
      echo "Unable to recover bot lock (${lock_dir}). If needed, remove lock manually and retry."
      exit 1
    fi
    echo "Recovered stale lock: ${lock_dir}"
  fi

  rm -f "${STOP_FILE}"
  echo "$$" > "${pid_file}"
  trap "rmdir '${lock_dir}' 2>/dev/null || true; rm -f '${pid_file}'" EXIT

  local offset_file="${DATA_DIR}/offset_${BOT_INSTANCE_ID}.txt"
  local legacy_offset_file="${DATA_DIR}/offset.txt"
  local offset=0
  if [[ -f "${offset_file}" ]]; then
    offset="$(cat "${offset_file}" 2>/dev/null || echo 0)"
  elif [[ -f "${legacy_offset_file}" ]]; then
    offset="$(cat "${legacy_offset_file}" 2>/dev/null || echo 0)"
  fi

  echo "Bot polling started at $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if [[ -n "${OPENAI_API_KEY}" ]]; then
    echo "Config: OPENAI_API_KEY_PRESENT=1, CONFIRM_BEFORE_SAVE=${CONFIRM_BEFORE_SAVE}"
  else
    echo "Config: OPENAI_API_KEY_PRESENT=0, CONFIRM_BEFORE_SAVE=${CONFIRM_BEFORE_SAVE}"
  fi
  write_heartbeat "${offset}" "started"
  local conflict_count=0
  while true; do
    if [[ -f "${STOP_FILE}" ]]; then
      echo "Stop request detected. Shutting down bot loop."
      rm -f "${STOP_FILE}"
      break
    fi

    local payload response ok quick_payload
    payload="$(jq -n --argjson offset "${offset}" '{offset:$offset, timeout:25}')"
    write_heartbeat "${offset}" "polling"
    tg_get_updates "${payload}" || true
    response="${TG_LAST_RESPONSE}"
    if [[ -z "${response}" ]]; then
      quick_payload="$(jq -n --argjson offset "${offset}" '{offset:$offset, timeout:0}')"
      tg_get_updates "${quick_payload}" || true
      response="${TG_LAST_RESPONSE}"
    fi
    if [[ "${POLL_DEBUG}" == "1" ]]; then
      echo "Poll debug: offset=${offset}, response_len=${#response}"
    fi
    ok="$(echo "${response}" | jq -r '.ok // false' 2>/dev/null || echo "false")"
    if [[ "${ok}" != "true" ]]; then
      local err_desc raw_preview
      err_desc="$(echo "${response}" | jq -r '.description // empty' 2>/dev/null || true)"
      if [[ -n "${err_desc}" ]]; then
        echo "Poll error: ${err_desc}"
        if [[ "${err_desc}" == *"terminated by other getUpdates request"* ]]; then
          conflict_count=$((conflict_count + 1))
          if (( conflict_count >= 5 )); then
            echo "Conflict detected repeatedly. Exiting to avoid duplicate processing."
            break
          fi
        else
          conflict_count=0
        fi
      elif [[ -n "${TG_LAST_CURL_ERROR}" ]]; then
        echo "Poll error: ${TG_LAST_CURL_ERROR}"
        conflict_count=0
      elif [[ -n "${response}" ]]; then
        raw_preview="$(printf '%s' "${response}" | tr '\n' ' ' | cut -c1-240)"
        echo "Poll error: non-JSON response preview: ${raw_preview}"
        conflict_count=0
      else
        echo "Poll error: empty or non-JSON response"
        conflict_count=0
      fi
      write_heartbeat "${offset}" "poll_error"
      sleep 2
      continue
    fi

    conflict_count=0
    write_heartbeat "${offset}" "poll_ok"
    local result_count
    result_count="$(echo "${response}" | jq -r '(.result | length) // 0' 2>/dev/null || echo "0")"
    if [[ "${result_count}" == "0" ]]; then
      write_heartbeat "${offset}" "idle"
      sleep 1
      continue
    fi
    while IFS= read -r update_json; do
      [[ -z "${update_json}" ]] && continue
      local update_id
      update_id="$(echo "${update_json}" | jq -r '.update_id // empty')"
      if [[ -n "${update_id}" ]]; then
        offset=$((update_id + 1))
        echo "${offset}" > "${offset_file}"
        write_heartbeat "${offset}" "processing_update"
      fi
      process_update "${update_json}"
    done < <(echo "${response}" | jq -c '.result[]?')
    write_heartbeat "${offset}" "idle"
  done
}

main_loop
