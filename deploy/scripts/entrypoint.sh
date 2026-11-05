#!/usr/bin/env bash
#
# Точка входа Mihomo.
#
# Работает в двух режимах:
#   1) production  — вызывается из systemd, конфиг в каталоге deploy
#   2) local/dev   — запускается вручную из ./.tmp, без sudo, без nftables
#
# Автоопределение: если запущен под systemd (есть $INVOCATION_ID) — production.
# Иначе — local.
#

set -euo pipefail

# ------------------------------------------------------------------------------
# Рабочий каталог
# ------------------------------------------------------------------------------
if [ -n "${INVOCATION_ID:-}" ]; then
    MODE="production"
    WORK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
else
    MODE="local"
    WORK_DIR="${MIHOMO_RUNTIME_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/.tmp}"
fi

cd "$WORK_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf '[%s] ОШИБКА: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# ------------------------------------------------------------------------------
# Окружение
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PACKAGE_ROOT/lib/env.sh"

if ! load_env_file "$WORK_DIR/.env"; then
    err "Файл .env не найден в $WORK_DIR"
    exit 1
fi

# Значения по умолчанию
SKIP_CNIP="${SKIP_CNIP:-true}"
SKIP_RUIP="${SKIP_RUIP:-false}"
QUIC="${QUIC:-true}"
LOCAL_LOOPBACK_PROXY="${LOCAL_LOOPBACK_PROXY:-false}"
MIHOMO_KERNEL_BIN="${MIHOMO_KERNEL:-$WORK_DIR/mihomo}"

# ------------------------------------------------------------------------------
# Валидация флагов
# ------------------------------------------------------------------------------
for flag in SKIP_CNIP SKIP_RUIP QUIC LOCAL_LOOPBACK_PROXY; do
    value="${!flag}"
    if [[ "$value" != "true" && "$value" != "false" ]]; then
        err "$flag должен быть 'true' или 'false', получено: '$value'"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# Ядро Mihomo
# ------------------------------------------------------------------------------
if [ ! -x "$MIHOMO_KERNEL_BIN" ]; then
    err "Ядро Mihomo не найдено: $MIHOMO_KERNEL_BIN"
    err "Скачайте его в $WORK_DIR/mihomo или укажите MIHOMO_KERNEL в .env"
    exit 1
fi

# ------------------------------------------------------------------------------
# Списки IP → в формат nftables
# ------------------------------------------------------------------------------
build_cidr_set() {
    local file="$1"
    [ -f "$file" ] || return 1
    # Формат nft: { ip1, ip2, ... }
    awk '!/^#/ && NF>0 {ip=ip $1 ", "} END {sub(/, $/, "", ip); print ip}' "$file"
}

# ------------------------------------------------------------------------------
# Настройка nftables (только production)
# ------------------------------------------------------------------------------
setup_nftables() {
    if [ "$MODE" != "production" ]; then
        log "local-режим: пропускаем настройку nftables"
        return 0
    fi

    if ! command -v nft >/dev/null 2>&1; then
        err "nft не установлен, прозрачный прокси невозможен"
        exit 1
    fi

    if nft list table clash >/dev/null 2>&1; then
        nft flush table clash
        nft delete table clash
    fi

    nft add table clash
    nft add chain clash PREROUTING '{ type filter hook prerouting priority 0 ; }'

    # Локальные/приватные адреса — напрямую
    nft add rule clash PREROUTING ip daddr \
        '{0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4}' \
        return

    # Китайские IP — напрямую (если включено)
    if [ "$SKIP_CNIP" = "true" ] && [ -f "$WORK_DIR/cn_cidr.txt" ]; then
        local cn_ip
        cn_ip=$(build_cidr_set "$WORK_DIR/cn_cidr.txt")
        if [ -n "$cn_ip" ]; then
            nft add rule clash PREROUTING ip daddr "{ $cn_ip }" return
            log "Добавлен обход китайских IP ($(wc -l < "$WORK_DIR/cn_cidr.txt") подсетей)"
        fi
    fi

    # Российские IP — напрямую (если включено)
    if [ "$SKIP_RUIP" = "true" ] && [ -f "$WORK_DIR/ru_cidr.txt" ]; then
        local ru_ip
        ru_ip=$(build_cidr_set "$WORK_DIR/ru_cidr.txt")
        if [ -n "$ru_ip" ]; then
            nft add rule clash PREROUTING ip daddr "{ $ru_ip }" return
            log "Добавлен обход российских IP ($(wc -l < "$WORK_DIR/ru_cidr.txt") подсетей)"
        fi
    fi

    # Защита от циклов
    nft add rule clash PREROUTING mark 0xff return
    nft add rule clash PREROUTING meta l4proto '{tcp, udp}' mark set 1 tproxy to :7893 accept

    # DNS
    nft add chain clash PREROUTING_DNS '{ type nat hook prerouting priority -100 ; }'
    nft add rule clash PREROUTING_DNS meta mark 0xff return
    nft add rule clash PREROUTING_DNS udp dport 53 redirect to :1053

    # Отключение QUIC
    if [ "$QUIC" = "false" ]; then
        nft add chain clash INPUT '{ type filter hook input priority 0 ; }'
        nft add rule clash INPUT udp dport 443 reject
    fi

    # Локальный трафик
    if [ "$LOCAL_LOOPBACK_PROXY" = "true" ]; then
        nft add chain clash OUTPUT '{ type route hook output priority 0 ; }'
        nft add rule clash OUTPUT ip daddr \
            '{0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4}' \
            return
        nft add rule clash OUTPUT mark 0xff return
        nft add rule clash OUTPUT meta l4proto '{tcp, udp}' mark set 1 accept

        nft add chain clash OUTPUT_DNS '{ type nat hook output priority -100 ; }'
        nft add rule clash OUTPUT_DNS meta mark 0xff return
        nft add rule clash OUTPUT_DNS udp dport 53 redirect to :1053
    fi

    # Ускорение TPROXY для установленных соединений
    nft add chain clash DIVERT '{ type filter hook prerouting priority -150 ; }'
    nft add rule clash DIVERT meta l4proto tcp socket transparent 1 meta mark set 1 accept

    log "nftables настроен"
}

# ------------------------------------------------------------------------------
# Policy routing (только production)
# ------------------------------------------------------------------------------
setup_routing() {
    if [ "$MODE" != "production" ]; then
        return 0
    fi

    if ! ip rule show | grep -Eq 'fwmark 0x0*1 .* lookup 100'; then
        ip rule add fwmark 1 lookup 100
    fi
    if ! ip route show table 100 | grep -Eq '^local 0\.0\.0\.0/0 dev lo'; then
        ip route add local 0.0.0.0/0 dev lo table 100
    fi
}

# ------------------------------------------------------------------------------
# Главная логика
# ------------------------------------------------------------------------------
log "Режим: $MODE"
log "Рабочий каталог: $WORK_DIR"
log "Ядро: $MIHOMO_KERNEL_BIN"

setup_routing
setup_nftables

log "*** Запуск Mihomo ***"

if [ $# -eq 0 ]; then
    exec "$MIHOMO_KERNEL_BIN" -d "$WORK_DIR"
else
    exec "$@"
fi