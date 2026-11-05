#!/bin/bash
# Версия: 3.2.0 2026-11-05
# Скрипт обновления конфигурации.
#
# Работает в двух режимах:
#   1) production  — ядро и менеджер в /usr/local/bin, конфиг в каталоге deploy
#   2) local/dev  — ядро и менеджер в ./.tmp, конфиг в ./.tmp, без sudo и systemd
#
# Режим выбирается автоматически: если /usr/local/bin/mihomo-manager существует —
# production, иначе local.
#

set -euo pipefail
umask 077

# ------------------------------------------------------------------------------
# Определение корневого каталога (где живёт скрипт)
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ------------------------------------------------------------------------------
# Определение режима работы
# ------------------------------------------------------------------------------
if [ -x /usr/local/bin/mihomo-manager ]; then
    MODE="production"
    MIHOMO_MANAGER_BIN="${MIHOMO_MANAGER:-/usr/local/bin/mihomo-manager}"
    MIHOMO_KERNEL_BIN="${MIHOMO_KERNEL:-/usr/local/bin/mihomo}"
    RUNTIME_DIR="${MIHOMO_RUNTIME_DIR:-$PACKAGE_ROOT}"
    PACKAGE_DIR="$PACKAGE_ROOT"
else
    MODE="local"
    RUNTIME_DIR="${MIHOMO_RUNTIME_DIR:-$PACKAGE_ROOT/.tmp}"
    MIHOMO_MANAGER_BIN="${MIHOMO_MANAGER:-$RUNTIME_DIR/mihomo-manager}"
    MIHOMO_KERNEL_BIN="${MIHOMO_KERNEL:-$RUNTIME_DIR/mihomo}"
    PACKAGE_DIR="$PACKAGE_ROOT"
fi

mkdir -p "$RUNTIME_DIR"
cd "$RUNTIME_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf '[%s] ОШИБКА: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# ------------------------------------------------------------------------------
# Обычный вход (не внутренний этап) — передаём управление в менеджер
# ------------------------------------------------------------------------------
case "${1:-}" in
    --prepare|--render) MODE_INTERNAL="$1"; shift ;;
    *)
        if [ ! -x "$MIHOMO_MANAGER_BIN" ]; then
            err "Отсутствует менеджер: $MIHOMO_MANAGER_BIN"
            err "Соберите: ./build.sh"
            exit 1
        fi
        exec "$MIHOMO_MANAGER_BIN" update "$@"
        ;;
esac

[ "${MIHOMO_UPDATE_INTERNAL:-}" = "1" ] || { err "Внутренний этап не может быть вызван напрямую"; exit 1; }

STAGING_DIR="$1"
[ -d "$STAGING_DIR" ] || { err "Нет каталога staging: $STAGING_DIR"; exit 1; }

# ------------------------------------------------------------------------------
# Загрузка окружения
# ------------------------------------------------------------------------------
source "$PACKAGE_DIR/lib/env.sh"
source "$PACKAGE_DIR/lib/http.sh"

SOURCE_DIR="${MIHOMO_SOURCE_DIR:-$RUNTIME_DIR}"
ENV_FILE="${MIHOMO_ENV_FILE:-$SOURCE_DIR/.env}"

if ! load_env_file "$ENV_FILE"; then
    err "Файл .env не найден: $ENV_FILE"
    exit 1
fi

# ------------------------------------------------------------------------------
# Конфигурация
# ------------------------------------------------------------------------------
CN_CIDR_URL="${CN_CIDR_URL:-https://cdn.jsdelivr.net/gh/gaoyifan/china-operator-ip@ip-lists/china.txt}"
#RU_CIDR_URL="${RU_CIDR_URL:-https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.txt}"
RU_CIDR_URL="${RU_CIDR_URL:-https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru/ipv4-aggregated.txt}"

CIDR_FILE_CN="${STAGING_DIR}/cn_cidr.txt"
CIDR_FILE_RU="${STAGING_DIR}/ru_cidr.txt"
CIDR_TS_FILE="${STAGING_DIR}/.cidr_timestamp"
CONFIG_FILE="${STAGING_DIR}/config.yaml"
SUBSCRIPTION_FILE="${STAGING_DIR}/subscription.yaml"
ENTRYPOINT_SCRIPT="$PACKAGE_DIR/scripts/entrypoint.sh"

DOWNLOAD_INTERVAL=86400  # 1 день

# ------------------------------------------------------------------------------
# Переопределения конфигурации (то, что накладывается поверх подписки)
# ------------------------------------------------------------------------------
CONFIG_OVERRIDES=(
    "dns.listen=0.0.0.0:1053"
    "bind-address=*"
    "iptables.enable=false"
    "routing-mark=255"
    "external-ui=ui"
    "external-controller=0.0.0.0:9900"
    "secret=${MIHOMO_SECRET}"
    "tproxy-port=7893"
    "mixed-port=7890"
    "port=7895"
    "socks-port=7896"
    "allow-lan=true"
)

# ------------------------------------------------------------------------------
# Проверки
# ------------------------------------------------------------------------------
check_kernel() {
    [ -x "$MIHOMO_KERNEL_BIN" ] || { err "Ядро Mihomo не найдено или не исполняемо: $MIHOMO_KERNEL_BIN"; exit 1; }
    "$MIHOMO_KERNEL_BIN" -v >/dev/null 2>&1 || { err "Ядро не запускается: $MIHOMO_KERNEL_BIN"; exit 1; }
    log "Ядро: $("$MIHOMO_KERNEL_BIN" -v | head -1)"
}

