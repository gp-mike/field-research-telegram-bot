#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${ROOT_DIR}/data"
ENV_FILE="${ROOT_DIR}/.env"
RUN_SCRIPT="${ROOT_DIR}/scripts/run_telegram_bot.sh"
RUNNING_MAX_HEARTBEAT_AGE="${RUNNING_MAX_HEARTBEAT_AGE:-60}"

mkdir -p "${DATA_DIR}"

read_env_value() {
  local key="$1"
  [[ -f "${ENV_FILE}" ]] || { echo ""; return 0; }
  awk -F= -v k="${key}" '
    $0 ~ /^[[:space:]]*#/ {next}
    $1 ~ /^[[:space:]]*$/ {next}
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      if ($1 == k) {
        $1=""
        sub(/^=/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 ~ /^".*"$/ || $0 ~ /^'\''.*'\''$/) {
          print substr($0,2,length($0)-2)
        } else {
          print $0
        }
        exit
      }
    }
  ' "${ENV_FILE}"
}

TELEGRAM_BOT_TOKEN="$(read_env_value TELEGRAM_BOT_TOKEN)"
if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
  BOT_INSTANCE_ID="${BOT_INSTANCE_ID:-$(printf '%s' "${TELEGRAM_BOT_TOKEN}" | shasum | awk '{print substr($1,1,8)}')}"
else
  BOT_INSTANCE_ID="${BOT_INSTANCE_ID:-default}"
fi

RUNTIME_PREFIX="${DATA_DIR}/bot_${BOT_INSTANCE_ID}"
PID_FILE="${RUNTIME_PREFIX}.pid"
LOCK_DIR="${RUNTIME_PREFIX}.lock"
LOG_FILE="${RUNTIME_PREFIX}.log"
HEARTBEAT_FILE="${RUNTIME_PREFIX}.heartbeat"
STOP_FILE="${RUNTIME_PREFIX}.stop"

heartbeat_age() {
  [[ -f "${HEARTBEAT_FILE}" ]] || { echo "-1"; return 0; }
  local ts now
  ts="$(cut -d'|' -f1 "${HEARTBEAT_FILE}" 2>/dev/null || true)"
  [[ "${ts}" =~ ^[0-9]+$ ]] || { echo "-1"; return 0; }
  now="$(date +%s)"
  echo $((now - ts))
}

heartbeat_offset() {
  [[ -f "${HEARTBEAT_FILE}" ]] || { echo ""; return 0; }
  cut -d'|' -f2 "${HEARTBEAT_FILE}" 2>/dev/null || true
}

heartbeat_state() {
  [[ -f "${HEARTBEAT_FILE}" ]] || { echo ""; return 0; }
  cut -d'|' -f3 "${HEARTBEAT_FILE}" 2>/dev/null || true
}

read_pid() {
  [[ -f "${PID_FILE}" ]] || { echo ""; return 0; }
  cat "${PID_FILE}" 2>/dev/null || true
}

pid_is_alive() {
  local pid="${1:-}"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null
}

is_running() {
  local age pid
  age="$(heartbeat_age)"
  pid="$(read_pid)"
  [[ -d "${LOCK_DIR}" ]] \
    && [[ "${age}" =~ ^-?[0-9]+$ ]] \
    && (( age >= 0 && age <= RUNNING_MAX_HEARTBEAT_AGE )) \
    && pid_is_alive "${pid}"
}

has_stale_artifacts() {
  [[ -d "${LOCK_DIR}" || -f "${PID_FILE}" ]]
}

cleanup_stale_state() {
  if is_running; then
    return 0
  fi
  rm -f "${PID_FILE}" "${STOP_FILE}" "${HEARTBEAT_FILE}"
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}

