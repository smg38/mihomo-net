#!/bin/bash
# =============================================================================
# scripts/build-servers.sh — генерация конфигов и учёток для серверов A/B/C/D
# Версия: 3.3.0
# Дата:   2026-11-07
# Автор:  @smg38
#
# Назначение:
#   Сборочный скрипт на машине A. Генерирует:
#     - ключи Reality/UUID для серверов A/B/C/D и пользователей (идемпотентно)
#     - config.yaml для серверов A, B, C, D из шаблонов template/*.j3
#     - systemd unit mihomo.service для B/C/D из template/*.service.j3
#     - nginx-конфиг для C из template/nginx-mihomo.conf.j3
#     - tunnel.service для D из template/tunnel.service.j3
#     - D-config для D из template/D-config.j3
#     - D-install.run — самораспаковывающийся установщик D
#     - ядро mihomo в build/kernel/mihomo-linux-<arch>-<version>
#     - user*.yaml и user*.txt для клиентов
#     - base64 .txt для веб-выдачи на C
#   Опционально:
#     --deploy  — идемпотентная заливка артефактов по SSH (A/B/C/D)
#     --publish — только для D: публикация D-install.run в once/<sha256>.run на C
#
# Использование:
#   scripts/build-servers.sh [all|A|B|C|D] [--instance ID] [--build] [--deploy] [--publish] [--force] [--check] [--help]
#
#   all (по умолчанию)  — все серверы
#   A | B | C | D       — только указанный сервер
#   --instance ID       — экземпляр D из build/instances/ID.env (по умолчанию D)
#   --build, -b         — только генерация артефактов
#   --deploy, -d        — идемпотентная заливка артефактов по SSH
#   --publish           — только для D: публикация D-install.run на C (once/<sha256>.run, TTL 8h)
#   --force, -f         — игнорировать sha256, перезалить всё
#   --check, -c         — проверить params.env и показать план, ничего не делать
#   --help, -h          — справка
#
#   --build --deploy    — сборка + деплой
#   (без ключей)        — эквивалентно --build (совместимость)
#
# Каталоги:
#   build/keys/         — ключи, UUID, params.env (НЕ коммитить)
#   build/kernel/       — кэш ядра mihomo (по ОС, архитектуре и версии)
#   build/A|B|C|D|<ID>/ — сгенерированные конфиги и артефакты экземпляров
#   build/users/        — user*.yaml, user*.txt
#   build/web/          — base64 .txt для веб-выдачи на C
#   .tmp/               — только runtime сервера A (build-local.sh)
#
# Зависимости:
#   bash, openssl, base64, scp, ssh, sha256sum (или shasum), curl, gzip, awk, tar
#   scripts/templater.sh — шаблонизатор
#   deploy/lib/env.sh    — literal env-file validation and parser
# =============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Корень проекта
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# ------------------------------------------------------------------------------
# Цветной вывод
# ------------------------------------------------------------------------------
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'

step() { printf '\n%s%s==>%s %s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$1"; }
info() { printf '%s  ·%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
skip() { printf '%s  =%s %s\n' "$C_DIM" "$C_RESET" "$1"; }
warn() { printf '%s  ⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
fail() { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }
kv()   { printf '%s      %-18s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"; }

trap 'printf "\n%sПрервано пользователем%s\n" "$C_RED" "$C_RESET" >&2; exit 130' INT TERM

# ------------------------------------------------------------------------------
# Константы путей
# ------------------------------------------------------------------------------
BUILD_DIR="$PROJECT_ROOT/build"
KEYS_DIR="$BUILD_DIR/keys"
KERNEL_DIR="$BUILD_DIR/kernel"
PARAMS_ENV="$KEYS_DIR/params.env"
KEYS_ENV="$KEYS_DIR/keys.env"
GLOBAL_KEYS_ENV="$KEYS_ENV"
INSTANCE_DIR="$BUILD_DIR/instances"
TMP_DIR="$PROJECT_ROOT/.tmp"
MIHOMO_BIN="${MIHOMO_BIN:-$TMP_DIR/mihomo}"
TEMPLATER="$PROJECT_ROOT/scripts/templater.sh"
ENV_LIB="$PROJECT_ROOT/deploy/lib/env.sh"

DT="$(date +%Y%m%d-%H%M%S)"
KEYS_ENV_BAK="$KEYS_DIR/back/keys.${DT}.env"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)
REMOTE_USER="${REMOTE_USER:-root}"

# ------------------------------------------------------------------------------
# Разбор аргументов
# ------------------------------------------------------------------------------
TARGET="all"
INSTANCE_ID="D"
DO_BUILD=false
DO_DEPLOY=false
DO_PUBLISH=false
DO_CHECK=false
FORCE=false
EXPLICIT_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            sed -n '2,48p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        --build|-b)   DO_BUILD=true; EXPLICIT_MODE=true; shift ;;
        --deploy|-d)  DO_DEPLOY=true; EXPLICIT_MODE=true; shift ;;
        --publish)    DO_PUBLISH=true; EXPLICIT_MODE=true; shift ;;
        --check|-c)   DO_CHECK=true; EXPLICIT_MODE=true; shift ;;
        --instance)   [[ $# -ge 2 ]] || fail "--instance требует ID"; INSTANCE_ID="$2"; shift 2 ;;
        --force|-f)   FORCE=true; shift ;;
        all|A|B|C|D)  TARGET="$1"; shift ;;
        *) fail "Неизвестный аргумент: $1 (см. --help)" ;;
    esac
done