check_entrypoint() {
    [ -x "$ENTRYPOINT_SCRIPT" ] || { err "Скрипт точки входа не найден: $ENTRYPOINT_SCRIPT"; exit 1; }
}

check_yq() {
    command -v yq >/dev/null 2>&1 || { err "yq не установлен"; exit 1; }
    yq --version 2>&1 | grep -q mikefarah || { err "Нужен Go-версия yq (mikefarah)"; exit 1; }
}

# ------------------------------------------------------------------------------
# Скачивание списка IP (универсальная функция)
# ------------------------------------------------------------------------------
# $1 — имя (для логов), $2 — URL, $3 — целевой файл, $4 — макс. размер
download_cidr() {
    local name="$1" url="$2" target="$3" max_bytes="${4:-16777216}"
    local tmp="${target}.download"

    log "Загрузка $name..."
    if http_download "$tmp" 90 "$max_bytes" "$url"; then
        mv "$tmp" "$target"
        log "$name загружен: $target ($(wc -l < "$target") строк)"
        return 0
    fi
    rm -f "$tmp"

    if [ -f "$target" ]; then
        log "Загрузка $name не удалась, используется существующий $target"
        return 0
    fi

    err "Загрузка $name не удалась, локальной копии нет: $url"
    return 1
}

# ------------------------------------------------------------------------------
# Нужно ли обновлять CIDR
# ------------------------------------------------------------------------------
cidr_needs_download() {
    [ -f "$CIDR_TS_FILE" ] || return 0
    local last now diff
    last=$(cat "$CIDR_TS_FILE")
    now=$(date +%s)
    diff=$((now - last))
    [ "$diff" -ge "$DOWNLOAD_INTERVAL" ]
}

# ------------------------------------------------------------------------------
# Этап --prepare
# ------------------------------------------------------------------------------
if [ "$MODE_INTERNAL" = "--prepare" ]; then

    # 1. Копируем существующие CIDR-файлы (чтобы не качать, если не нужно)
    for name in cn_cidr.txt ru_cidr.txt .cidr_timestamp; do
        [ ! -f "${SOURCE_DIR}/$name" ] || cp "${SOURCE_DIR}/$name" "${STAGING_DIR}/$name"
    done

    # 2. Проверяем ядро и yq
    check_kernel
    check_entrypoint
    check_yq

    # 3. Скачиваем CIDR-списки (независимо друг от друга)
    download_cidr_flag=false

    if [ "${SKIP_CNIP:-true}" = "true" ] && [ ! -f "$CIDR_FILE_CN" ]; then
        download_cidr_flag=true
    fi
    if [ "${SKIP_RUIP:-false}" = "true" ] && [ ! -f "$CIDR_FILE_RU" ]; then
        download_cidr_flag=true
    fi

    if cidr_needs_download; then
        if [ "${SKIP_CNIP:-true}" = "true" ]; then
            download_cidr "китайские IP (cn_cidr.txt)" "$CN_CIDR_URL" "$CIDR_FILE_CN" 16777216 || \
                log "Продолжаем без китайского списка"
        else
            log "SKIP_CNIP=false — китайский список не нужен"
        fi

        if [ "${SKIP_RUIP:-false}" = "true" ]; then
            download_cidr "российские IP (ru_cidr.txt)" "$RU_CIDR_URL" "$CIDR_FILE_RU" 16777216 || \
                log "Продолжаем без российского списка"
        else
            log "SKIP_RUIP=false — российский список не нужен"
        fi

        date +%s > "$CIDR_TS_FILE"
    else
        log "CIDR обновлялись менее суток назад — используем кэш"
    fi

    # 4. Скачиваем подписку
    log "Загрузка подписки..."
    if ! http_download "$SUBSCRIPTION_FILE" 120 16777216 "$CONFIG_URL"; then
        err "Загрузка подписки не удалась: $CONFIG_URL"
        exit 1
    fi
    cp "$SUBSCRIPTION_FILE" "$CONFIG_FILE"

# ------------------------------------------------------------------------------
# Этап --render (используется при откате)
# ------------------------------------------------------------------------------
else
    cp "$2" "$CONFIG_FILE" || { err "Не удалось подготовить конфиг для рендера"; exit 1; }
fi

# ------------------------------------------------------------------------------
# Переопределения через yq
# ------------------------------------------------------------------------------
log "Переопределение конфигурации..."

for override in "${CONFIG_OVERRIDES[@]}"; do
    path="${override%%=*}"
    value="${override#*=}"

    if [[ "$value" == "true" || "$value" == "false" ]] || [[ "$value" =~ ^[0-9]+$ ]]; then
        yq_cmd=".$path = $value"
    else
        escaped="${value//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        yq_cmd=".$path = \"$escaped\""
    fi

    if yq eval "$yq_cmd" -i "$CONFIG_FILE"; then
        log "  $path = $value"
    else
        err "Переопределение $path не удалось"
        exit 1
    fi
done

log "Конфигурация-кандидат готова: $CONFIG_FILE"