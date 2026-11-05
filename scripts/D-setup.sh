#!/bin/bash
# =============================================================================
# scripts/D-setup.sh — bootstrap D по прямому SSH A -> D (LAN)
# Версия: 3.2.0   2026-11-5
# Автор: @smg38
#
# Назначение:
#   Когда A видит D напрямую по LAN (IP_D:22), этот скрипт копирует
#   build/D/D-install.run на D и запускает его. Всё остальное (ключ D->C,
#   авторизация на C, tunnel.service, mihomo.service, тесты) делает
#   сам install.sh внутри D-install.run НА D.
#
#   Если A НЕ видит D — этот скрипт не нужен. Вместо него:
#     1. scripts/build-servers.sh D --build
#     2. scripts/build-servers.sh D --publish
#     3. На D: curl -fsSL <URL> -o /tmp/D-install.run
#              echo "<SHA256>  /tmp/D-install.run" | sha256sum -c -
#              sh /tmp/D-install.run
#
# Использование (на A):
#   scripts/D-setup.sh [--dry-run] [--skip-tests]
#
#   --dry-run     показать, что будет сделано, не выполняя
#   --skip-tests  передать --skip-tests в install.sh на D
#
# Предусловия:
#   - build/keys/params.env содержит IP_D, REMOTE_USER
#   - build/D/D-install.run существует (build-servers.sh D --build)
#   - A видит D по IP_D:22
#   - SSH-ключ A -> D настроен (root@IP_D)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARAMS_ENV="$PROJECT_ROOT/build/keys/params.env"
INSTALLER="$PROJECT_ROOT/build/D/D-install.run"
INSTALLER_SHA="$INSTALLER.sha256"
ENV_LIB="$PROJECT_ROOT/deploy/lib/env.sh"

DRY_RUN=false
EXTRA_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --skip-tests) EXTRA_ARGS+=(--skip-tests) ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный аргумент: $arg" >&2; exit 1 ;;
    esac
done

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
load_env_file "$PARAMS_ENV" || fail "Не удалось загрузить $PARAMS_ENV"

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
log "Проверка SHA256 D-install.run"
if [[ -f "$INSTALLER_SHA" ]]; then
    expected=$(awk '{print $1}' "$INSTALLER_SHA")
    actual=$(sha256sum "$INSTALLER" | awk '{print $1}')
    [[ "$expected" == "$actual" ]] || fail "SHA256 не совпадает: expected=$expected actual=$actual"
    ok "SHA256 OK: $actual"
else
    warn "Нет $INSTALLER_SHA — пропускаю проверку"
fi

# --- Копирование на D ---
log "Копирование D-install.run на D"
run scp -q "$INSTALLER" "$REMOTE_USER@$IP_D:/tmp/D-install.run"
ok "D:/tmp/D-install.run"

# --- Запуск install.sh на D ---
log "Запуск установщика на D"
if $DRY_RUN; then
    info "[dry-run] ssh $REMOTE_USER@$IP_D 'sh /tmp/D-install.run ${EXTRA_ARGS[*]:-}'"
else
    ssh -t "$REMOTE_USER@$IP_D" "sh /tmp/D-install.run ${EXTRA_ARGS[*]:-}"
fi

log "Готово"
cat <<EOF

D установлен через прямой SSH A -> D.
Дальше с A:
  scripts/build-servers.sh D --deploy    # обновления через ProxyCommand C
  scripts/diagnose.sh                    # проверки

Настройте LAN (шлюз и DNS = IP_D).
EOF