[[ "$INSTANCE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_]*$ ]] \
    || fail "Недопустимый ID экземпляра D: $INSTANCE_ID"
if [[ "$INSTANCE_ID" != "D" && "$TARGET" != "D" ]]; then
    fail "--instance можно использовать только с TARGET=D"
fi
if [[ "$INSTANCE_ID" != "D" ]]; then
    [[ -f "$INSTANCE_DIR/$INSTANCE_ID.env" ]] \
        || fail "Нет файла экземпляра: $INSTANCE_DIR/$INSTANCE_ID.env"
    KEYS_ENV="$INSTANCE_DIR/$INSTANCE_ID.keys.env"
    KEYS_ENV_BAK="$INSTANCE_DIR/$INSTANCE_ID.keys.${DT}.env.bak"
fi
D_BUILD_DIR="$BUILD_DIR/$INSTANCE_ID"

# По умолчанию — только сборка (совместимость)
if [[ "$EXPLICIT_MODE" == false ]]; then
    DO_BUILD=true
fi

# --publish имеет смысл только для D
if [[ "$DO_PUBLISH" == true && "$TARGET" != "D" ]]; then
    fail "--publish имеет смысл только для TARGET=D"
fi

# ------------------------------------------------------------------------------
# Вспомогательные функции
# ------------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

sha256_local() {
    local f="$1"
    if have sha256sum; then
        sha256sum "$f" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 "$f" | awk '{print $1}'
    else
        fail "Нет sha256sum/shasum"
    fi
}

check_deps() {
    for c in openssl base64 scp ssh curl gzip awk tar; do
        have "$c" || fail "Не найдена команда: $c"
    done
    have sha256sum || have shasum || fail "Нужен sha256sum или shasum"
    [[ -x "$MIHOMO_BIN" ]] || fail "Не найден бинарь Mihomo: $MIHOMO_BIN (соберите через ./build-local.sh build)"
    [[ -x "$TEMPLATER" ]] || fail "Не найден шаблонизатор: $TEMPLATER"
    [[ -f "$ENV_LIB" ]]   || fail "Не найден env-парсер: $ENV_LIB"
}

load_env() {
    # shellcheck disable=SC1090
    source "$ENV_LIB"
    load_env_file "$1"
}

load_params() {
    # shellcheck disable=SC1090
    source "$ENV_LIB"
    load_env_file_literal "$PARAMS_ENV" || return $?
    if [[ ! -v D_TO_B_INSTANCES && ! -v D_TO_C_INSTANCES ]]; then
        D_TO_B_INSTANCES=D
        D_TO_C_INSTANCES=D
    else
        : "${D_TO_B_INSTANCES=}"
        : "${D_TO_C_INSTANCES=}"
    fi
    export D_TO_B_INSTANCES D_TO_C_INSTANCES
}

load_instance_params() {
    load_params || return 1
    if [[ "$INSTANCE_ID" != "D" ]]; then
        validate_d_instance_file "$INSTANCE_DIR/$INSTANCE_ID.env" || return 1
        load_env_file_literal "$INSTANCE_DIR/$INSTANCE_ID.env" || return 1
    fi
    : "${ARCH_D:=amd64}"
    : "${GEO_MODE:=local}"
    : "${DNS_PORT:=1053}"
    : "${TUNNEL_C_HOST:=${IP_C-}}"
    : "${TUNNEL_C_USER:=root}"
    : "${TUNNEL_C_PORT:=22}"
    : "${TUNNEL_REMOTE_PORT:=2222}"
    : "${TUNNEL_KEY:=/root/.ssh/id_ed25519_tunnel}"
    JUMP_D_HOST="$TUNNEL_C_HOST"
    JUMP_D_USER="$TUNNEL_C_USER"
    JUMP_D_SSH_PORT="$TUNNEL_C_PORT"
    REMOTE_PORT_D="$TUNNEL_REMOTE_PORT"
    : "${CN_CIDR_URL:=https://cdn.jsdelivr.net/gh/gaoyifan/china-operator-ip@ip-lists/china.txt}"
    : "${RU_CIDR_URL:=https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru/ipv4-aggregated.txt}"
    : "${GEOSITE_URL:=https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat}"
    : "${GEOIP_METADB_URL:=https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb}"
    D_TO_B_ENABLED=false
    D_TO_C_ENABLED=false
    local -a d_to_b_ids=() d_to_c_ids=()
    local id
    read -r -a d_to_b_ids <<< "$D_TO_B_INSTANCES"
    read -r -a d_to_c_ids <<< "$D_TO_C_INSTANCES"
    for id in "${d_to_b_ids[@]}"; do
        [[ "$id" == "$INSTANCE_ID" ]] && D_TO_B_ENABLED=true
    done
    for id in "${d_to_c_ids[@]}"; do
        [[ "$id" == "$INSTANCE_ID" ]] && D_TO_C_ENABLED=true
    done
    export D_TO_B_ENABLED D_TO_C_ENABLED
    export ARCH_D GEO_MODE DNS_PORT TUNNEL_C_HOST TUNNEL_C_USER TUNNEL_C_PORT TUNNEL_REMOTE_PORT
    export TUNNEL_KEY JUMP_D_HOST JUMP_D_USER JUMP_D_SSH_PORT REMOTE_PORT_D
    export CN_CIDR_URL RU_CIDR_URL GEOSITE_URL GEOIP_METADB_URL
}

ensure_dirs() {
    mkdir -p "$KEYS_DIR"
    mkdir -p "$KERNEL_DIR"
    mkdir -p "$BUILD_DIR"/{A,B,C,D}/back
    mkdir -p "$D_BUILD_DIR/back" "$INSTANCE_DIR"
    mkdir -p "$BUILD_DIR"/users
    mkdir -p "$BUILD_DIR"/web
}

# Утилита: экранировать строку для удалённой POSIX sh (одинарные кавычки)
quote_shell() {
    local escaped="'\\''"
    printf "'%s'" "${1//\'/$escaped}"
}

# Утилита: сформировать user@host
ssh_target() {
    local host="$1"
    if [[ "$host" == *@* ]]; then
        printf '%s' "$host"      # уже с user@
    else
        printf '%s@%s' "$REMOTE_USER" "$host"
    fi
}

# ------------------------------------------------------------------------------
# Валидация params.env (preflight) — оффлайн, без сети
# ------------------------------------------------------------------------------
# Строгая для IP/PORT/DIR/ARCH/юзеров/ключей.
# Мягкая только для пустого USERS_A.
# Не проверяет уникальность DIR и PORT между серверами — это разные машины.
# Проверяет пересечения каталогов на C (безопасность).

_v_errors=0

# --- IPv4 ---
_v_is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do
        (( o >= 0 && o <= 255 )) || return 1
        [[ "$o" == "0" || "$o" != 0* ]] || return 1
    done
    return 0
}

_v_check_ipv4() {
    local name="$1" value="${2-}" placeholder="${3-}"
    if [[ -z "$value" ]]; then
        warn "$name не задана"; _v_errors=$((_v_errors+1)); return
    fi
    if [[ -n "$placeholder" && "$value" == *"$placeholder"* ]]; then
        warn "$name = '$value' — похоже на заглушку"; _v_errors=$((_v_errors+1)); return
    fi
    if ! _v_is_ipv4 "$value"; then
        warn "$name = '$value' — не IPv4 (A.B.C.D, каждый октет 0-255)"; _v_errors=$((_v_errors+1)); return
    fi
    ok "$name = $value"
}

# --- порт ---
_v_check_port() {
    local name="$1" value="${2-}"
    if [[ -z "$value" ]]; then
        warn "$name не задана"; _v_errors=$((_v_errors+1)); return
    fi
    if ! [[ "$value" =~ ^[0-9]+$ ]] || (( 10#$value < 1 || 10#$value > 65535 )); then
        warn "$name = '$value' — не порт (1-65535)"; _v_errors=$((_v_errors+1)); return
    fi
    ok "$name = $value"
}

# --- каталог ---
_v_check_dir() {
    local name="$1" value="${2-}"
    if [[ -z "$value" ]]; then
        warn "$name не задана"; _v_errors=$((_v_errors+1)); return
    fi
    if [[ "$value" != /* ]]; then
        warn "$name = '$value' — должен быть абсолютным путём"; _v_errors=$((_v_errors+1)); return
    fi
    case "$value" in
        /|/usr|/usr/local|/etc|/opt|/var|/var/www|/root|/home|/bin|/sbin|/lib|/lib64|/boot|/sys|/proc|/dev)
            warn "$name = '$value' — слишком общий системный каталог (запрещено)"
            _v_errors=$((_v_errors+1)); return ;;
    esac
    ok "$name = $value"
}

# --- архитектура ---
_v_check_arch() {
    local name="$1" value="${2-}"
    case "$value" in
        amd64|arm64|armv7|armv6|386) ok "$name = $value" ;;
        "") warn "$name не задана"; _v_errors=$((_v_errors+1)) ;;
        *)  warn "$name = '$value' — допустимо: amd64 arm64 armv7 armv6 386"; _v_errors=$((_v_errors+1)) ;;
    esac
}

# --- пользователи ---
_v_is_username() {
    [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,31}$ ]]
}

_v_check_users() {
    local name="$1" list="${2-}" strict="$3"
    if [[ -z "$list" ]]; then
        if [[ "$strict" == true ]]; then
            warn "$name пуста (нужен хотя бы один пользователь)"; _v_errors=$((_v_errors+1))
        else
            warn "$name пуста"
        fi
        return
    fi
    local u seen="" bad=0
    for u in $list; do
        if ! _v_is_username "$u"; then
            warn "$name: невалидное имя '$u' (нужно [a-zA-Z][a-zA-Z0-9_-]{0,31})"
            _v_errors=$((_v_errors+1)); bad=1; continue
        fi
        case " $seen " in
            *" $u "*) warn "$name: дубликат '$u'"; _v_errors=$((_v_errors+1)); bad=1 ;;
            *) seen="$seen $u" ;;
        esac
    done
    (( bad == 0 )) && ok "$name = $list"
}

# --- flow ---
_v_check_flow() {
    local name="$1" value="${2-}"
    case "$value" in
        xtls-rprx-vision|xtls-rprx-vision-udp443|"")
            ok "$name = ${value:-<пусто>}" ;;
        *)  warn "$name = '$value' — ожидается xtls-rprx-vision (или -udp443, или пусто)"
            _v_errors=$((_v_errors+1)) ;;
    esac
}

# --- формат ключей в keys.env ---
_v_check_keys_format() {
    [[ -f "$KEYS_ENV" ]] || { skip "keys.env ещё нет — формат ключей не проверяется"; return; }
    local bad=0 line name value
    while IFS='=' read -r name value; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        case "$name" in
            UUID_*)
                if ! [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
                    warn "keys.env: $name — не UUID ('$value')"; bad=$((bad+1))
                fi ;;
            PRIVATE_KEY_*|PUBLIC_KEY_*)
                if ! [[ "$value" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
                    warn "keys.env: $name — не base64url 43 символа ('${value:0:12}...')"; bad=$((bad+1))
                fi ;;
            SHORT_ID_*)
                if ! [[ "$value" =~ ^[0-9a-fA-F]{1,16}$ ]]; then
                    warn "keys.env: $name — не hex 1-16 ('$value')"; bad=$((bad+1))
                fi ;;
        esac
    done < "$KEYS_ENV"
    if (( bad == 0 )); then
        ok "keys.env: форматы UUID/PRIVATE_KEY/PUBLIC_KEY/SHORT_ID корректны"
    else
        _v_errors=$((_v_errors + bad))
    fi
}

# --- уникальность массива ---
_v_check_unique_array() {
    local label="$1"; shift
    (( $# == 0 )) && return
    local seen="" v bad=0
    for v in "$@"; do
        case " $seen " in
            *" $v "*) warn "$label: дубликат '$v'"; bad=1 ;;
            *) seen="$seen $v" ;;
        esac
    done
    if (( bad == 0 )); then
        ok "$label уникальны: $*"
    else
        _v_errors=$((_v_errors+1))
    fi
}

validate_d_instance_collisions() {
    local setting_vars=(D_TO_B_INSTANCES D_TO_C_INSTANCES D_TO_B_ENABLED D_TO_C_ENABLED
        IP_A IP_B IP_C IP_D PORT_D DNS_PORT DIR_D ARCH_D GEO_MODE SECRET_KEY_D
        TUNNEL_C_HOST TUNNEL_C_USER TUNNEL_C_PORT TUNNEL_REMOTE_PORT TUNNEL_KEY
        JUMP_D_HOST JUMP_D_USER JUMP_D_SSH_PORT REMOTE_PORT_D FWMARK ROUTE_TABLE NFT_TABLE
        CN_CIDR_URL RU_CIDR_URL GEOSITE_URL GEOIP_METADB_URL)
    local -A saved_set=() saved_value=()
    local var
    for var in "${setting_vars[@]}"; do
        if [[ -v "$var" ]]; then
            saved_set["$var"]=1
            saved_value["$var"]="${!var}"
        else
            saved_set["$var"]=0
        fi
    done

    local -a ids=()
    local -A instance_ip=() instance_dir=() instance_port=() tunnel_host=()
    local -A tunnel_port=() tunnel_key=() instance_secret=()
    local errors=0 id file remote_port arch
    while IFS= read -r id; do
        for var in "${setting_vars[@]}"; do unset "$var"; done
        load_params || { errors=$((errors+1)); continue; }
        if [[ "$id" != D ]]; then
            file="$INSTANCE_DIR/$id.env"
            validate_d_instance_file "$file" || { errors=$((errors+1)); continue; }
            load_env_file_literal "$file" || { errors=$((errors+1)); continue; }
        fi

        ids+=("$id")
        instance_ip["$id"]="${IP_D-}"
        instance_dir["$id"]="${DIR_D-}"
        instance_port["$id"]="${PORT_D-}"
        tunnel_host["$id"]="${TUNNEL_C_HOST:-${IP_C-}}"
        tunnel_port["$id"]="${TUNNEL_REMOTE_PORT:-2222}"
        tunnel_key["$id"]="${TUNNEL_KEY:-/root/.ssh/id_ed25519_tunnel}"
        instance_secret["$id"]="${SECRET_KEY_D-}"
        _v_is_ipv4 "${IP_D-}" || { printf '✗ %s: IP_D не задан или не IPv4\n' "$id" >&2; errors=$((errors+1)); }
        _v_is_ipv4 "${TUNNEL_C_HOST:-${IP_C-}}" \
            || { printf '✗ %s: TUNNEL_C_HOST не задан или не IPv4\n' "$id" >&2; errors=$((errors+1)); }
        if ! [[ "${PORT_D-}" =~ ^[0-9]+$ ]] \
            || (( 10#${PORT_D} < 1 || 10#${PORT_D} > 65535 )); then
            printf '✗ %s: PORT_D не является портом 1-65535\n' "$id" >&2
            errors=$((errors+1))
        fi
        if [[ "${DIR_D-}" != /* || "${DIR_D-}" == / || "${DIR_D-}" == /opt || "${DIR_D-}" == /root || "${DIR_D-}" == /etc ]]; then
            printf '✗ %s: DIR_D должен быть абсолютным каталогом приложения\n' "$id" >&2
            errors=$((errors+1))
        fi
        if [[ -z "${SECRET_KEY_D-}" ]]; then
            printf '✗ %s: SECRET_KEY_D не задан\n' "$id" >&2
            errors=$((errors+1))
        fi
        remote_port="${tunnel_port[$id]}"
        if ! [[ "$remote_port" =~ ^[0-9]+$ ]] \
            || (( 10#${remote_port} < 1024 || 10#${remote_port} > 65535 )); then
            printf '✗ %s: TUNNEL_REMOTE_PORT должен быть в диапазоне 1024-65535\n' "$id" >&2
            errors=$((errors+1))
        fi
        arch="${ARCH_D:-amd64}"
        case "$arch" in amd64|arm64|armv7|armv6|386) ;; *)
            printf '✗ %s: недопустимый ARCH_D (%s)\n' "$id" "$arch" >&2
            errors=$((errors+1))
            ;;
        esac
        case "${GEO_MODE:-local}" in local|remote) ;; *)
            printf '✗ %s: GEO_MODE должен быть local или remote\n' "$id" >&2
            errors=$((errors+1))
            ;;
        esac
    done < <(configured_d_instance_ids)

    local i j first second key_file key_name key_value category prior
    local -A seen_key=()
    for ((i=0; i<${#ids[@]}; i++)); do
        first="${ids[i]}"
        for ((j=i+1; j<${#ids[@]}; j++)); do
            second="${ids[j]}"
            if [[ -n "${instance_ip[$first]}" && "${instance_ip[$first]}" == "${instance_ip[$second]}" ]]; then
                printf '✗ %s и %s: совпадает IP_D (%s)\n' "$first" "$second" "${instance_ip[$first]}" >&2
                errors=$((errors+1))
            fi
            if [[ -n "${tunnel_host[$first]}" && "${tunnel_host[$first],,}" == "${tunnel_host[$second],,}" \
                && "${tunnel_port[$first]}" == "${tunnel_port[$second]}" ]]; then
                printf '✗ %s и %s: конфликт reverse-туннеля на %s:%s\n' \
                    "$first" "$second" "${tunnel_host[$first]}" "${tunnel_port[$first]}" >&2
                errors=$((errors+1))
            fi
            if [[ -n "${instance_ip[$first]}" && "${instance_ip[$first]}" == "${instance_ip[$second]}" ]]; then
                if [[ "${instance_dir[$first]}" == "${instance_dir[$second]}" ]]; then
                    printf '✗ %s и %s: совпадает DIR_D на одном сервере (%s)\n' \
                        "$first" "$second" "${instance_dir[$first]}" >&2
                    errors=$((errors+1))
                fi
                if [[ "${instance_port[$first]}" == "${instance_port[$second]}" ]]; then
                    printf '✗ %s и %s: совпадает PORT_D на одном сервере (%s)\n' \
                        "$first" "$second" "${instance_port[$first]}" >&2
                    errors=$((errors+1))
                fi
                if [[ "${tunnel_key[$first]}" == "${tunnel_key[$second]}" ]]; then
                    printf '✗ %s и %s: совпадает путь TUNNEL_KEY на одном сервере (%s)\n' \
                        "$first" "$second" "${tunnel_key[$first]}" >&2
                    errors=$((errors+1))
                fi
            fi
            if [[ -n "${instance_secret[$first]}" && "${instance_secret[$first]}" == "${instance_secret[$second]}" ]]; then
                printf '✗ %s и %s: повторяется SECRET_KEY_D; задайте отдельные секреты\n' "$first" "$second" >&2
                errors=$((errors+1))
            fi
        done

        if [[ "$first" == D ]]; then
            key_file="$GLOBAL_KEYS_ENV"
        else
            key_file="$INSTANCE_DIR/$first.keys.env"
        fi
        if [[ ! -f "$key_file" ]]; then
            info "$first: ключи экземпляра будут созданы при сборке"
            continue
        fi
        while IFS='=' read -r key_name key_value; do
            key_name="${key_name%$'\r'}"
            case "$key_name" in
                UUID_D|UUID_DC|UUID_DB)
                    category=UUID
                    [[ "$key_value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
                        || { printf '✗ %s: неверный формат %s\n' "$first" "$key_name" >&2; errors=$((errors+1)); }
                    ;;
                PRIVATE_KEY_D|PRIVATE_KEY_DC|PRIVATE_KEY_DB)
                    category=PRIVATE_KEY
                    [[ "$key_value" =~ ^[A-Za-z0-9_-]{43}$ ]] \
                        || { printf '✗ %s: неверный формат %s\n' "$first" "$key_name" >&2; errors=$((errors+1)); }
                    ;;
                PUBLIC_KEY_D|PUBLIC_KEY_DC|PUBLIC_KEY_DB)
                    category=PUBLIC_KEY
                    [[ "$key_value" =~ ^[A-Za-z0-9_-]{43}$ ]] \
                        || { printf '✗ %s: неверный формат %s\n' "$first" "$key_name" >&2; errors=$((errors+1)); }
                    ;;
                SHORT_ID_D|SHORT_ID_DC|SHORT_ID_DB)
                    category=SHORT_ID
                    [[ "$key_value" =~ ^[0-9a-fA-F]{1,16}$ ]] \
                        || { printf '✗ %s: неверный формат %s\n' "$first" "$key_name" >&2; errors=$((errors+1)); }
                    ;;
                *) continue ;;
            esac
            [[ -n "$key_value" ]] || continue
            key="$category:$key_value"
            prior="${seen_key[$key]-}"
            if [[ -n "$prior" ]]; then
                printf '✗ повторяется %s между экземплярами %s и %s\n' "$category" "$prior" "$first" >&2
                errors=$((errors+1))
            else
                seen_key["$key"]="$first"
            fi
        done < "$key_file"
    done

    for var in "${setting_vars[@]}"; do
        if [[ "${saved_set[$var]}" == 1 ]]; then
            printf -v "$var" '%s' "${saved_value[$var]}"
            export "$var"
        else
            unset "$var"
        fi
    done

    if (( errors > 0 )); then
        printf '✗ Проверка экземпляров D: %d конфликт(ов)\n' "$errors" >&2
        return 1
    fi
    ok "Экземпляры D: конфигурации, порты и ключи не конфликтуют"
}

# --- главная функция ---
validate_params() {
    local target="$1"
    _v_errors=0

    local need_a=false need_b=false need_c=false need_d=false
    case "$target" in
        all) need_a=true; need_b=true; need_c=true; need_d=true ;;
        A)   need_a=true ;;
        B)   need_b=true ;;
        C)   need_c=true ;;
        D)   need_d=true ;;
    esac

    local ips=()

    # --- A ---
    if [[ "$need_a" == true ]]; then
        printf '\n%s[Сервер A]%s\n' "$C_DIM" "$C_RESET"
        if [[ "${LOCAL_A:-1}" == "0" ]]; then
            _v_check_ipv4 "IP_A"   "${IP_A-}" "x.x.x.x"
            _v_check_port "PORT_A" "${PORT_A-}"
            _v_check_dir  "DIR_A"  "${DIR_A-}"
            [[ -n "${IP_A-}" ]] && ips+=("$IP_A")
        else
            info "LOCAL_A=1 — A работает локально, IP_A/DIR_A не критичны"
        fi
        _v_check_users "USERS_A" "${USERS_A-}" false
    fi

    # --- B ---
    if [[ "$need_b" == true ]]; then
        printf '\n%s[Сервер B]%s\n' "$C_DIM" "$C_RESET"
        _v_check_ipv4 "IP_B"   "${IP_B-}" "x.x.x.x"
        _v_check_port "PORT_B" "${PORT_B-}"
        _v_check_dir  "DIR_B"  "${DIR_B-}"
        _v_check_arch "ARCH_B" "${ARCH_B:-amd64}"
        [[ -n "${IP_B-}" ]] && ips+=("$IP_B")
    fi

    # --- C ---
    if [[ "$need_c" == true ]]; then
        printf '\n%s[Сервер C]%s\n' "$C_DIM" "$C_RESET"
        _v_check_ipv4 "IP_C"   "${IP_C-}" "x.x.x.x"
        _v_check_port "PORT_C" "${PORT_C-}"
        _v_check_dir  "DIR_C"  "${DIR_C-}"
        _v_check_arch "ARCH_C" "${ARCH_C:-amd64}"
        _v_check_users "USERS_C" "${USERS_C-}" true
        _v_check_dir "KEYS_DIR_REMOTE" "${KEYS_DIR_REMOTE:-/opt/mihomo/keys}"
        _v_check_dir "WEB_DIR_REMOTE"  "${WEB_DIR_REMOTE:-/var/www/html/mihomo}"
        [[ -n "${IP_C-}" ]] && ips+=("$IP_C")
    fi

    # --- D ---
    if [[ "$need_d" == true ]]; then
        printf '\n%s[Сервер D]%s\n' "$C_DIM" "$C_RESET"
        _v_check_ipv4 "IP_D"   "${IP_D-}" "x.x.x.x"
        _v_check_port "PORT_D" "${PORT_D-}"
        _v_check_dir  "DIR_D"  "${DIR_D-}"
        _v_check_arch "ARCH_D" "${ARCH_D:-amd64}"
        case "${GEO_MODE:-local}" in
            local|remote) ok "GEO_MODE = $GEO_MODE" ;;
            *) warn "GEO_MODE = '$GEO_MODE' — допустимо: local, remote"; _v_errors=$((_v_errors+1)) ;;
        esac
        _v_check_ipv4 "TUNNEL_C_HOST" "${TUNNEL_C_HOST-${IP_C-}}" "x.x.x.x"
        _v_check_port "TUNNEL_C_PORT" "${TUNNEL_C_PORT:-22}"
        _v_check_port "TUNNEL_REMOTE_PORT" "${TUNNEL_REMOTE_PORT-}"
        if [[ -n "${TUNNEL_REMOTE_PORT-}" ]] && [[ "$TUNNEL_REMOTE_PORT" =~ ^[0-9]+$ ]] && (( TUNNEL_REMOTE_PORT < 1024 )); then
            warn "TUNNEL_REMOTE_PORT < 1024 (на C нужен root для bind; обычно 2222)"
            _v_errors=$((_v_errors+1))
        fi
        [[ -n "${TUNNEL_KEY-}" ]] || { warn "TUNNEL_KEY не задан"; _v_errors=$((_v_errors+1)); }
        [[ -n "${TUNNEL_C_USER-}" ]] || { warn "TUNNEL_C_USER не задан"; _v_errors=$((_v_errors+1)); }
        [[ -n "${IP_D-}" ]] && ips+=("$IP_D")
    fi

    # --- Уникальность IP ---
    printf '\n%s[Уникальность]%s\n' "$C_DIM" "$C_RESET"
    _v_check_unique_array "IP-адреса" "${ips[@]}"
    info "порты и рабочие каталоги могут совпадать между серверами (разные машины)"

    # --- Пересечения каталогов на C (безопасность) ---
    if [[ "$need_c" == true ]]; then
        printf '\n%s[Пересечения каталогов на C]%s\n' "$C_DIM" "$C_RESET"
        local dir_c="${DIR_C:-}"
        local keys_dir="${KEYS_DIR_REMOTE:-/opt/mihomo/keys}"
        local web_dir="${WEB_DIR_REMOTE:-/var/www/html/mihomo}"

        if [[ -n "$dir_c" && ( "$dir_c" == "$web_dir" || "$dir_c" == "$web_dir"/* ) ]]; then
            warn "DIR_C ($dir_c) внутри WEB_DIR_REMOTE ($web_dir) — config.yaml станет доступен по HTTP"
            _v_errors=$((_v_errors+1))
        else
            ok "DIR_C вне WEB_DIR_REMOTE"
        fi

        if [[ "$keys_dir" == "$web_dir" || "$keys_dir" == "$web_dir"/* ]]; then
            warn "KEYS_DIR_REMOTE ($keys_dir) внутри WEB_DIR_REMOTE ($web_dir) — приватные ключи будут доступны по HTTP"
            _v_errors=$((_v_errors+1))
        else
            ok "KEYS_DIR_REMOTE вне WEB_DIR_REMOTE"
        fi

        if [[ "$web_dir" != /var/www/* && "$web_dir" != /srv/www/* && "$web_dir" != /usr/share/nginx/* ]]; then
            warn "WEB_DIR_REMOTE ($web_dir) — не типичный webroot nginx, проверьте root в nginx-конфиге"
        fi
    fi

    # --- Общие flow и ключи ---
    printf '\n%s[Общие]%s\n' "$C_DIM" "$C_RESET"
    _v_check_flow "FLOW_AB"    "${FLOW_AB:-xtls-rprx-vision}"
    _v_check_flow "FLOW_USERS" "${FLOW_USERS:-xtls-rprx-vision}"
    _v_check_keys_format

    if (( _v_errors > 0 )); then
        printf '\n%s  ✗ Найдено %d ошибок в params.env%s\n' "$C_RED" "$_v_errors" "$C_RESET" >&2
        return 1
    fi
    return 0
}

# Проверка доступности URL ядра Mihomo (без скачивания)
validate_kernel_url() {
    local target="$1"
    local need_b=false need_c=false need_d=false
    case "$target" in
        all|B) need_b=true ;;
    esac
    case "$target" in
        all|C) need_c=true ;;
    esac
    case "$target" in
        all|D) need_d=true ;;
    esac
    [[ "$need_b" == false && "$need_c" == false && "$need_d" == false ]] && return 0

    local version="${MIHOMO_VERSION:-v1.19.14}"
    local arch_b="${ARCH_B:-amd64}"
    local arch_c="${ARCH_C:-amd64}"
    local arch_d="${ARCH_D:-amd64}"

    printf '\n%s[URL ядра Mihomo]%s\n' "$C_DIM" "$C_RESET"

    _check_kernel_asset() {
        local arch="$1"
        local asset
        case "$arch" in
            amd64) asset="mihomo-linux-amd64-compatible-${version}.gz" ;;
            arm64) asset="mihomo-linux-arm64-${version}.gz" ;;
            armv7) asset="mihomo-linux-armv7-${version}.gz" ;;
            armv6) asset="mihomo-linux-armv6-${version}.gz" ;;
            386)   asset="mihomo-linux-386-${version}.gz" ;;
            *) warn "неизвестная архитектура: $arch"; _v_errors=$((_v_errors+1)); return ;;
        esac
        local url="https://github.com/MetaCubeX/mihomo/releases/download/${version}/${asset}"
        local http_code
        http_code=$(curl -sIL -o /dev/null -w '%{http_code}' "$url" || echo "000")
        if [[ "$http_code" == "200" ]]; then
            ok "ядро $arch ($version): доступно"
        else
            warn "ядро $arch ($version): HTTP $http_code — $url"
            _v_errors=$((_v_errors+1))
        fi
    }

    [[ "$need_b" == true ]] && _check_kernel_asset "$arch_b"
    [[ "$need_c" == true ]] && _check_kernel_asset "$arch_c"
    [[ "$need_d" == true ]] && _check_kernel_asset "$arch_d"
    if (( _v_errors > 0 )); then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Сетевая проверка (при --check и --deploy)
# ------------------------------------------------------------------------------
validate_connectivity() {
    local target="$1"
    local need_a=false need_b=false need_c=false need_d=false
    case "$target" in
        all) need_a=true; need_b=true; need_c=true; need_d=true ;;
        A)   need_a=true ;;
        B)   need_b=true ;;
        C)   need_c=true ;;
        D)   need_d=true ;;
    esac

    printf '\n%s[Доступность серверов]%s\n' "$C_DIM" "$C_RESET"

    _v_ssh_check() {
        local name="$1" host="$2" need_nginx="${3:-false}"
        if [[ -z "$host" ]]; then
            warn "$name: IP не задан, пропуск"
            return
        fi
        local target
        target=$(ssh_target "$host")

        local ssh_err
        if ! ssh_err=$("${SSH[@]}" "$target" "true" 2>&1); then
            warn "$name ($target): SSH недоступен"
            warn "  причина: ${ssh_err:-нет вывода от ssh}"
            _v_errors=$((_v_errors+1))
            return
        fi
        ok "$name ($target): SSH OK"

        local facts
        facts=$("${SSH[@]}" "$target" '
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            user=$(id -un)
            have() { command -v "$1" >/dev/null 2>&1 && echo yes || echo no; }
            echo "user=$user"
            echo "sudo=$(have sudo)"
            echo "systemctl=$(have systemctl)"
            echo "sha256sum=$(have sha256sum || have shasum)"
            echo "install=$(have install)"
            echo "nginx=$(have nginx)"
        ' 2>/dev/null) || { warn "$name: не удалось получить факты"; _v_errors=$((_v_errors+1)); return; }

        local remote_user=""
        local has_sudo=no has_systemctl=no has_hash=no has_install=no has_nginx=no
        while IFS='=' read -r k v; do
            case "$k" in
                user)      remote_user="$v" ;;
                sudo)      has_sudo="$v" ;;
                systemctl) has_systemctl="$v" ;;
                sha256sum) has_hash="$v" ;;
                install)   has_install="$v" ;;
                nginx)     has_nginx="$v" ;;
            esac
        done <<< "$facts"

        local need_sudo=false
        if [[ "$remote_user" != "root" ]]; then
            need_sudo=true
        fi

        local missing=""
        [[ "$need_sudo" == true && "$has_sudo" != "yes" ]] && missing="$missing sudo"
        [[ "$has_systemctl" != "yes" ]] && missing="$missing systemctl"
        [[ "$has_hash" != "yes" ]]      && missing="$missing sha256sum/shasum"
        [[ "$has_install" != "yes" ]]   && missing="$missing install"

        if [[ -n "$missing" ]]; then
            warn "$name (user=$remote_user): нет команд:$missing"; _v_errors=$((_v_errors+1))
        else
            if [[ "$need_sudo" == true ]]; then
                ok "$name (user=$remote_user): sudo/systemctl/sha256sum/install — есть"
            else
                ok "$name (user=$remote_user, root): systemctl/sha256sum/install — есть, sudo не нужен"
            fi
        fi

        if [[ "$need_nginx" == true ]]; then
            if [[ "$has_nginx" == "yes" ]]; then
                ok "$name: nginx есть"
            else
                warn "$name: nginx не найден (нужен для web-выдачи)"
                _v_errors=$((_v_errors+1))
            fi
        fi
    }

    if [[ "$need_a" == true && "${LOCAL_A:-1}" == "0" ]]; then
        _v_ssh_check "A" "${IP_A-}" false
    elif [[ "$need_a" == true ]]; then
        info "A: LOCAL_A=1 — локально, SSH не проверяется"
    fi
    [[ "$need_b" == true ]] && _v_ssh_check "B" "${REMOTE_USER}@${IP_B-}" false
    [[ "$need_c" == true ]] && _v_ssh_check "C" "${REMOTE_USER}@${IP_C-}" true
    [[ "$need_d" == true ]] && _v_ssh_check "C (для $INSTANCE_ID)" "${REMOTE_USER}@${TUNNEL_C_HOST:-${IP_C-}}" false

    # D за NAT: проверяем, что туннель D->C уже поднят (bootstrap впереди — warn, не fail)
    if [[ "$need_d" == true ]]; then
        local tunnel_port="${TUNNEL_REMOTE_PORT:-2222}"
        local tunnel_user="${TUNNEL_C_USER:-root}"
        local tunnel_host="${TUNNEL_C_HOST:-${IP_C-}}"
        if [[ -n "$tunnel_host" ]] && "${SSH[@]}" "$(ssh_target "$tunnel_host")" \
             "ss -tln 2>/dev/null | grep -q '127.0.0.1:${tunnel_port} '" 2>/dev/null; then
            ok "C: 127.0.0.1:${tunnel_port} слушает (туннель D->C поднят)"
        else
            warn "$tunnel_host: 127.0.0.1:${tunnel_port} НЕ слушает — туннель ещё не поднят (bootstrap впереди)"
        fi
    fi

    if (( _v_errors > 0 )); then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# План действий (для --check)
# ------------------------------------------------------------------------------
show_plan() {
    local target="$1"
    step "План действий"
    if [[ "$DO_BUILD" == true ]]; then
        case "$target" in
            all) info "--build all:  fetch_kernel + render A/B/C/D + units + nginx + D-install.run + build_users" ;;
            A)   info "--build A:    render config_A + build_users (A)" ;;
            B)   info "--build B:    fetch_kernel + render config_B + mihomo.service" ;;
            C)   info "--build C:    fetch_kernel + render config_C + mihomo.service + nginx.conf" ;;
            D)   info "--build $INSTANCE_ID: fetch_kernel + GeoSite/geoip/CIDR + render config_D + units + D-config + installer" ;;
        esac
    else
        info "--build:      пропущен"
    fi
    if [[ "$DO_DEPLOY" == true ]]; then
        case "$target" in
            all) info "--deploy all: A(config) + B(kernel+config+unit) + C(kernel+config+unit+keys+yaml+grant+nginx) + D(через ProxyCommand)" ;;
            A)   info "--deploy A:   config.yaml (LOCAL_A=${LOCAL_A:-1})" ;;
            B)   info "--deploy B:   /usr/local/bin/mihomo + config.yaml + mihomo.service" ;;
            C)   info "--deploy C:   /usr/local/bin/mihomo + config.yaml + mihomo.service + keys/ + users/ + grant.sh + nginx.conf" ;;
            D)   info "--deploy D:   /usr/local/bin/mihomo + config.yaml + .env + GeoSite.dat + mihomo.service + tunnel.service (через ProxyCommand C)" ;;
        esac
    else
        info "--deploy:     пропущен"
    fi
    if [[ "$DO_PUBLISH" == true ]]; then
        info "--publish:    D-install.run -> C:$WEB_DIR_REMOTE/once/<sha256>.run (TTL ${D_INSTALL_TTL:-28800}s)"
    fi
    info "FORCE=$FORCE"
}

# ------------------------------------------------------------------------------
# Идемпотентная генерация ключей
# ------------------------------------------------------------------------------
make_keys() {
    local name="$1"
    local uuid priv pub sid
    keys=$($MIHOMO_BIN generate reality-keypair)
    [[ $keys =~ PrivateKey:[[:space:]]*([^[:space:]]+) ]] && priv="${BASH_REMATCH[1]}"
    [[ $keys =~ PublicKey:[[:space:]]*([^[:space:]]+) ]]  && pub="${BASH_REMATCH[1]}"
    sid=$(openssl rand -hex 8)
    uuid=$("$MIHOMO_BIN" generate uuid)
    printf 'UUID_%s=%s\n'        "$name" "$uuid"
    printf 'PRIVATE_KEY_%s=%s\n' "$name" "$priv"
    printf 'PUBLIC_KEY_%s=%s\n'  "$name" "$pub"
    printf 'SHORT_ID_%s=%s\n'    "$name" "$sid"
}

ensure_key() {
    local name="$1"
    if [[ -f "$KEYS_ENV" ]] && grep -q "^UUID_${name}=" "$KEYS_ENV" 2>/dev/null; then
        return 0
    fi
    local block
    block=$(make_keys "$name")
    printf '%s\n' "$block" >> "$KEYS_ENV"
    chmod 0600 "$KEYS_ENV"
    ok "Сгенерированы ключи для ${name}"
}

configured_d_instance_ids() {
    local file id
    printf '%s\n' D
    for file in "$INSTANCE_DIR"/*.env; do
        [[ -f "$file" ]] || continue
        id="${file##*/}"
        [[ "$id" == *.keys.env ]] && continue
        id="${id%.env}"
        [[ "$id" == D ]] && continue
        printf '%s\n' "$id"
    done
}

validate_d_connection_lists() {
    local id
    local list_name list entry file errors=0
    local -A instance_ids=() connected_ids=()
    local -a list_values=()

    while IFS= read -r id; do
        if ! [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9_]*$ ]]; then
            fail "Недопустимый ID экземпляра D в имени файла: $id"
            errors=$((errors+1))
            continue
        fi
        instance_ids["$id"]=1
    done < <(configured_d_instance_ids)

    for list_name in D_TO_B_INSTANCES D_TO_C_INSTANCES; do
        list="${!list_name-}"
        read -r -a list_values <<< "$list"
        local -A seen=()
        for entry in "${list_values[@]}"; do
            if ! [[ "$entry" =~ ^[A-Za-z0-9][A-Za-z0-9_]*$ ]]; then
                fail "Недопустимый ID '$entry' в $list_name"
                errors=$((errors+1))
            elif [[ ! -v "instance_ids[$entry]" ]]; then
                fail "$list_name содержит $entry, но $INSTANCE_DIR/$entry.env не настроен"
                errors=$((errors+1))
            elif [[ -v "seen[$entry]" ]]; then
                fail "$entry указан в $list_name несколько раз"
                errors=$((errors+1))
            else
                seen["$entry"]=1
                connected_ids["$entry"]=1
            fi
        done
    done
    for id in "${!instance_ids[@]}"; do
        if [[ ! -v "connected_ids[$id]" ]]; then
            fail "$id не включён ни в D_TO_B_INSTANCES, ни в D_TO_C_INSTANCES"
            errors=$((errors+1))
        fi
    done
    (( errors == 0 ))
}

load_d_connection_keys() {
    local target="$1"
    local saved_keys_env="$KEYS_ENV" id key_file key_suffix uuid_name list_name
    case "$target" in
        B) key_suffix=DB; uuid_name=UUID_DB; list_name=D_TO_B_INSTANCES ;;
        C) key_suffix=DC; uuid_name=UUID_DC; list_name=D_TO_C_INSTANCES ;;
        *) fail "Неверная цель для ключей D: $target"; return 1 ;;
    esac

    local -a ids=()
    read -r -a ids <<< "${!list_name}"
    for id in "${ids[@]}"; do
        if [[ "$id" == D ]]; then
            key_file="$GLOBAL_KEYS_ENV"
        else
            key_file="$INSTANCE_DIR/$id.keys.env"
        fi

        KEYS_ENV="$key_file"
        ensure_key "$key_suffix"
        load_env "$key_file"
        printf -v "${uuid_name}_$id" '%s' "${!uuid_name}"
        export "${uuid_name}_$id"
    done

    KEYS_ENV="$saved_keys_env"
    load_env "$GLOBAL_KEYS_ENV"
}

