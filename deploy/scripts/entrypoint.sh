#!/usr/bin/env bash
# Версия 3.3.0   2026.11.07  @smg38
#
# Точка входа Mihomo.
#
# Использование:
#   entrypoint.sh [КОМАНДА] [-- свои аргументы]
#
# Команды:
#   run      (по умолчанию) запустить ядро, дождаться порта, применить сетевые правила,
#            при остановке — убрать их
#   setup    только применить ip rule / ip route / nftables (ядро не запускается)
#   clean    удалить всё, что создал setup (идемпотентно)
#   status   показать текущее состояние
#   check    проверить .env, файлы и конфиг ядра; сеть не трогать
#   noop     ничего не делать, вывести режим и выйти с кодом 0
#   <иное>   выполнить как команду вместо ядра (старое поведение: entrypoint.sh cmd args...)
#
# Режимы окружения (автоопределение, можно задать MIHOMO_MODE=production|local):
#   production — под systemd, конфиг в каталоге deploy
#   local      — вручную из ./.tmp, без root и без nftables
#
# Параметры .env (значения по умолчанию в скобках):
#   SKIP_CNIP (true)  SKIP_RUIP (false)  QUIC (true)  LOCAL_LOOPBACK_PROXY (false)
#   NETWORK_MODE (tproxy)  — tproxy | none (none: ядро запускается, сеть не трогаем)
#   TPROXY_PORT (7893)  DNS_PORT (1053)
#   FWMARK (1)  BYPASS_MARK (0xff)  ROUTE_TABLE (100)  NFT_TABLE (clash)
#   MIHOMO_KERNEL, SKIP_CONFIG_TEST (false), READY_TIMEOUT (30)
#
# Важно: в конфиге Mihomo должно быть routing-mark, равный BYPASS_MARK (по умолчанию 255),
# иначе исходящий трафик самого ядра зациклится.
#
# Рекомендуемый фрагмент unit-файла:
#   ExecStart=/opt/mihomo/bin/entrypoint.sh run
#   ExecStopPost=/opt/mihomo/bin/entrypoint.sh clean
#

set -euo pipefail

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] ВНИМАНИЕ: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
err()  { printf '[%s] ОШИБКА: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------------------
# Команда
# ------------------------------------------------------------------------------
COMMAND="run"
case "${1:-}" in
    run|setup|clean|status|check|noop) COMMAND="$1"; shift ;;
esac
if [ "${1:-}" = "--" ]; then shift; fi

# ------------------------------------------------------------------------------
# Режим и рабочий каталог
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

case "${MIHOMO_MODE:-auto}" in
    production|local) MODE="$MIHOMO_MODE" ;;
    auto)
        if [ -n "${INVOCATION_ID:-}" ]; then MODE="production"; else MODE="local"; fi
        ;;
    *) err "MIHOMO_MODE должен быть production, local или auto"; exit 1 ;;
esac

if [ "$MODE" = "production" ]; then
    WORK_DIR="$PACKAGE_ROOT"
else
    WORK_DIR="${MIHOMO_RUNTIME_DIR:-$(cd "$PACKAGE_ROOT/.." && pwd)/.tmp}"
    mkdir -p "$WORK_DIR"
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
cd "$WORK_DIR"

if [ "$COMMAND" = "noop" ]; then
    log "noop: режим=$MODE, каталог=$WORK_DIR — ничего не делаем"
    exit 0
fi

# ------------------------------------------------------------------------------
# Окружение
# ------------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$PACKAGE_ROOT/lib/env.sh"

if ! load_env_file "$WORK_DIR/.env"; then
    case "$COMMAND" in
        clean|status) warn "Файл .env не найден в $WORK_DIR, используем значения по умолчанию" ;;
        *) err "Файл .env не найден в $WORK_DIR"; exit 1 ;;
    esac
fi

SKIP_CNIP="${SKIP_CNIP:-true}"
SKIP_RUIP="${SKIP_RUIP:-false}"
QUIC="${QUIC:-true}"
LOCAL_LOOPBACK_PROXY="${LOCAL_LOOPBACK_PROXY:-false}"
SKIP_CONFIG_TEST="${SKIP_CONFIG_TEST:-false}"
NETWORK_MODE="${NETWORK_MODE:-tproxy}"
TPROXY_PORT="${TPROXY_PORT:-7893}"
DNS_PORT="${DNS_PORT:-1053}"
FWMARK="${FWMARK:-1}"
BYPASS_MARK="${BYPASS_MARK:-0xff}"
ROUTE_TABLE="${ROUTE_TABLE:-100}"
NFT_TABLE="${NFT_TABLE:-clash}"
READY_TIMEOUT="${READY_TIMEOUT:-30}"
MIHOMO_KERNEL_BIN="${MIHOMO_KERNEL:-$WORK_DIR/mihomo}"

