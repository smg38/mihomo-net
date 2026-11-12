#!/bin/bash
# =============================================================================
# scripts/D-tunnel.sh — reverse SSH tunnel D -> C (управление D через C)
# Версия: 3.3.0   2026-11-07
# Автор: @smg38
#
# Назначение:
#   D за NAT, C имеет публичный IP. D поднимает обратный SSH-туннель на C,
#   пробрасывая C:127.0.0.1:${TUNNEL_REMOTE_PORT} -> D:22.
#   A подключается к C по SSH, оттуда — `ssh -p ${TUNNEL_REMOTE_PORT} localhost`.
#
#   Порт на C слушает ТОЛЬКО 127.0.0.1 (GatewayPorts=no), из интернета недоступен.
#
# Использование:
#   scripts/D-tunnel.sh start    — поднять туннель (foreground; для systemd)
#   scripts/D-tunnel.sh stop     — остановить (по PID_FILE)
#   scripts/D-tunnel.sh restart  — stop + start
#   scripts/D-tunnel.sh --check  — проверить, жив ли туннель (exit 0/1)
#   scripts/D-tunnel.sh --status — показать PID, лог, последние строки
#
# Параметры берутся из build/D/D-config (рендерится из template/D-config.j3):
#   TUNNEL_C_HOST, TUNNEL_C_USER, TUNNEL_C_PORT,
#   TUNNEL_REMOTE_PORT, TUNNEL_KEY
#
# Переменные окружения (опционально):
#   D_TUNNEL_PID_FILE  — по умолчанию /run/tunnel-D.pid
#   D_TUNNEL_LOG_FILE  — по умолчанию /var/log/tunnel-D.log
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
D_CONFIG="${D_CONFIG:-$PROJECT_ROOT/build/D/D-config}"
ENV_LIB="$PROJECT_ROOT/deploy/lib/env.sh"
PID_FILE="${D_TUNNEL_PID_FILE:-/run/tunnel-D.pid}"
LOG_FILE="${D_TUNNEL_LOG_FILE:-/var/log/tunnel-D.log}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf '[%s] ОШИБКА: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# --- Загрузка параметров ---
[[ -f "$D_CONFIG" ]] || { err "Нет $D_CONFIG (сначала: scripts/build-servers.sh D --build)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_LIB"
load_env_file "$D_CONFIG" || { err "Не удалось загрузить $D_CONFIG"; exit 1; }

: "${TUNNEL_C_HOST:?TUNNEL_C_HOST не задан в D-config}"
: "${TUNNEL_C_USER:=root}"
: "${TUNNEL_C_PORT:=22}"
: "${TUNNEL_REMOTE_PORT:=2222}"
: "${TUNNEL_KEY:=/root/.ssh/id_ed25519_tunnel}"
[[ -f "$TUNNEL_KEY" ]] || { err "Нет SSH-ключа: $TUNNEL_KEY (запустите scripts/D-setup.sh на D)"; exit 1; }

SSH_OPTS=(
  -i "$TUNNEL_KEY"
  -p "$TUNNEL_C_PORT"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/root/.ssh/known_hosts_tunnel
  -o GatewayPorts=no
)

# --- Проверка, что туннель жив ---
check_tunnel() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# --- Проверка, что удалённый порт свободен на C ---
remote_port_busy() {
  ssh -i "$TUNNEL_KEY" -p "$TUNNEL_C_PORT" \
    -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/root/.ssh/known_hosts_tunnel \
    "$TUNNEL_C_USER@$TUNNEL_C_HOST" \
    "ss -tln 2>/dev/null | grep -q ':${TUNNEL_REMOTE_PORT} '" 2>/dev/null
}

# --- start (foreground; systemd трекает PID сам) ---
start_tunnel() {
  if check_tunnel; then
    log "Туннель уже запущен (PID $(cat "$PID_FILE"))"
    return 0
  fi
  if remote_port_busy; then
    err "Порт ${TUNNEL_REMOTE_PORT} на C уже занят"
    err "Проверьте: ssh ${TUNNEL_C_USER}@${TUNNEL_C_HOST} 'ss -tlnp | grep ${TUNNEL_REMOTE_PORT}'"
    return 1
  fi

  mkdir -p "$(dirname "$LOG_FILE")"
  log "start tunnel D -> ${TUNNEL_C_HOST}:${TUNNEL_C_PORT} (remote 127.0.0.1:${TUNNEL_REMOTE_PORT})" | tee -a "$LOG_FILE" >&2

  # -N: без команды, только туннель
  # -R 127.0.0.1:PORT:localhost:22 — reverse forward, слушает только loopback на C
  ssh "${SSH_OPTS[@]}" -N -R "127.0.0.1:${TUNNEL_REMOTE_PORT}:localhost:22" \
    "$TUNNEL_C_USER@$TUNNEL_C_HOST" >> "$LOG_FILE" 2>&1 &

  echo $! > "$PID_FILE"
  sleep 2
  if check_tunnel; then
    log "Туннель запущен (PID $(cat "$PID_FILE"))"
    return 0
  fi
  err "Туннель не поднялся, лог: $LOG_FILE"
  tail -20 "$LOG_FILE" >&2 || true
  return 1
}

# --- stop ---
stop_tunnel() {
  if [[ ! -f "$PID_FILE" ]]; then
    log "PID-файл не найден — туннель не запущен"
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  if kill -0 "$pid" 2>/dev/null; then
    log "Остановка туннеля (PID $pid)"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.3
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  log "Туннель остановлен"
}

# --- status ---
status_tunnel() {
  if check_tunnel; then
    echo "Туннель жив (PID $(cat "$PID_FILE"))"
    echo "Лог: $LOG_FILE"
    tail -5 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
    return 0
  fi
  echo "Туннель не работает"
  echo "Лог: $LOG_FILE"
  return 1
}

case "${1:-}" in
  start)    start_tunnel ;;
  stop)     stop_tunnel ;;
  restart)  stop_tunnel; start_tunnel ;;
  --check)  check_tunnel && { echo "OK"; exit 0; } || { echo "FAIL"; exit 1; } ;;
  --status) status_tunnel ;;
  -h|--help|"")
    cat <<EOF
Использование: $0 <команда>

Команды:
  start      Поднять туннель D -> C (foreground; для systemd)
  stop       Остановить (по PID_FILE)
  restart    stop + start
  --check    Проверить, жив ли туннель (exit 0/1)
  --status   Показать PID, лог, последние строки

Параметры: $D_CONFIG
PID_FILE:  $PID_FILE
LOG_FILE:  $LOG_FILE
EOF
    ;;
  *) err "Неизвестная команда: $1"; exit 1 ;;
esac