backup_keys_once() {
    if [[ -f "$KEYS_ENV" && ! -f "${KEYS_ENV}.${DT}.bak" ]]; then
        cp "$KEYS_ENV" "$KEYS_ENV_BAK"
        info "Бэкап keys.env: $KEYS_ENV_BAK"
    fi
}

# ------------------------------------------------------------------------------
# Рендеры шаблонов
# ------------------------------------------------------------------------------
render() {
    local tpl="$1" out="$2" envf="$3"
    if [[ ! -f "$tpl" ]]; then
        warn "Шаблон не найден: $tpl"
    fi
    if [[ "$tpl" == *.yaml* || "$tpl" == *.yml* ]]; then
        render_yaml "$tpl" "$out" "$envf"
    else
        render_plain "$tpl" "$out" "$envf"
    fi
}

# Рендер YAML-конфига с валидацией ядром mihomo
render_yaml() {
    local tpl="$1" out="$2" envf="${3:-}"
    if [[ ! -f "$tpl" ]]; then
        fail "Шаблон не найден: $tpl"
    fi
    if [[ -f "$out" ]]; then
        mkdir -p "$(dirname "$out")/back"
        cp "$out" "$(dirname "$out")/back/$(basename "$out").${DT}.bak"
    fi
    if [[ -n "$envf" ]]; then
        echo "DEBUG: $TEMPLATER -c -e $envf -o $out $tpl"
        "$TEMPLATER" -c -e "$envf" -o "$out" "$tpl" >/dev/null
    else
        echo "DEBUG: $TEMPLATER -c -o $out $tpl"
        "$TEMPLATER" -c -o "$out" "$tpl" >/dev/null
    fi
    "$MIHOMO_BIN" -t -f "$out" -d "$TMP_DIR" >/dev/null || fail "Валидация не прошла: $out"
    ok "$out"
}