PRIVATE4='0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4'

validate_env() {
    local flag value
    for flag in SKIP_CNIP SKIP_RUIP QUIC LOCAL_LOOPBACK_PROXY SKIP_CONFIG_TEST; do
        value="${!flag}"
        if [[ "$value" != "true" && "$value" != "false" ]]; then
            err "$flag должен быть 'true' или 'false', получено: '$value'"
            exit 1
        fi
    done
    for flag in TPROXY_PORT DNS_PORT FWMARK BYPASS_MARK ROUTE_TABLE READY_TIMEOUT; do
        value="${!flag}"
        if [[ ! "$value" =~ ^([0-9]+|0x[0-9a-fA-F]+)$ ]]; then
            err "$flag должен быть числом, получено: '$value'"
            exit 1
        fi
    done
    if [[ "$NETWORK_MODE" != "tproxy" && "$NETWORK_MODE" != "none" ]]; then
        err "NETWORK_MODE должен быть 'tproxy' или 'none', получено: '$NETWORK_MODE'"
        exit 1
    fi
    if [[ ! "$NFT_TABLE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        err "NFT_TABLE содержит недопустимые символы: '$NFT_TABLE'"
        exit 1
    fi
}
validate_env

# Сетевые правила нужны только в production и только при NETWORK_MODE=tproxy
NET_ACTIVE=false
if [ "$MODE" = "production" ] && [ "$NETWORK_MODE" = "tproxy" ]; then
    NET_ACTIVE=true
fi

# ------------------------------------------------------------------------------
# Проверки
# ------------------------------------------------------------------------------
require_kernel() {
    if [ ! -x "$MIHOMO_KERNEL_BIN" ]; then
        err "Ядро Mihomo не найдено или не исполняемо: $MIHOMO_KERNEL_BIN"
        err "Скачайте его в $WORK_DIR/mihomo или укажите MIHOMO_KERNEL в .env"
        exit 1
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Нужны права root (CAP_NET_ADMIN) для настройки сети"
        exit 1
    fi
}

require_net_tools() {
    local tool
    for tool in ip nft; do
        if ! have "$tool"; then
            err "Не найдена утилита '$tool', прозрачный прокси невозможен"
            exit 1
        fi
    done
}

check_ip_forward() {
    if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 1)" != "1" ]; then
        warn "net.ipv4.ip_forward=0: трафик клиентов за этим хостом проксироваться не будет"
    fi
}

test_config() {
    local out
    log "Проверка конфигурации ядра"
    if ! out="$("$MIHOMO_KERNEL_BIN" -t -d "$WORK_DIR" 2>&1)"; then
        err "Конфигурация Mihomo не прошла проверку:"
        printf '%s\n' "$out" >&2
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Списки IP
# ------------------------------------------------------------------------------
# Выводит валидные CIDR из файла, по одному в строке (CRLF, комментарии и мусор отбрасываются)
cidr_entries() {
    local file="$1"
    [ -f "$file" ] || return 0
    sed -e 's/\r$//' -e 's/#.*//' -e 's/[[:space:]]//g' "$file" \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$' || true
}

count_elems() { awk -F, '{print NF}' <<<"$1"; }

CN_ELEMS=""
RU_ELEMS=""

prepare_lists() {
    CN_ELEMS=""
    RU_ELEMS=""
    if [ "$SKIP_CNIP" = "true" ]; then
        CN_ELEMS="$(cidr_entries "$WORK_DIR/cn_cidr.txt" | paste -sd, -)"
        if [ -n "$CN_ELEMS" ]; then
            log "Обход китайских IP: $(count_elems "$CN_ELEMS") подсетей"
        else
            warn "SKIP_CNIP=true, но $WORK_DIR/cn_cidr.txt отсутствует или пуст"
        fi
    fi
    if [ "$SKIP_RUIP" = "true" ]; then
        RU_ELEMS="$(cidr_entries "$WORK_DIR/ru_cidr.txt" | paste -sd, -)"
        if [ -n "$RU_ELEMS" ]; then
            log "Обход российских IP: $(count_elems "$RU_ELEMS") подсетей"
        else
            warn "SKIP_RUIP=true, но $WORK_DIR/ru_cidr.txt отсутствует или пуст"
        fi
    fi
}

# ------------------------------------------------------------------------------
# nftables
# ------------------------------------------------------------------------------
skip_rules() {
    echo "    ip daddr @private4 return"
    [ -n "$CN_ELEMS" ] && echo "    ip daddr @cn4 return"
    [ -n "$RU_ELEMS" ] && echo "    ip daddr @ru4 return"
    return 0
}

# Собирает весь набор правил в один файл — применяется атомарно через nft -f
build_ruleset() {
    local out="$1"
    {
        echo "table ip $NFT_TABLE"
        echo "delete table ip $NFT_TABLE"
        echo "table ip $NFT_TABLE {"
        echo "  set private4 { type ipv4_addr; flags interval; elements = { $PRIVATE4 } }"
        [ -n "$CN_ELEMS" ] && echo "  set cn4 { type ipv4_addr; flags interval; auto-merge; elements = { $CN_ELEMS } }"
        [ -n "$RU_ELEMS" ] && echo "  set ru4 { type ipv4_addr; flags interval; auto-merge; elements = { $RU_ELEMS } }"

        # Ускорение TPROXY для уже установленных соединений
        cat <<EOF
#  chain DIVERT {
#    type filter hook prerouting priority -150; policy accept;
#    meta l4proto tcp socket transparent 1 meta mark set $FWMARK accept
#  }
  chain PREROUTING_DNS {
    type nat hook prerouting priority -100; policy accept;
    meta mark $BYPASS_MARK return
    udp dport 53 redirect to :$DNS_PORT
  }
  chain PREROUTING {
    type filter hook prerouting priority 0; policy accept;
    meta mark $BYPASS_MARK return
EOF
        skip_rules
        cat <<EOF
    meta l4proto { tcp, udp } meta mark set $FWMARK tproxy to :$TPROXY_PORT accept
  }
EOF

        # Отключение QUIC только для проксируемого трафика (не трогаем свои сервисы на 443/udp)
        if [ "$QUIC" = "false" ]; then
            cat <<EOF
  chain INPUT {
    type filter hook input priority 0; policy accept;
    meta mark $FWMARK udp dport 443 reject
  }
EOF
        fi

        # Локальный трафик самого хоста
        if [ "$LOCAL_LOOPBACK_PROXY" = "true" ]; then
            cat <<EOF
  chain OUTPUT {
    type route hook output priority 0; policy accept;
    meta mark $BYPASS_MARK return
EOF
            skip_rules
            cat <<EOF
    meta l4proto { tcp, udp } meta mark set $FWMARK accept
  }
  chain OUTPUT_DNS {
    type nat hook output priority -100; policy accept;
    meta mark $BYPASS_MARK return
    udp dport 53 redirect to :$DNS_PORT
  }
EOF
        fi

        # Исходящие mihomo (uid root) — НЕ перехватывать TPROXY.
        # routing-mark в config.yaml не гарантирует SO_MARK на всех сокетах,
        # поэтому ставим mark 0xff на уровне nft по skuid.
        cat <<EOF
  chain OUTPUT_BYPASS {
    type route hook output priority -150; policy accept;
    meta skuid 0 meta mark set $BYPASS_MARK accept
  }
EOF
        echo "}"
    } > "$out"
}

setup_nftables() {
    local rules
    prepare_lists
    rules="$(mktemp)"
    build_ruleset "$rules"
    if ! nft -c -f "$rules"; then
        err "Набор правил nftables не прошёл проверку (файл сохранён: $rules)"
        exit 1
    fi
    nft -f "$rules"
    rm -f "$rules"
    log "nftables настроен (таблица ip $NFT_TABLE)"
}

clean_nftables() {
    if have nft; then
        nft delete table ip "$NFT_TABLE" 2>/dev/null || true
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Policy routing
# ------------------------------------------------------------------------------
clean_routing() {
    if have ip; then
        # цикл убирает и накопившиеся дубли от старых версий
        while ip rule del fwmark "$FWMARK" lookup "$ROUTE_TABLE" 2>/dev/null; do :; done
        ip route flush table "$ROUTE_TABLE" 2>/dev/null || true
    fi
    return 0
}

setup_routing() {
    # Числовая таблица работает без записи в /etc/iproute2/rt_tables
    while ip rule del fwmark "$FWMARK" lookup "$ROUTE_TABLE" 2>/dev/null; do :; done
    ip rule add fwmark "$FWMARK" lookup "$ROUTE_TABLE"
    ip route replace local 0.0.0.0/0 dev lo table "$ROUTE_TABLE"
    log "policy routing настроен (fwmark $FWMARK → table $ROUTE_TABLE)"
}

cleanup_network() {
    trap - EXIT
    clean_nftables
    clean_routing
    log "сетевые правила удалены"
}

# ------------------------------------------------------------------------------
# Команды
# ------------------------------------------------------------------------------
CHILD_PID=""

on_signal() {
    if [ -n "$CHILD_PID" ]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
    fi
}

# systemd ExecReload шлёт HUP главному PID (это скрипт) — пробрасываем ядру (перечитать конфиг)
on_reload() {
    if [ -n "$CHILD_PID" ]; then
        kill -HUP "$CHILD_PID" 2>/dev/null || true
    fi
}

wait_for_port() {
    local port="$1" i
    if ! have ss; then
        sleep 2
        return 0
    fi
    for ((i = 0; i < READY_TIMEOUT * 5; i++)); do
        kill -0 "$CHILD_PID" 2>/dev/null || return 1
        if ss -Htln "sport = :$port" 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

cmd_setup() {
    if [ "$NET_ACTIVE" != "true" ]; then
        log "Сетевые правила не применяются (режим=$MODE, NETWORK_MODE=$NETWORK_MODE)"
        return 0
    fi
    require_root
    require_net_tools
    check_ip_forward
    setup_routing
    setup_nftables
}

cmd_clean() {
    if [ "$MODE" != "production" ]; then
        log "local-режим: чистить нечего"
        return 0
    fi
    require_root
    cleanup_network
}

cmd_status() {
    log "Режим: $MODE, NETWORK_MODE=$NETWORK_MODE, каталог: $WORK_DIR"
    if [ "$MODE" != "production" ]; then
        log "local-режим: сетевых правил нет"
        return 0
    fi
    if have nft && nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
        log "nftables: таблица $NFT_TABLE присутствует"
    else
        log "nftables: таблицы $NFT_TABLE нет (или нет прав на чтение)"
    fi
    log "ip rule (fwmark):"
    ip rule show 2>/dev/null | grep fwmark || echo "  нет"
    log "ip route table $ROUTE_TABLE:"
    ip route show table "$ROUTE_TABLE" 2>/dev/null | sed 's/^/  /' || true
}

cmd_check() {
    require_kernel
    test_config
    log "Конфигурация ядра: OK"
    prepare_lists
    if [ "$NET_ACTIVE" = "true" ] && [ "$(id -u)" -eq 0 ] && have nft; then
        local rules
        rules="$(mktemp)"
        build_ruleset "$rules"
        if nft -c -f "$rules"; then
            log "Набор правил nftables: OK"
        else
            err "Набор правил nftables не прошёл проверку"
            rm -f "$rules"
            exit 1
        fi
        rm -f "$rules"
    fi
    log "check: всё в порядке"
}

cmd_run() {
    local -a cmd
    local custom=false rc=0

    if [ $# -eq 0 ]; then
        require_kernel
        cmd=("$MIHOMO_KERNEL_BIN" -d "$WORK_DIR")
        if [ "$SKIP_CONFIG_TEST" != "true" ]; then
            test_config
        fi
    else
        cmd=("$@")
        custom=true
    fi

    log "Режим: $MODE"
    log "Рабочий каталог: $WORK_DIR"
    log "Ядро: $MIHOMO_KERNEL_BIN"

    if [ "$NET_ACTIVE" != "true" ]; then
        log "Сетевые правила не применяются (режим=$MODE, NETWORK_MODE=$NETWORK_MODE)"
        log "*** Запуск Mihomo ***"
        exec "${cmd[@]}"
    fi

    require_root
    require_net_tools
    check_ip_forward

    # Убираем хвосты прошлого запуска, чтобы ядро стартовало с чистой сетью
    clean_nftables
    clean_routing

    log "*** Запуск Mihomo ***"
    "${cmd[@]}" &
    CHILD_PID=$!
    trap on_signal TERM INT
    trap on_reload HUP
    trap cleanup_network EXIT

    if [ "$custom" = "false" ]; then
        if ! wait_for_port "$TPROXY_PORT"; then
            err "Ядро не открыло порт $TPROXY_PORT за ${READY_TIMEOUT}с (проверьте tproxy-port в конфиге)"
            kill -TERM "$CHILD_PID" 2>/dev/null || true
            wait "$CHILD_PID" 2>/dev/null || true
            exit 1
        fi
    fi

    setup_routing
    setup_nftables

    # wait прерывается любым пойманным сигналом (TERM, INT, HUP), поэтому ждём в цикле,
    # пока ядро реально не завершится; rc берём из последнего wait
    while :; do
        wait "$CHILD_PID" && rc=0 || rc=$?
        kill -0 "$CHILD_PID" 2>/dev/null || break
    done
    exit "$rc"
}

case "$COMMAND" in
    run)    cmd_run "$@" ;;
    setup)  cmd_setup ;;
    clean)  cmd_clean ;;
    status) cmd_status ;;
    check)  cmd_check ;;
esac