stop_competing_processes() {
  local current_pid pids pid
  current_pid="$(read_pid)"

  if ! command -v pgrep >/dev/null 2>&1; then
    return 0
  fi

  pids="$(pgrep -f "${RUN_SCRIPT}" 2>/dev/null || true)"
  [[ -n "${pids}" ]] || return 0

  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    if [[ -n "${current_pid}" && "${pid}" == "${current_pid}" ]]; then
      continue
    fi
    kill "${pid}" 2>/dev/null || true
    sleep 0.2
    kill -9 "${pid}" 2>/dev/null || true
  done <<< "${pids}"
}

status_cmd() {
  local age state offset pid pid_alive
  age="$(heartbeat_age)"
  state="$(heartbeat_state)"
  offset="$(heartbeat_offset)"
  pid="$(read_pid)"
  if pid_is_alive "${pid}"; then
    pid_alive="1"
  else
    pid_alive="0"
  fi

  if is_running; then
    echo "running (pid=${pid}, heartbeat_age=${age}s, state=${state:-unknown}, offset=${offset:-n/a})"
    return 0
  fi
  if has_stale_artifacts; then
    echo "stale runtime state detected (pid=${pid:-n/a}, pid_alive=${pid_alive}, heartbeat_age=${age}s, state=${state:-unknown}, offset=${offset:-n/a})"
  else
    echo "stopped"
  fi
}

start_cmd() {
  cleanup_stale_state
  if is_running; then
    status_cmd
    return 0
  fi

  # Avoid Telegram getUpdates conflicts caused by legacy/manual bot processes.
  stop_competing_processes
  cleanup_stale_state

  rm -f "${STOP_FILE}"
  : > "${LOG_FILE}"
  nohup "${RUN_SCRIPT}" >> "${LOG_FILE}" 2>&1 &
  disown || true

  local i
  for i in {1..24}; do
    if is_running; then
      # Ensure process survives startup and does not die shortly after initial heartbeat.
      local j
      for j in {1..10}; do
        sleep 1
        if ! is_running; then
          cleanup_stale_state
          echo "failed to start (bot exited during startup health window)"
          logs_cmd 40
          return 1
        fi
      done
      status_cmd
      return 0
    fi
    sleep 0.5
  done

  cleanup_stale_state
  echo "failed to start (bot did not stay alive after startup)"
  logs_cmd 40
  return 1
}

stop_cmd() {
  local pid
  pid="$(read_pid)"
  if [[ -n "${pid}" ]] && pid_is_alive "${pid}"; then
    touch "${STOP_FILE}"
    local i
    for i in {1..80}; do
      if ! pid_is_alive "${pid}"; then
        break
      fi
      sleep 0.5
    done

    if pid_is_alive "${pid}"; then
      kill "${pid}" 2>/dev/null || true
      for i in {1..20}; do
        if ! pid_is_alive "${pid}"; then
          break
        fi
        sleep 0.25
      done
    fi

    if pid_is_alive "${pid}"; then
      kill -9 "${pid}" 2>/dev/null || true
    fi
  fi

  cleanup_stale_state
  if [[ -d "${LOCK_DIR}" || -f "${PID_FILE}" ]]; then
    echo "stopped (forced stale cleanup needed)"
  else
    echo "stopped"
  fi
}

restart_cmd() {
  stop_cmd
  start_cmd
}

logs_cmd() {
  local lines="${1:-120}"
  tail -n "${lines}" "${LOG_FILE}" 2>/dev/null || true
}

usage() {
  cat <<'EOF'
Usage: ./scripts/botctl.sh <command>

Commands:
  run          Run bot in foreground (recommended for local debugging)
  start        Start bot in background
  stop         Stop background bot process
  restart      Restart bot
  status       Show bot status
  logs [N]     Show last N log lines (default 120)
EOF
}

cmd="${1:-}"
case "${cmd}" in
  run)
    cleanup_stale_state
    exec "${RUN_SCRIPT}"
    ;;
  start) start_cmd ;;
  stop) stop_cmd ;;
  restart) restart_cmd ;;
  status) status_cmd ;;
  logs) logs_cmd "${2:-120}" ;;
  *) usage; exit 1 ;;
esac