# Рендер без валидации (для .txt, .service, .conf)
render_plain() {
    local tpl="$1" out="$2" envf="${3:-}"
    if [[ ! -f "$tpl" ]]; then
        fail "Шаблон не найден: $tpl"
    fi
    if [[ -f "$out" ]]; then
        mkdir -p "$(dirname "$out")/back"
        cp "$out" "$(dirname "$out")/back/$(basename "$out").${DT}.bak"
    fi
    if [[ -n "$envf" ]]; then
        "$TEMPLATER" -c -e "$envf" -o "$out" "$tpl" >/dev/null
    else
        "$TEMPLATER" -c -o "$out" "$tpl" >/dev/null
    fi
    ok "$out"
}

# ------------------------------------------------------------------------------
# Ключ кэша учитывает целевую ОС, архитектуру и версию выпуска.
kernel_path() {
    local arch="$1" version="${MIHOMO_VERSION:-v1.19.14}"
    printf '%s/mihomo-linux-%s-%s\n' "$KERNEL_DIR" "$arch" "$version"
}

# ------------------------------------------------------------------------------
# Скачивание ядра mihomo
# ------------------------------------------------------------------------------
fetch_kernel() {
    local arch="$1"
    local dst
    dst=$(kernel_path "$arch")
    if [[ -x "$dst" ]]; then
        skip "ядро уже есть: $dst"
        return 0
    fi

    local version="${MIHOMO_VERSION:-v1.19.14}"

    local asset
    case "$arch" in
        amd64) asset="mihomo-linux-amd64-compatible-${version}.gz" ;;
        arm64) asset="mihomo-linux-arm64-${version}.gz" ;;
        armv7) asset="mihomo-linux-armv7-${version}.gz" ;;
        armv6) asset="mihomo-linux-armv6-${version}.gz" ;;
        386)   asset="mihomo-linux-386-${version}.gz" ;;
        *) fail "Неподдерживаемая архитектура ядра: $arch" ;;
    esac

    local url="https://github.com/MetaCubeX/mihomo/releases/download/${version}/${asset}"

    info "Скачивание ядра ($arch): $asset"
    kv "URL" "$url"

    local http_code
    http_code=$(curl -sIL -o /dev/null -w '%{http_code}' "$url" || echo "000")
    if [[ "$http_code" != "200" ]]; then
        fail "URL недоступен (HTTP $http_code): $url
