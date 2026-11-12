#!/bin/bash
# =============================================================================
# scripts/D-setup.sh — bootstrap D по прямому SSH A -> D (LAN)
# Версия: 3.3.0   2026-11-07
# Автор: @smg38
#
# Назначение:
#   Когда A видит D напрямую по LAN (IP_D:22), этот скрипт копирует
#   build/<ID>/D-install.run (или <ID>-install.run) на D и запускает его. Всё остальное (ключ D->C,
#   авторизация на C, tunnel.service, mihomo.service, тесты) делает
#   сам install.sh внутри D-install.run НА D.
#
#   Если A НЕ видит D — этот скрипт не нужен. Вместо него:
#     1. scripts/build-servers.sh D --instance ID --build
#     2. scripts/build-servers.sh D --instance ID --publish
#     3. На D: curl -fsSL <URL> -o /tmp/ID-install.run
#              echo "<SHA256>  /tmp/ID-install.run" | sha256sum -c -
#              sh /tmp/ID-install.run
#
# Использование (на A):
#   scripts/D-setup.sh [--instance ID] [--dry-run] [--skip-tests]
#
#   --dry-run     показать, что будет сделано, не выполняя
#   --skip-tests  передать --skip-tests в install.sh на D
#
# Предусловия:
#   - build/keys/params.env содержит IP_D, REMOTE_USER
#   - установщик build/<ID>/ существует (build-servers.sh D --instance ID --build)
#   - A видит D по IP_D:22
#   - SSH-ключ A -> D настроен (root@IP_D)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARAMS_ENV="$PROJECT_ROOT/build/keys/params.env"
ENV_LIB="$PROJECT_ROOT/deploy/lib/env.sh"
INSTANCE_DIR="$PROJECT_ROOT/build/instances"

DRY_RUN=false
INSTANCE_ID=D
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true ;;
        --skip-tests) EXTRA_ARGS+=(--skip-tests) ;;
        --instance)
            [[ $# -ge 2 ]] || { echo "--instance требует ID" >&2; exit 1; }
            INSTANCE_ID="$2"
            shift
            ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
    shift
done

[[ "$INSTANCE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_]*$ ]] || { echo "Недопустимый ID: $INSTANCE_ID" >&2; exit 1; }
if [[ "$INSTANCE_ID" != D ]]; then
    [[ -f "$INSTANCE_DIR/$INSTANCE_ID.env" ]] || { echo "Нет $INSTANCE_DIR/$INSTANCE_ID.env" >&2; exit 1; }
fi
D_BUILD_DIR="$PROJECT_ROOT/build/$INSTANCE_ID"
INSTALLER_NAME=D-install.run
[[ "$INSTANCE_ID" == D ]] || INSTALLER_NAME="$INSTANCE_ID-install.run"
INSTALLER="$D_BUILD_DIR/$INSTALLER_NAME"
INSTALLER_SHA="$INSTALLER.sha256"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m⚠\033[0m %s\n' "$*" >&2; }
fail() { printf '  \033[0;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if $DRY_RUN; then echo "  [dry-run] $*"; else "$@"; fi; }

# --- Предусловия ---
log "Проверка предусловий"
for f in "$PARAMS_ENV" "$INSTALLER" "$ENV_LIB"; do
    [[ -f "$f" ]] || fail "Нет $f (сначала: scripts/build-servers.sh D --build)"
    ok "$f"
done

# shellcheck disable=SC1090
source "$ENV_LIB"
load_env_file_literal "$PARAMS_ENV" || fail "Не удалось загрузить $PARAMS_ENV"
if [[ "$INSTANCE_ID" != D ]]; then
    validate_d_instance_file "$INSTANCE_DIR/$INSTANCE_ID.env" || fail "Ошибка в настройках экземпляра $INSTANCE_ID"
    load_env_file_literal "$INSTANCE_DIR/$INSTANCE_ID.env" || fail "Не удалось загрузить настройки $INSTANCE_ID"
fi

: "${IP_D:?IP_D не задан в params.env}"
: "${REMOTE_USER:=root}"
ok "IP_D=$IP_D  REMOTE_USER=$REMOTE_USER"

# --- Проверка связности A -> D (LAN) ---
log "Проверка SSH A -> D ($REMOTE_USER@$IP_D:22)"
if ! $DRY_RUN; then
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_USER@$IP_D" true 2>/dev/null; then
        fail "SSH $REMOTE_USER@$IP_D недоступен. Если A не видит D — используйте канал через C (см. docs/D-deployment.md §6.2)"
    fi
    ok "A -> D OK"
else
    info "[dry-run] ssh $REMOTE_USER@$IP_D true"
fi

# --- Проверка SHA256 установщика ---
log "Проверка SHA256 $INSTALLER_NAME"
if [[ -f "$INSTALLER_SHA" ]]; then
    expected=$(awk '{print $1}' "$INSTALLER_SHA")
    actual=$(sha256sum "$INSTALLER" | awk '{print $1}')
    [[ "$expected" == "$actual" ]] || fail "SHA256 не совпадает: expected=$expected actual=$actual"
    ok "SHA256 OK: $actual"
else
    warn "Нет $INSTALLER_SHA — пропускаю проверку"
fi

# --- Копирование на D ---
log "Копирование $INSTALLER_NAME на D"
run scp -q "$INSTALLER" "$REMOTE_USER@$IP_D:/tmp/$INSTALLER_NAME"
ok "D:/tmp/$INSTALLER_NAME"

# --- Запуск install.sh на D ---
log "Запуск установщика на D"
if $DRY_RUN; then
    info "[dry-run] ssh $REMOTE_USER@$IP_D 'sh /tmp/$INSTALLER_NAME ${EXTRA_ARGS[*]:-}'"
else
    ssh -t "$REMOTE_USER@$IP_D" "sh /tmp/$INSTALLER_NAME ${EXTRA_ARGS[*]:-}"
fi

log "Готово"
cat <<EOF

D ($INSTANCE_ID) установлен через прямой SSH A -> D.
Дальше с A:
  scripts/build-servers.sh D --instance $INSTANCE_ID --deploy    # обновления через ProxyCommand C
  scripts/D-diagnose.sh --instance $INSTANCE_ID                 # проверки

Настройте LAN (шлюз и DNS = IP_D).
EOF