Проверьте версию Mihomo: https://github.com/MetaCubeX/mihomo/releases"
    fi

    curl -fL --progress-bar -o "$dst.gz" "$url" || fail "Не удалось скачать: $url"
    gunzip -f "$dst.gz" || fail "gunzip не удался"
    chmod +x "$dst"
    ok "ядро готово: $dst"
    kv "Версия" "$("$dst" -v 2>&1 | head -1)"
}

# ------------------------------------------------------------------------------
# Идемпотентный деплой
# ------------------------------------------------------------------------------
CHANGED=false
NGINX_CHANGED=false

sha256_remote() {
    local host="$1" path="$2"
    local target
    target=$(ssh_target "$host")
    "${SSH[@]}" "$target" "if [ -f '$path' ]; then (sha256sum '$path' 2>/dev/null || shasum -a 256 '$path') | awk '{print \$1}'; fi" 2>/dev/null || true
}

# deploy_file <host> <local> <remote> <mode>
deploy_file() {
    local host="$1" local_path="$2" remote_path="$3" mode="${4:-0644}"
    if [[ ! -f "$local_path" ]]; then
        warn "пропуск (нет файла): $local_path"
        return 1
    fi
    local lh rh
    lh=$(sha256_local "$local_path")
    rh=$(sha256_remote "$host" "$remote_path")

    if [[ "$FORCE" != true && -n "$rh" && "$lh" == "$rh" ]]; then
        skip "$remote_path (идентичен)"
        return 0
    fi

    info "upload: $local_path -> $host:$remote_path"
    local remote_dir
    remote_dir=$(dirname "$remote_path")

    local target
    target=$(ssh_target "$host")

    local prefix
    prefix=$(_remote_prefix "$target")

    "${SSH[@]}" "$target" "
        set -e
        ${prefix} mkdir -p '$remote_dir'
        if [ -f '$remote_path' ]; then
            ${prefix} cp -a '$remote_path' '${remote_path}.${DT}.bak'
        fi
    " || { warn "не удалось подготовить $remote_path"; return 1; }

    local staging="${remote_path}.incoming.$$"
    if scp -q -o BatchMode=yes -o ConnectTimeout=10  "$local_path" "$target:$staging" 2>/dev/null; then
        "${SSH[@]}" "$target" "${prefix} install -m $mode '$staging' '$remote_path' && rm -f '$staging'" \
            || { warn "install не удался: $remote_path"; return 1; }
        CHANGED=true
        return 0
    fi

    local tmp_remote="/tmp/mihomo-deploy.$$.$(basename "$remote_path")"
    scp -q -o BatchMode=yes -o ConnectTimeout=10 "$local_path" "$target:$tmp_remote" || { warn "scp не удался: $remote_path"; return 1; }
    "${SSH[@]}" "$target" "${prefix} install -m $mode '$tmp_remote' '$remote_path' && rm -f '$tmp_remote'" \
        || { warn "install не удался: $remote_path"; return 1; }
    CHANGED=true
    return 0
}

declare -A _REMOTE_PREFIX_CACHE
_remote_prefix() {
    local target="$1"
    if [[ -n "${_REMOTE_PREFIX_CACHE[$target]+x}" ]]; then
        printf '%s' "${_REMOTE_PREFIX_CACHE[$target]}"
        return
    fi
    local user
    user=$("${SSH[@]}" "$target" "id -un" 2>/dev/null || echo "")
    if [[ "$user" == "root" ]]; then
        _REMOTE_PREFIX_CACHE[$target]=""
    else
        _REMOTE_PREFIX_CACHE[$target]="sudo"
    fi
    printf '%s' "${_REMOTE_PREFIX_CACHE[$target]}"
}

deploy_tree() {
    local host="$1" local_dir="$2" remote_dir="$3" mode="$4" pattern="$5"
    [[ -d "$local_dir" ]] || { skip "нет каталога: $local_dir"; return 0; }
    local f base
    for f in "$local_dir"/$pattern; do
        [[ -e "$f" ]] || continue
        base=$(basename "$f")
        deploy_file "$host" "$f" "$remote_dir/$base" "$mode" || true
    done
}

restart_service() {
    local host="$1" service="$2"
    local target
    target=$(ssh_target "$host")
    local prefix
    prefix=$(_remote_prefix "$target")
    info "systemctl restart $service на $target"
    "${SSH[@]}" "$target" "${prefix} systemctl daemon-reload && ${prefix} systemctl enable '$service' >/dev/null 2>&1; ${prefix} systemctl restart '$service'" \
        || fail "Не удалось перезапустить $service на $target"
    ok "$service перезапущен"
}

# ------------------------------------------------------------------------------
# Генерация конфига сервера A
# ------------------------------------------------------------------------------
build_A() {
    step "Сервер A — config.yaml"
    ensure_key A
    for u in ${USERS_A:-}; do
        ensure_key "A_${u}"
    done
    load_env "$KEYS_ENV"
    local cfg="$BUILD_DIR/A/config.yaml"
    if [[ -f "$cfg" ]]; then
        mkdir -p "$(dirname "$cfg")/back"
        cp "$cfg" "$(dirname "$cfg")/back/$(basename "$cfg").${DT}.bak"
    fi
    "$TEMPLATER" -c -e "$PARAMS_ENV" -o "$cfg" \
        "$PROJECT_ROOT/template/config_A.yaml.j3" >/dev/null
    "$MIHOMO_BIN" -t -f "$cfg" -d "$TMP_DIR">/dev/null || fail "Валидация не прошла: $cfg"
    ok "$cfg"
}

# ------------------------------------------------------------------------------
# Генерация конфига сервера B
# ------------------------------------------------------------------------------
build_B() {
    step "Сервер B — config.yaml + mihomo.service"
    ensure_key B
    ensure_key BA
    ensure_key BC
    load_env "$KEYS_ENV"
    load_d_connection_keys B

    local arch="${ARCH_B:-amd64}"
    fetch_kernel "$arch"

    local cfg="$BUILD_DIR/B/config.yaml"
    if [[ -f "$cfg" ]]; then
        mkdir -p "$(dirname "$cfg")/back"
        cp "$cfg" "$(dirname "$cfg")/back/$(basename "$cfg").${DT}.bak"
    fi
    "$TEMPLATER" -c -e "$PARAMS_ENV" -o "$cfg" \
        "$PROJECT_ROOT/template/config_B.yaml.j3" >/dev/null
    "$MIHOMO_BIN" -t -f "$cfg" -d "$TMP_DIR">/dev/null || fail "Валидация не прошла: $cfg"
    ok "$cfg"
    export DIR="$DIR_B" USER="root"
    "$TEMPLATER" -e "$PARAMS_ENV" -o "$BUILD_DIR/B/mihomo.service" \
        "$PROJECT_ROOT/template/mihomo-relay.service.j3" >/dev/null
    ok "$BUILD_DIR/B/mihomo.service"
}

# ------------------------------------------------------------------------------
# Генерация конфига сервера C
# ------------------------------------------------------------------------------
build_C() {
    step "Сервер C — config.yaml + mihomo.service + nginx.conf"
    ensure_key C
    ensure_key BC
    for u in ${USERS_C:-}; do
        ensure_key "C_${u}"
    done
    load_env "$KEYS_ENV"
    load_d_connection_keys C

    local arch="${ARCH_C:-amd64}"
    fetch_kernel "$arch"

    local cfg="$BUILD_DIR/C/config.yaml"
    if [[ -f "$cfg" ]]; then
        mkdir -p "$(dirname "$cfg")/back"
        cp "$cfg" "$(dirname "$cfg")/back/$(basename "$cfg").${DT}.bak"
    fi
    "$TEMPLATER" -c -e "$PARAMS_ENV" -o "$cfg" \
        "$PROJECT_ROOT/template/config_C.yaml.j3" >/dev/null
    "$MIHOMO_BIN" -t -f "$cfg" -d "$TMP_DIR">/dev/null || fail "Валидация не прошла: $cfg"
    ok "$cfg"

    export DIR="$DIR_C" USER="root"
    "$TEMPLATER" -c -e "$PARAMS_ENV" -o "$BUILD_DIR/C/mihomo.service" \
        "$PROJECT_ROOT/template/mihomo-relay.service.j3" >/dev/null
    ok "$BUILD_DIR/C/mihomo.service"

    export WEB_DIR_REMOTE="${WEB_DIR_REMOTE:-/var/www/html/mihomo}"
    export IP_C
    "$TEMPLATER" -c -e "$PARAMS_ENV" -o "$BUILD_DIR/C/nginx-mihomo.conf" \
        "$PROJECT_ROOT/template/nginx-mihomo.conf.j3" >/dev/null
    ok "$BUILD_DIR/C/nginx-mihomo.conf"
}

# ------------------------------------------------------------------------------
# Geodata для D (GeoSite.dat обязателен; geoip.metadb и CIDR — по возможности)
# ------------------------------------------------------------------------------
ensure_geodata_d() {
    step "Geodata для D"

    # GeoSite.dat — обязателен, с category-ru (RoscomVPN)
    if [[ -f "$BUILD_DIR/C/GeoSite.dat" ]]; then
        cp "$BUILD_DIR/C/GeoSite.dat" "$D_BUILD_DIR/GeoSite.dat"
        ok "GeoSite.dat <- build/C/GeoSite.dat"
    elif [[ -f "$D_BUILD_DIR/GeoSite.dat" ]]; then
        ok "GeoSite.dat <- $D_BUILD_DIR/GeoSite.dat (кэш)"
    else
        info "Скачивание GeoSite.dat (RoscomVPN)…"
        kv "URL" "${GEOSITE_URL:-https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat}"
        curl -fL --progress-bar -o "$D_BUILD_DIR/GeoSite.dat" \
            "${GEOSITE_URL:-https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat}" \
            || fail "Не удалось скачать GeoSite.dat (обязателен, category-ru)"
        ok "GeoSite.dat скачан"
    fi

    # geoip.metadb — опционально
    if [[ -f "$BUILD_DIR/C/geoip.metadb" ]]; then
        cp "$BUILD_DIR/C/geoip.metadb" "$D_BUILD_DIR/geoip.metadb"
        ok "geoip.metadb <- build/C/geoip.metadb"
    elif [[ -f "$D_BUILD_DIR/geoip.metadb" ]]; then
        ok "geoip.metadb <- $D_BUILD_DIR/geoip.metadb (кэш)"
    else
        info "Скачивание geoip.metadb…"
        curl -fL --progress-bar -o "$D_BUILD_DIR/geoip.metadb" \
            "${GEOIP_METADB_URL:-https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb}" \
            || warn "Не удалось скачать geoip.metadb (GEOIP,RU использует mmdb по умолчанию)"
    fi

    # cn/ru CIDR — по возможности, иначе D скачает сам
    for f in cn_cidr.txt ru_cidr.txt; do
        if [[ -f "$BUILD_DIR/C/$f" ]]; then
            cp "$BUILD_DIR/C/$f" "$D_BUILD_DIR/$f"
            ok "$f <- build/C/$f"
        elif [[ -f "$D_BUILD_DIR/$f" ]]; then
            ok "$f <- $D_BUILD_DIR/$f (кэш)"
        else
            warn "Нет build/C/$f и $D_BUILD_DIR/$f — D скачает сам при install"
        fi
    done
}

# ------------------------------------------------------------------------------
# Генерация D-config (плоский dotenv, без шаблона)
# ------------------------------------------------------------------------------
write_D_config() {
    local out="$D_BUILD_DIR/D-config"
    render_plain "$PROJECT_ROOT/template/D-config.j3" "$out" "$PARAMS_ENV"
    chmod 0600 "$out"
    ok "$out"
}

# ------------------------------------------------------------------------------
# Генерация установщика D-install.run (shar)
# ------------------------------------------------------------------------------
make_D_installer() (
    set -euo pipefail
    step "Сборка D-install.run"
    local arch="${ARCH_D:-amd64}"
    local stage
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT

    mkdir -p "$stage/D-install/lib"
    cp "$D_BUILD_DIR/config.yaml"             "$stage/D-install/"
    cp "$D_BUILD_DIR/mihomo.service"          "$stage/D-install/"
    cp "$D_BUILD_DIR/tunnel.service"          "$stage/D-install/"
    cp "$D_BUILD_DIR/D-config"                "$stage/D-install/"
    cp "$D_BUILD_DIR/.env"                    "$stage/D-install/env.sh"
    cp "$(kernel_path "$arch")"               "$stage/D-install/mihomo"
    cp "$PROJECT_ROOT/deploy/scripts/entrypoint.sh" "$stage/D-install/entrypoint.sh"
    cp "$PROJECT_ROOT/deploy/lib/env.sh"      "$stage/D-install/lib/env.sh"
    cp "$PROJECT_ROOT/deploy/lib/http.sh"     "$stage/D-install/lib/http.sh"
    cp "$PROJECT_ROOT/scripts/D-install-inner.sh" "$stage/D-install/install.sh"
    cp "$PROJECT_ROOT/scripts/D-test.sh"          "$stage/D-install/D-test.sh"
    cp "$D_BUILD_DIR/GeoSite.dat"             "$stage/D-install/geosite.dat"
    [[ -f "$D_BUILD_DIR/geoip.metadb" ]]   && cp "$D_BUILD_DIR/geoip.metadb"  "$stage/D-install/"
    [[ -f "$D_BUILD_DIR/cn_cidr.txt" ]]    && cp "$D_BUILD_DIR/cn_cidr.txt"   "$stage/D-install/"
    [[ -f "$D_BUILD_DIR/ru_cidr.txt" ]]    && cp "$D_BUILD_DIR/ru_cidr.txt"   "$stage/D-install/"

    [[ -f "${TUNNEL_KEY_LOCAL}" && -f "${TUNNEL_KEY_LOCAL}.pub" ]] \
        || fail "Нет ключа D->C: ${TUNNEL_KEY_LOCAL}"
    mkdir -p "$stage/D-install/ssh"
    cp "${TUNNEL_KEY_LOCAL}"     "$stage/D-install/ssh/id_ed25519_tunnel"
    cp "${TUNNEL_KEY_LOCAL}.pub" "$stage/D-install/ssh/id_ed25519_tunnel.pub"
    chmod 600 "$stage/D-install/ssh/id_ed25519_tunnel"
    chmod 644 "$stage/D-install/ssh/id_ed25519_tunnel.pub"
    ok "ключ D->C упакован в архив"
    # --- Публичный ключ A для авторизации A→D (для diagnose.sh и deploy_D) ---
    local a_pub=""
    for cand in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
        [[ -f "$cand" ]] && { a_pub="$cand"; break; }
    done
    [[ -n "$a_pub" ]] || fail "Не найден публичный ключ A (~/.ssh/id_ed25519.pub / id_rsa.pub) — нужен для A→D"
    cp "$a_pub" "$stage/D-install/A_authorized_key.pub"
    ok "публичный ключ A упакован: $a_pub"
    
    chmod +x "$stage/D-install/install.sh" "$stage/D-install/entrypoint.sh" "$stage/D-install/mihomo"

    local installer_name="D-install.run"
    [[ "$INSTANCE_ID" != "D" ]] && installer_name="${INSTANCE_ID}-install.run"
    local out="$D_BUILD_DIR/$installer_name"
    local new_payload
    new_payload=$(mktemp)
    cat > "$new_payload" <<'HEADER'
#!/bin/bash
# D-install.run — самораспаковывающийся установщик сервера D.
# Собран scripts/build-servers.sh D --build.
set -euo pipefail
SELF="$0"
PAYLOAD_LINE=$(awk '/^__PAYLOAD_BELOW__$/{print NR+1; exit}' "$SELF")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
tail -n +"$PAYLOAD_LINE" "$SELF" | tar -xz -C "$TMP"
exec bash "$TMP/D-install/install.sh" "$@"
__PAYLOAD_BELOW__
HEADER
    tar -czf - -C "$stage" D-install >> "$new_payload"
    mv -f "$new_payload" "$out"

    chmod 0755 "$out"
    sha256_local "$out" > "$out.sha256"
    chmod 0644 "$out.sha256"
    ok "$out ($(du -h "$out" | cut -f1))"
    ok "$out.sha256"
)

# ------------------------------------------------------------------------------
# Ключ D->C: генерируется на A, идемпотентно
# ------------------------------------------------------------------------------
ensure_tunnel_key_d() {
    step "Ключ D->C (tunnel)"
    local key="$KEYS_DIR/id_ed25519_tunnel"
    [[ "$INSTANCE_ID" == "D" ]] || key="$INSTANCE_DIR/$INSTANCE_ID.tunnel.key"
    mkdir -p "$KEYS_DIR"
    chmod 700 "$KEYS_DIR"

    if [[ -f "$key" ]]; then
        skip "ключ уже есть: $key"
    else
        ssh-keygen -t ed25519 -f "$key" -N "" -C "tunnel-D-to-C@$(hostname)" >/dev/null
        ok "ключ создан: $key"
    fi
    chmod 600 "$key"
    chmod 644 "${key}.pub"
    export TUNNEL_KEY_LOCAL="$key"
    kv "PUB" "$(cut -c1-40 "${key}.pub")..."

    # Публичная часть встраивается в архив как отдельный файл (для справки), приватная остаётся здесь.
    cp "$key"     "$D_BUILD_DIR/D-tunnel.key"
    cp "${key}.pub" "$D_BUILD_DIR/D-tunnel.key.pub"
    chmod 600 "$D_BUILD_DIR/D-tunnel.key"
    chmod 644 "$D_BUILD_DIR/D-tunnel.key.pub"
}

# ------------------------------------------------------------------------------
# Авторизация публичной части ключа D->C на C (идемпотентно)
# ------------------------------------------------------------------------------
authorize_tunnel_key_on_c() {
    step "Авторизация ключа D->C на C"
    local pub
    pub=$(cat "${TUNNEL_KEY_LOCAL}.pub")
    local remote_port="${TUNNEL_REMOTE_PORT:-2222}"
    local restricted
    restricted="restrict,port-forwarding,permitlisten=\"127.0.0.1:${remote_port}\" ${pub}"

    local target
    target=$(ssh_target "${TUNNEL_C_USER:-root}@${TUNNEL_C_HOST:-$IP_C}")
    local prefix
    prefix=$(_remote_prefix "$target")

    if "${SSH[@]}" "$target" "grep -qxF $(quote_shell "$restricted") \"\$HOME/.ssh/authorized_keys\" 2>/dev/null"; then
        skip "ключ уже авторизован на C"
        return 0
    fi

    info "добавляю публичную часть ключа на C ($target)"
    "${SSH[@]}" "$target" "
        set -e
        umask 077
        mkdir -p \"\$HOME/.ssh\"
        chmod 700 \"\$HOME/.ssh\"
        touch \"\$HOME/.ssh/authorized_keys\"
        chmod 600 \"\$HOME/.ssh/authorized_keys\"
        grep -qxF $(quote_shell "$restricted") \"\$HOME/.ssh/authorized_keys\" \
            || ${prefix} tee -a \"\$HOME/.ssh/authorized_keys\" <<'__KEY_EOF__'
$(printf '%s\n' "$restricted")
__KEY_EOF__
    " || fail "Не удалось авторизовать ключ на C"
    ok "ключ авторизован на C"
}

# ------------------------------------------------------------------------------
# Генерация сервера D
# ------------------------------------------------------------------------------
build_D() {
    step "Экземпляр $INSTANCE_ID типа D — config + units + .env + D-config + installer"
    ensure_key D
    [[ "$D_TO_C_ENABLED" == true ]] && ensure_key DC
    [[ "$D_TO_B_ENABLED" == true ]] && ensure_key DB
    load_env "$KEYS_ENV"
    load_instance_params || fail "Не удалось загрузить параметры экземпляра $INSTANCE_ID"

    local arch="${ARCH_D:-amd64}"
    fetch_kernel "$arch"
    ensure_geodata_d

    export GEO_MODE="${GEO_MODE:-local}"
    render_yaml  "$PROJECT_ROOT/template/config_D.yaml.j3"          "$D_BUILD_DIR/config.yaml"     "$PARAMS_ENV"

    export DIR="$DIR_D" USER="root"
    render_plain "$PROJECT_ROOT/template/mihomo-tproxy.service.j3" "$D_BUILD_DIR/mihomo.service"  "$PARAMS_ENV"

    export TUNNEL_KEY="${TUNNEL_KEY:-/root/.ssh/id_ed25519_tunnel}"
    export TUNNEL_C_USER="${TUNNEL_C_USER:-root}"
    export TUNNEL_C_PORT="${TUNNEL_C_PORT:-22}"
    export TUNNEL_REMOTE_PORT="${TUNNEL_REMOTE_PORT:-2222}"
    export TUNNEL_C_HOST="${TUNNEL_C_HOST:-$IP_C}"
    render_plain "$PROJECT_ROOT/template/tunnel.service.j3"         "$D_BUILD_DIR/tunnel.service"  "$PARAMS_ENV"
    render_plain "$PROJECT_ROOT/template/D-env.j3"                  "$D_BUILD_DIR/.env"            "$PARAMS_ENV"

    write_D_config

    "$MIHOMO_BIN" -t -f "$D_BUILD_DIR/config.yaml" -d "$TMP_DIR" >/dev/null \
        || fail "Валидация не прошла: $D_BUILD_DIR/config.yaml"
    ok "$D_BUILD_DIR/config.yaml валиден"

    ensure_tunnel_key_d
    make_D_installer
}

# ------------------------------------------------------------------------------
# Публикация D-install.run на C (once/<sha256>.run, TTL 8h)
# ------------------------------------------------------------------------------
publish_D() {
    step "Публикация $INSTANCE_ID installer на C (once/<sha256>.run)"
    load_instance_params || fail "Не удалось загрузить параметры экземпляра $INSTANCE_ID"

    ensure_tunnel_key_d
    authorize_tunnel_key_on_c
    make_D_installer

    local installer_name="D-install.run"
    [[ "$INSTANCE_ID" != "D" ]] && installer_name="${INSTANCE_ID}-install.run"
    local installer="$D_BUILD_DIR/$installer_name"
    [[ -f "$installer" ]] || fail "Нет $installer"

    local hash
    local hash256
    hash256=$(sha256_local "$installer")
    hash=${hash256: -8}
    local ttl="${D_INSTALL_TTL:-28800}"
    local web_dir="${WEB_DIR_REMOTE:-/var/www/html/mihomo}"
    local once_dir="$web_dir/once"
    local target; target=$(ssh_target "$IP_C")
    local prefix; prefix=$(_remote_prefix "$target")

    "${SSH[@]}" "$target" "set -e; ${prefix} mkdir -p '$once_dir'; ${prefix} chmod 755 '$once_dir'" \
        || fail "Не удалось создать $once_dir на C"

    deploy_file "$IP_C" "$installer" "$once_dir/${hash}.run" 0644
    deploy_file "$IP_C" "$installer.sha256" "$once_dir/${hash}.run.sha256" 0644

    "${SSH[@]}" "$target" "nohup bash -c 'sleep $ttl; rm -f \"$once_dir/${hash}.run\" \"$once_dir/${hash}.run.sha256\"' >/dev/null 2>&1 & disown" \
        || warn "Не удалось запустить автоудаление через $ttl сек"

    local web_ip="${WEB_IP:-$IP_C}"
    cat <<EOF

Публикация D-install.run на C:
  URL:    http://${web_ip}/mihomo/once/${hash}.run
  SHA256: ${hash256}
  TTL:    ${ttl} сек ($(( ttl / 3600 )) ч)

Ключ D->C уже авторизован на C заранее. На D — одна команда:
  curl -fsSL http://${web_ip}/mihomo/once/${hash}.run -o /tmp/${installer_name} && sh /tmp/${installer_name}
EOF
}

# ------------------------------------------------------------------------------
# Генерация учёток пользователей
# ------------------------------------------------------------------------------
build_users() {
    local target="${1:-all}" servers=()
    case "$target" in all) servers=(A C) ;; A) servers=(A) ;; C) servers=(C) ;; *) return 0 ;; esac
    step "Учётные записи пользователей"
    load_env "$KEYS_ENV"
    local server ip port pubkey sid users_var
    for server in "${servers[@]}"; do
        case "$server" in
            A) ip="${IP_A:?}"; port="${PORT_A:?}"; pubkey="${PUBLIC_KEY_A:?}"; sid="${SHORT_ID_A:?}"; users_var=USERS_A ;;
            C) ip="${IP_C:?}"; port="${PORT_C:?}"; pubkey="${PUBLIC_KEY_C:?}"; sid="${SHORT_ID_C:?}"; users_var=USERS_C ;;
        esac

        local users="${!users_var:-}"
        [[ -n "$users" ]] || { info "${server}: список пользователей пуст"; continue; }

        for u in $users; do
            local uuid
            uuid=$(grep -E "^UUID_${server}_${u}=" "$KEYS_ENV" | head -1 | cut -d= -f2)
            if [[ -z "$uuid" ]]; then
                uuid=$(grep -E "^UUID_${u}=" "$KEYS_ENV" | head -1 | cut -d= -f2)
            fi
            [[ -n "$uuid" ]] || { warn "${server}/${u}: UUID не найден, пропуск"; continue; }

            export NAME="${server}"
            export IP="$ip"
            export PORT="$port"
            export PUBLIC_KEY="$pubkey"
            export SHORT_ID="$sid"
            export UUID_USER="$uuid"
            export FLOW_USERS="${FLOW_USERS:-xtls-rprx-vision}"

            render "$PROJECT_ROOT/template/user.yaml.j3" "$BUILD_DIR/users/${server}_${u}.yaml" "$PARAMS_ENV"
            render "$PROJECT_ROOT/template/user.txt.j3"  "$BUILD_DIR/users/${server}_${u}.txt"  "$PARAMS_ENV"

            base64 -w0 "$BUILD_DIR/users/${server}_${u}.txt" > "$BUILD_DIR/web/${server}_${u}.txt"
            ok "web/${server}_${u}.txt"
        done
    done
}

# ------------------------------------------------------------------------------
# Деплой A (только если LOCAL_A=0)
# ------------------------------------------------------------------------------
deploy_A() {
    step "Деплой A"
    load_env "$PARAMS_ENV"
    if [[ "${LOCAL_A:-1}" == "1" ]]; then
        info "LOCAL_A=1 — A работает локально через build-local.sh, деплой пропущен"
        return 0
    fi
    local host="${IP_A}"
    CHANGED=false
    deploy_file "$host" "$BUILD_DIR/A/config.yaml" "$DIR_A/config.yaml" 0644
    if [[ "$CHANGED" == true ]]; then
        restart_service "$host" "mihomo"
    else
        skip "A: изменений нет"
    fi
}

# ------------------------------------------------------------------------------
# Деплой B
# ------------------------------------------------------------------------------
deploy_B() {
    step "Деплой B"
    load_env "$PARAMS_ENV"
    local host="$IP_B"
    local arch="${ARCH_B:-amd64}"
    CHANGED=false

    deploy_file "$host" "$(kernel_path "$arch")"      "/usr/local/bin/mihomo"              0755
    deploy_file "$host" "$BUILD_DIR/B/config.yaml"    "$DIR_B/config.yaml"                 0644
    deploy_file "$host" "$BUILD_DIR/B/mihomo.service" "/etc/systemd/system/mihomo.service" 0644

    if [[ "$CHANGED" == true ]]; then
        restart_service "$host" "mihomo"
    else
        skip "B: изменений нет"
    fi
}

# ------------------------------------------------------------------------------
# Деплой C
# ------------------------------------------------------------------------------
deploy_C() {
    step "Деплой C"
    load_env "$PARAMS_ENV"
    local host="$IP_C"
    local arch="${ARCH_C:-amd64}"
    local keys_dir="${KEYS_DIR_REMOTE:-/opt/mihomo/keys}"
    local web_dir="${WEB_DIR_REMOTE:-/var/www/html/mihomo}"
    local target
    target=$(ssh_target "$host")
    CHANGED=false
    NGINX_CHANGED=false

    deploy_file "$host" "$(kernel_path "$arch")" "/usr/local/bin/mihomo" 0755
    deploy_file "$host" "$BUILD_DIR/C/config.yaml" "$DIR_C/config.yaml" 0644
    deploy_file "$host" "$BUILD_DIR/C/mihomo.service" "/etc/systemd/system/mihomo.service" 0644

    local prefix
    prefix=$(_remote_prefix "$target")
    "${SSH[@]}" "$target" "${prefix} mkdir -p '$keys_dir' && ${prefix} chmod 700 '$keys_dir'" || true
    deploy_tree "$host" "$BUILD_DIR/web"   "$keys_dir" 0600 "C_*.txt"
    deploy_tree "$host" "$BUILD_DIR/users" "$keys_dir" 0600 "C_*.yaml"

    deploy_file "$host" "$PROJECT_ROOT/scripts/grant.sh" "/opt/mihomo/grant.sh" 0700

    "${SSH[@]}" "$target" "
        set -e
        ${prefix} mkdir -p '$web_dir/sub' '$web_dir/once' '$web_dir/users'
        ${prefix} chmod 755 '$web_dir' '$web_dir/sub' '$web_dir/once' '$web_dir/users'
    " || true

    local nginx_local="$BUILD_DIR/C/nginx-mihomo.conf"
    if [[ -f "$nginx_local" ]]; then
        local lh rh
        lh=$(sha256_local "$nginx_local")
        rh=$(sha256_remote "$host" "/etc/nginx/sites-available/mihomo.conf")
        if [[ "$FORCE" == true || -z "$rh" || "$lh" != "$rh" ]]; then
            info "upload: $nginx_local -> $host:/etc/nginx/sites-available/mihomo.conf"
            local staging="/tmp/nginx-mihomo.$$.conf"
            scp -q -o BatchMode=yes -o ConnectTimeout=10  "$nginx_local" "$target:$staging" || warn "scp nginx.conf не удался"
            if "${SSH[@]}" "$target" "
                set -e
                ${prefix}  install -m 0644 '$staging' /etc/nginx/sites-available/mihomo.conf
                ${prefix} ln -sfn /etc/nginx/sites-available/mihomo.conf /etc/nginx/sites-enabled/mihomo.conf
                rm -f '$staging'
                ${prefix} nginx -t
            "; then
                NGINX_CHANGED=true
                ok "nginx-конфиг обновлён"
            else
                warn "nginx -t не прошёл, конфиг не активирован"
            fi
        else
            skip "nginx.conf (идентичен)"
        fi
    fi

    if [[ "$CHANGED" == true ]]; then
        restart_service "$host" "mihomo"
    else
        skip "C: бинарь/конфиг/юниты без изменений"
    fi

    if [[ "$NGINX_CHANGED" == true ]]; then
        info "systemctl reload nginx на $host"
        "${SSH[@]}" "$target" "${prefix} systemctl reload nginx" || warn "reload nginx не удался"
        ok "nginx перезагружен"
    fi
}

# ------------------------------------------------------------------------------
# Деплой D (через ProxyCommand C: localhost:REMOTE_PORT_D)
# ------------------------------------------------------------------------------
deploy_D() {
    step "Деплой экземпляра $INSTANCE_ID типа D (через ProxyCommand C)"
    load_instance_params || fail "Не удалось загрузить параметры экземпляра $INSTANCE_ID"

    : "${IP_C:?IP_C не задан}"
    if [[ "$INSTANCE_ID" == "D" ]]; then
        TUNNEL_KEY_LOCAL="$KEYS_DIR/id_ed25519_tunnel"
    else
        TUNNEL_KEY_LOCAL="$INSTANCE_DIR/$INSTANCE_ID.tunnel.key"
    fi
    [[ -f "$TUNNEL_KEY_LOCAL" ]] || fail "Нет ключа D->C: $TUNNEL_KEY_LOCAL (сначала: build-servers.sh D --build)"

    authorize_tunnel_key_on_c

    local tunnel_host="${TUNNEL_C_HOST:-$IP_C}"
    local tunnel_user="${TUNNEL_C_USER:-root}"
    local tunnel_port="${TUNNEL_C_PORT:-22}"
    local remote_port="${TUNNEL_REMOTE_PORT:-2222}"
    local jump_user="${JUMP_D_USER:-root}"

    local proxy="ssh -p $tunnel_port -o BatchMode=yes -o StrictHostKeyChecking=accept-new $tunnel_user@$tunnel_host -W %h:%p"
    local SSH_D=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o "ProxyCommand=$proxy" -p "$remote_port")
    local SCP_D=(scp -q -o BatchMode=yes -o ConnectTimeout=10 -o "ProxyCommand=$proxy" -P "$remote_port")
    local target_D="${jump_user}@localhost"

    if ! "${SSH_D[@]}" "$target_D" true 2>/dev/null; then
        fail "SSH D через ProxyCommand C не работает. Сначала bootstrap: на D выполнить 'curl -fsSL <URL>.run | sh' (URL из --publish)"
    fi
    ok "A -> C -> D OK"

    CHANGED=false
    local arch="${ARCH_D:-amd64}"

    deploy_file_d() {
        local local_path="$1" remote_path="$2" mode="${3:-0644}"
        [[ -f "$local_path" ]] || { warn "пропуск (нет файла): $local_path"; return 1; }
        local lh rh
        lh=$(sha256_local "$local_path")
        rh=$("${SSH_D[@]}" "$target_D" "if [ -f '$remote_path' ]; then sha256sum '$remote_path' | awk '{print \$1}'; fi" 2>/dev/null || true)
        if [[ "$FORCE" != true && -n "$rh" && "$lh" == "$rh" ]]; then
            skip "$remote_path (идентичен)"
            return 0
        fi
        info "upload: $local_path -> D:$remote_path"
        "${SSH_D[@]}" "$target_D" "mkdir -p '$(dirname "$remote_path")'" || { warn "mkdir D:$remote_path"; return 1; }
        local staging="${remote_path}.incoming.$$"
        "${SCP_D[@]}" "$local_path" "$target_D:$staging" || { warn "scp D:$remote_path"; return 1; }
        "${SSH_D[@]}" "$target_D" "install -m $mode '$staging' '$remote_path' && rm -f '$staging'" \
            || { warn "install D:$remote_path"; return 1; }
        CHANGED=true
        return 0
    }

    deploy_file_d "$(kernel_path "$arch")" "/usr/local/bin/mihomo" 0755
    deploy_file_d "$D_BUILD_DIR/config.yaml" "$DIR_D/config.yaml" 0644
    deploy_file_d "$D_BUILD_DIR/.env" "$DIR_D/.env" 0600
    deploy_file_d "$D_BUILD_DIR/D-config" "$DIR_D/D-config" 0644
    deploy_file_d "$D_BUILD_DIR/GeoSite.dat" "$DIR_D/GeoSite.dat" 0644
        # entrypoint.sh + lib — без них не обновляется nftables
    deploy_file_d "$PROJECT_ROOT/deploy/scripts/entrypoint.sh" "$DIR_D/scripts/entrypoint.sh" 0755
    deploy_file_d "$PROJECT_ROOT/deploy/lib/env.sh" "$DIR_D/lib/env.sh" 0644
    deploy_file_d "$PROJECT_ROOT/deploy/lib/http.sh" "$DIR_D/lib/http.sh" 0644
    [[ -f "$D_BUILD_DIR/geoip.metadb" ]] && deploy_file_d "$D_BUILD_DIR/geoip.metadb" "$DIR_D/geoip.metadb" 0644
    deploy_file_d "$D_BUILD_DIR/mihomo.service" "/etc/systemd/system/mihomo.service" 0644
    deploy_file_d "$D_BUILD_DIR/tunnel.service" "/etc/systemd/system/tunnel.service" 0644

    "${SSH_D[@]}" "$target_D" "mihomo -t -d '$DIR_D' -f '$DIR_D/config.yaml'" \
        || fail "mihomo -t на D не прошёл"

    if [[ "$CHANGED" == true ]]; then
        info "systemctl restart mihomo.service на D"
        "${SSH_D[@]}" "$target_D" "systemctl daemon-reload && systemctl restart mihomo.service && systemctl is-active --quiet mihomo.service" \
            || fail "mihomo.service на D не перезапустился"
        ok "mihomo.service перезапущен"
    else
        skip "D: изменений нет"
    fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    check_deps
    ensure_dirs

    if [[ "$DO_BUILD" == true || "$DO_DEPLOY" == true || "$DO_PUBLISH" == true ]]; then
        backup_keys_once
    fi

    [[ -f "$PARAMS_ENV" ]] || fail "Не найден $PARAMS_ENV (создайте из шаблона, см. --help)"

    if [[ "$TARGET" == "D" ]]; then
        load_instance_params || fail "Не удалось загрузить параметры экземпляра $INSTANCE_ID"
    else
        load_params || fail "Не удалось загрузить $PARAMS_ENV"
    fi
    load_env "$GLOBAL_KEYS_ENV" 2>/dev/null || true
    if [[ "$KEYS_ENV" != "$GLOBAL_KEYS_ENV" ]]; then
        load_env "$KEYS_ENV" 2>/dev/null || true
    fi

    info "TARGET=$TARGET  INSTANCE=$INSTANCE_ID  BUILD=$DO_BUILD  DEPLOY=$DO_DEPLOY  PUBLISH=$DO_PUBLISH  CHECK=$DO_CHECK  FORCE=$FORCE"
    kv "params.env" "$PARAMS_ENV"
    kv "keys.env"   "$KEYS_ENV"

    step "Проверка params.env"
    validate_params "$TARGET" || fail "Исправьте params.env и повторите"
    validate_d_connection_lists || fail "Исправьте списки подключений D_TO_B_INSTANCES / D_TO_C_INSTANCES"
    validate_d_instance_collisions || fail "Исправьте конфликты экземпляров D"

    if [[ "$DO_CHECK" == true || "$DO_DEPLOY" == true || "$DO_PUBLISH" == true ]]; then
        step "Проверка доступности серверов"
        _v_errors=0
        validate_connectivity "$TARGET" || fail "Серверы недоступны, исправьте и повторите"

        step "Проверка URL ядра Mihomo"
        _v_errors=0
        validate_kernel_url "$TARGET" || fail "URL ядра недоступен, исправьте версию"
    fi

    if [[ "$DO_CHECK" == true ]]; then
        show_plan "$TARGET"
        step "Проверка завершена"
        ok "Всё готово к запуску"
        info "Запустите без --check для выполнения"
        return 0
    fi

    if [[ "$DO_BUILD" == true ]]; then
        case "$TARGET" in
            all) ensure_key A; ensure_key B; build_A; build_B; build_C; build_D; build_users ;;
            A)   ensure_key A; build_A; build_users ;;
            B)   ensure_key B; ensure_key BA; ensure_key BC; build_B ;;
            C)   ensure_key C; ensure_key BC; build_C ;;
            D)   ensure_key D; build_D ;;
        esac
    fi

    if [[ "$DO_PUBLISH" == true ]]; then
        publish_D
    fi

    if [[ "$DO_DEPLOY" == true ]]; then
        case "$TARGET" in
            all) deploy_A; deploy_B; deploy_C; deploy_D ;;
            A)   deploy_A ;;
            B)   deploy_B ;;
            C)   deploy_C ;;
            D)   deploy_D ;;
        esac
    fi

    step "Готово"
    ok "Артефакты в $BUILD_DIR"
    if [[ "$DO_DEPLOY" == false && "$DO_PUBLISH" == false ]]; then
        info "Деплой не выполнялся (--deploy/--publish не указаны)"
    fi
}

main "$@"