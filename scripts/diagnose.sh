#!/bin/bash
# =============================================================================
# scripts/diagnose.sh — полная диагностика конфигов A/B/C/D
# Версия: 3.3.0
# Дата:   2026-11-07
# Автор:  @smg38
#
# Запуск: scripts/diagnose.sh [--no-remote]
#   --no-remote  — только локальная проверка (без SSH)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

# --- Единые YAML-парсеры (используются и в check-keys-sync.sh) ---
YAML_LIB="$SCRIPT_DIR/lib/yaml.sh"
[[ -f "$YAML_LIB" ]] || { echo "Нет $YAML_LIB" >&2; exit 2; }
# shellcheck disable=SC1090
source "$YAML_LIB"
ENV_LIB="$PROJECT_ROOT/deploy/lib/env.sh"
[[ -f "$ENV_LIB" ]] || { echo "Нет $ENV_LIB" >&2; exit 2; }
# shellcheck disable=SC1090
source "$ENV_LIB"

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'

ERRORS=0
WARNINGS=0
OK_COUNT=0

step() { printf '\n%s%s==>%s %s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$1"; }
info() { printf '%s  ·%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; OK_COUNT=$((OK_COUNT+1)); }
skip() { printf '%s  =%s %s\n' "$C_DIM" "$C_RESET" "$1"; }
warn() { printf '%s  ⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$1"; ERRORS=$((ERRORS+1)); }

have() { command -v "$1" >/dev/null 2>&1; }

# --- Пути ---
KEYS_ENV="$PROJECT_ROOT/build/keys/keys.env"
PARAMS_ENV="$PROJECT_ROOT/build/keys/params.env"
TEMPLATER="$PROJECT_ROOT/scripts/templater.sh"

CFG_A="$PROJECT_ROOT/build/A/config.yaml"
CFG_B="$PROJECT_ROOT/build/B/config.yaml"
CFG_C="$PROJECT_ROOT/build/C/config.yaml"
CFG_D="$PROJECT_ROOT/build/D/config.yaml"

SVC_B="$PROJECT_ROOT/build/B/mihomo.service"
SVC_C="$PROJECT_ROOT/build/C/mihomo.service"
SVC_D="$PROJECT_ROOT/build/D/mihomo.service"
SVC_D_TUNNEL="$PROJECT_ROOT/build/D/tunnel.service"

NGX_C="$PROJECT_ROOT/build/C/nginx-mihomo.conf"

D_CONFIG="$PROJECT_ROOT/build/D/D-config"
D_ENV="$PROJECT_ROOT/build/D/.env"
D_INSTALLER="$PROJECT_ROOT/build/D/D-install.run"
D_GEOSITE="$PROJECT_ROOT/build/D/GeoSite.dat"
C_GEOSITE="$PROJECT_ROOT/build/C/GeoSite.dat"

USER_YAML_TPL="$PROJECT_ROOT/template/user.yaml.j3"
USER_TXT_TPL="$PROJECT_ROOT/template/user.txt.j3"

# --- SSH ---
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)
REMOTE_USER="${REMOTE_USER:-root}"

# --- Аргументы ---
NO_REMOTE=false
for arg in "$@"; do
    case "$arg" in
        --no-remote) NO_REMOTE=true ;;
        --help|-h) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный аргумент: $arg"; exit 1 ;;
    esac
done

# =============================================================================
# Утилиты
# =============================================================================
ssh_target() {
    local host="$1"
    [[ "$host" == *@* ]] && { printf '%s' "$host"; return; }
    printf '%s@%s' "$REMOTE_USER" "$host"
}

# §5.3: пустое значение показываем как <пусто>, а не ***.
# Иначе ошибка вида "serverD.uuid (***) != UUID_DB" не говорит, что
# на самом деле парсер вернул пустую строку.
mask() {
    local v="$1"
    if [[ -z "$v" ]]; then printf '<пусто>'; return; fi
    (( ${#v} <= 12 )) && printf '***' || printf '%s...%s' "${v:0:6}" "${v: -4}"
}

is_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
is_x25519() { [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]; }
is_short_id() { [[ "$1" =~ ^[0-9a-fA-F]{1,16}$ ]]; }

# --- Загрузка env-файлов ---
declare -A ENV_KEYS=()
declare -A ENV_PARAMS=()

load_and_capture_env_file() {
    local file="$1" map_name="$2" _diagnose_env_line _diagnose_env_key _diagnose_env_value
    load_env_file "$file" || return 1
    while IFS= read -r _diagnose_env_line || [[ -n "$_diagnose_env_line" ]]; do
        _diagnose_env_line="${_diagnose_env_line%$'\r'}"
        _diagnose_env_line="${_diagnose_env_line#"${_diagnose_env_line%%[![:space:]]*}"}"
        if [[ "$_diagnose_env_line" =~ ^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            _diagnose_env_key="${BASH_REMATCH[2]}"
            if [[ -v "$_diagnose_env_key" ]]; then
                _diagnose_env_value="${!_diagnose_env_key}"
            else
                _diagnose_env_value=""
            fi
            if [[ "$map_name" == "keys" ]]; then
                ENV_KEYS["$_diagnose_env_key"]="$_diagnose_env_value"
            else
                ENV_PARAMS["$_diagnose_env_key"]="$_diagnose_env_value"
            fi
        fi
    done < "$file"
}

# YAML-парсеры (yaml_get, yaml_get_in_block, yaml_user_uuid,
# yaml_server_names, yaml_short_id_listener, yaml_proxy_field)
# — из scripts/lib/yaml.sh (подключён в начале).

# =============================================================================
# 1. Загрузка параметров
# =============================================================================
step "Загрузка keys.env и params.env"

load_and_capture_env_file "$KEYS_ENV" keys || { fail "Нет или ошибка разбора $KEYS_ENV"; exit 1; }
validate_env_file_literal "$PARAMS_ENV" || { fail "Нельзя загрузить $PARAMS_ENV: используйте буквальные значения"; exit 1; }
load_and_capture_env_file "$PARAMS_ENV" params || { fail "Нет или ошибка разбора $PARAMS_ENV"; exit 1; }
ok "keys.env: ${#ENV_KEYS[@]} переменных"
ok "params.env: ${#ENV_PARAMS[@]} переменных"

IP_A="${ENV_PARAMS[IP_A]:-}"; PORT_A="${ENV_PARAMS[PORT_A]:-}"; DIR_A="${ENV_PARAMS[DIR_A]:-}"
IP_B="${ENV_PARAMS[IP_B]:-}"; PORT_B="${ENV_PARAMS[PORT_B]:-}"; DIR_B="${ENV_PARAMS[DIR_B]:-}"
IP_C="${ENV_PARAMS[IP_C]:-}"; PORT_C="${ENV_PARAMS[PORT_C]:-}"; DIR_C="${ENV_PARAMS[DIR_C]:-}"
IP_D="${ENV_PARAMS[IP_D]:-}"; PORT_D="${ENV_PARAMS[PORT_D]:-}"; DIR_D="${ENV_PARAMS[DIR_D]:-}"
ARCH_D="${ENV_PARAMS[ARCH_D]:-amd64}"
GEO_MODE="${ENV_PARAMS[GEO_MODE]:-local}"
SECRET_KEY_D="${ENV_PARAMS[SECRET_KEY_D]:-}"
TUNNEL_C_HOST="${ENV_PARAMS[TUNNEL_C_HOST]:-$IP_C}"
TUNNEL_C_USER="${ENV_PARAMS[TUNNEL_C_USER]:-root}"
TUNNEL_C_PORT="${ENV_PARAMS[TUNNEL_C_PORT]:-22}"
TUNNEL_REMOTE_PORT="${ENV_PARAMS[TUNNEL_REMOTE_PORT]:-2222}"
TUNNEL_KEY="${ENV_PARAMS[TUNNEL_KEY]:-/root/.ssh/id_ed25519_tunnel}"
WEB_DIR_REMOTE="${ENV_PARAMS[WEB_DIR_REMOTE]:-/var/www/html/mihomo}"

USERS_A="${ENV_PARAMS[USERS_A]:-}"
USERS_C="${ENV_PARAMS[USERS_C]:-}"
FLOW_AB="${ENV_PARAMS[FLOW_AB]:-xtls-rprx-vision}"
FLOW_USERS="${ENV_PARAMS[FLOW_USERS]:-xtls-rprx-vision}"
LOCAL_A="${ENV_PARAMS[LOCAL_A]:-1}"
SERVERNAME="${ENV_PARAMS[SERVERNAME]:-}"
FINGERPRINT="${ENV_PARAMS[FINGERPRINT]:-}"

if [[ -z "$SERVERNAME" ]]; then
    fail "SERVERNAME не задан в params.env"
else
    ok "SERVERNAME = $SERVERNAME"
fi

if [[ -z "$FINGERPRINT" ]]; then
    fail "FINGERPRINT не задан в params.env"
else
    ok "FINGERPRINT = $FINGERPRINT"
fi

# =============================================================================
# 2. Локальные артефакты A/B/C
# =============================================================================
step "Локальные артефакты A/B/C"
for f in "$CFG_A" "$CFG_B" "$CFG_C" "$SVC_B" "$SVC_C" "$NGX_C"; do
    [[ -f "$f" ]] && ok "$(basename "$(dirname "$f")")/$(basename "$f")" || fail "нет $f"
done

# =============================================================================
# 3. Локальные артефакты D
# =============================================================================
step "Локальные артефакты D"
for f in "$CFG_D" "$SVC_D" "$SVC_D_TUNNEL" "$D_CONFIG" "$D_ENV" "$D_INSTALLER"; do
    [[ -f "$f" ]] && ok "$(basename "$(dirname "$f")")/$(basename "$f")" || fail "нет $f"
done

if [[ -f "$D_GEOSITE" ]]; then
    ok "build/D/GeoSite.dat ($(du -h "$D_GEOSITE" | cut -f1))"
elif [[ -f "$C_GEOSITE" ]]; then
    warn "build/D/GeoSite.dat нет, но есть build/C/GeoSite.dat — build_D должен был скопировать"
else
    fail "GeoSite.dat нет ни в build/D, ни в build/C (обязателен, category-ru)"
fi

if [[ -f "$D_INSTALLER.sha256" ]]; then
    expected=$(awk '{print $1}' "$D_INSTALLER.sha256")
    actual=$(sha256sum "$D_INSTALLER" | awk '{print $1}')
    [[ "$expected" == "$actual" ]] && ok "D-install.run SHA256 OK" || fail "D-install.run SHA256 не совпадает"
else
    warn "Нет D-install.run.sha256"
fi

# =============================================================================
# 4. Конфиг A — все поля
# =============================================================================
step "Конфиг A — проверка полей"

A_LISTEN_PORT=$(yaml_get_in_block "$CFG_A" 'name:[[:space:]]*vless-in' "port")
[[ "$A_LISTEN_PORT" == "$PORT_A" ]] && ok "A: listener.port == PORT_A ($PORT_A)" || fail "A: listener.port ($A_LISTEN_PORT) != PORT_A ($PORT_A)"

A_DEST=$(yaml_get "$CFG_A" "dest")
A_DEST_HOST="${A_DEST%%:*}"
[[ "$A_DEST_HOST" == "$SERVERNAME" ]] && ok "A: reality-config.dest.host == SERVERNAME" || fail "A: reality-config.dest.host ($A_DEST_HOST) != SERVERNAME"

A_SNAMES=$(yaml_server_names "$CFG_A")
[[ "$A_SNAMES" == "$SERVERNAME" ]] && ok "A: server-names[0] == SERVERNAME" || fail "A: server-names[0] ($A_SNAMES) != SERVERNAME"

A_PRIV=$(yaml_get "$CFG_A" "private-key")
[[ "$A_PRIV" == "${ENV_KEYS[PRIVATE_KEY_A]:-}" ]] && ok "A: private-key == PRIVATE_KEY_A" || fail "A: private-key mismatch"

A_SID=$(yaml_short_id_listener "$CFG_A")
[[ "$A_SID" == "${ENV_KEYS[SHORT_ID_A]:-}" ]] && ok "A: short-id == SHORT_ID_A" || fail "A: short-id mismatch"

for u in $USERS_A; do
    uu=$(yaml_user_uuid "$CFG_A" "$u")
    expect="${ENV_KEYS[UUID_A_${u}]:-}"
    [[ "$uu" == "$expect" ]] && ok "A: user '$u' uuid == UUID_A_$u" || fail "A: user '$u' uuid mismatch"
    uflow=$(yaml_get_in_block "$CFG_A" "username:[[:space:]]*$u" "flow")
    [[ "$uflow" == "$FLOW_USERS" ]] && ok "A: user '$u' flow == FLOW_USERS" || fail "A: user '$u' flow ($uflow) != FLOW_USERS"
done

A_P_UUID=$(yaml_get_in_block "$CFG_A" 'name:[[:space:]]*"to-serverB"' "uuid")
[[ "$A_P_UUID" == "${ENV_KEYS[UUID_BA]:-}" ]] && ok "A: to-serverB.uuid == UUID_BA" || fail "A: to-serverB.uuid mismatch"

A_P_SRV=$(yaml_get_in_block "$CFG_A" 'name:[[:space:]]*"to-serverB"' "server")
[[ "$A_P_SRV" == "$IP_B" ]] && ok "A: to-serverB.server == IP_B" || fail "A: to-serverB.server mismatch"

A_P_PORT=$(yaml_get_in_block "$CFG_A" 'name:[[:space:]]*"to-serverB"' "port")
[[ "$A_P_PORT" == "$PORT_B" ]] && ok "A: to-serverB.port == PORT_B" || fail "A: to-serverB.port mismatch"

A_P_SNI=$(yaml_get_in_block "$CFG_A" 'name:[[:space:]]*"to-serverB"' "servername")
[[ "$A_P_SNI" == "$SERVERNAME" ]] && ok "A: to-serverB.servername == SERVERNAME" || fail "A: to-serverB.servername mismatch"

A_P_PK=$(yaml_get_in_block "$CFG_A" 'name:[[:space:]]*"to-serverB"' "public-key")
[[ "$A_P_PK" == "${ENV_KEYS[PUBLIC_KEY_B]:-}" ]] && ok "A: to-serverB.public-key == PUBLIC_KEY_B" || fail "A: to-serverB.public-key mismatch"

A_P_SID=$(yaml_get_in_block "$CFG_A" 'name:[[:space:]]*"to-serverB"' "short-id")
[[ "$A_P_SID" == "${ENV_KEYS[SHORT_ID_B]:-}" ]] && ok "A: to-serverB.short-id == SHORT_ID_B" || fail "A: to-serverB.short-id mismatch"

A_P_FLOW=$(yaml_get_in_block "$CFG_A" 'name:[[:space:]]*"to-serverB"' "flow")
[[ "$A_P_FLOW" == "$FLOW_AB" ]] && ok "A: to-serverB.flow == FLOW_AB" || fail "A: to-serverB.flow mismatch"

# =============================================================================
# 5. Конфиг B — все поля
# =============================================================================
step "Конфиг B — проверка полей"

B_LISTEN_PORT=$(yaml_get_in_block "$CFG_B" 'name:[[:space:]]*vless-in' "port")
[[ "$B_LISTEN_PORT" == "$PORT_B" ]] && ok "B: listener.port == PORT_B" || fail "B: listener.port ($B_LISTEN_PORT) != PORT_B ($PORT_B)"

B_DEST=$(yaml_get "$CFG_B" "dest")
B_DEST_HOST="${B_DEST%%:*}"
[[ "$B_DEST_HOST" == "$SERVERNAME" ]] && ok "B: reality-config.dest.host == SERVERNAME" || fail "B: reality-config.dest.host ($B_DEST_HOST) != SERVERNAME"

B_SNAMES=$(yaml_server_names "$CFG_B")
[[ "$B_SNAMES" == "$SERVERNAME" ]] && ok "B: server-names[0] == SERVERNAME" || fail "B: server-names[0] ($B_SNAMES) != SERVERNAME"

B_PRIV=$(yaml_get "$CFG_B" "private-key")
[[ "$B_PRIV" == "${ENV_KEYS[PRIVATE_KEY_B]:-}" ]] && ok "B: private-key == PRIVATE_KEY_B" || fail "B: private-key mismatch"

B_SID=$(yaml_short_id_listener "$CFG_B")
[[ "$B_SID" == "${ENV_KEYS[SHORT_ID_B]:-}" ]] && ok "B: short-id == SHORT_ID_B" || fail "B: short-id mismatch"

B_UUID_A=$(yaml_user_uuid "$CFG_B" "serverA")
[[ "$B_UUID_A" == "${ENV_KEYS[UUID_BA]:-}" ]] && ok "B: serverA.uuid == UUID_BA" || fail "B: serverA.uuid mismatch"

B_UUID_C=$(yaml_user_uuid "$CFG_B" "serverC")
[[ "$B_UUID_C" == "${ENV_KEYS[UUID_BC]:-}" ]] && ok "B: serverC.uuid == UUID_BC" || fail "B: serverC.uuid mismatch"

B_UUID_D=$(yaml_user_uuid "$CFG_B" "serverD")
[[ "$B_UUID_D" == "${ENV_KEYS[UUID_DB]:-}" ]] && ok "B: serverD.uuid == UUID_DB" || fail "B: serverD.uuid ($(mask "$B_UUID_D")) != UUID_DB"

B_P_UUID=$(yaml_get_in_block "$CFG_B" 'name:[[:space:]]*"to-serverC"' "uuid")
[[ "$B_P_UUID" == "${ENV_KEYS[UUID_BC]:-}" ]] && ok "B: to-serverC.uuid == UUID_BC" || fail "B: to-serverC.uuid mismatch"

B_P_SRV=$(yaml_get_in_block "$CFG_B" 'name:[[:space:]]*"to-serverC"' "server")
[[ "$B_P_SRV" == "$IP_C" ]] && ok "B: to-serverC.server == IP_C" || fail "B: to-serverC.server mismatch"

B_P_PORT=$(yaml_get_in_block "$CFG_B" 'name:[[:space:]]*"to-serverC"' "port")
[[ "$B_P_PORT" == "$PORT_C" ]] && ok "B: to-serverC.port == PORT_C" || fail "B: to-serverC.port mismatch"

B_P_SNI=$(yaml_get_in_block "$CFG_B" 'name:[[:space:]]*"to-serverC"' "servername")
[[ "$B_P_SNI" == "$SERVERNAME" ]] && ok "B: to-serverC.servername == SERVERNAME" || fail "B: to-serverC.servername mismatch"

B_P_PK=$(yaml_get_in_block "$CFG_B" 'name:[[:space:]]*"to-serverC"' "public-key")
[[ "$B_P_PK" == "${ENV_KEYS[PUBLIC_KEY_C]:-}" ]] && ok "B: to-serverC.public-key == PUBLIC_KEY_C" || fail "B: to-serverC.public-key mismatch"

B_P_SID=$(yaml_get_in_block "$CFG_B" 'name:[[:space:]]*"to-serverC"' "short-id")
[[ "$B_P_SID" == "${ENV_KEYS[SHORT_ID_C]:-}" ]] && ok "B: to-serverC.short-id == SHORT_ID_C" || fail "B: to-serverC.short-id mismatch"

B_P_FLOW=$(yaml_get_in_block "$CFG_B" 'name:[[:space:]]*"to-serverC"' "flow")
[[ "$B_P_FLOW" == "$FLOW_AB" ]] && ok "B: to-serverC.flow == FLOW_AB" || fail "B: to-serverC.flow mismatch"

B_BA=$(yaml_get "$CFG_B" "bind-address")
if [[ "$B_BA" == "127.0.0.1" || "$B_BA" == "localhost" ]]; then
    fail "B: bind-address ($B_BA) — заворачивает исходящие в loopback"
else
    ok "B: bind-address не 127.0.0.1 ($B_BA)"
fi

if grep -qE '^external-ui:' "$CFG_B"; then
    warn "B: external-ui задан — mihomo ретраит скачивание UI"
fi

# =============================================================================
# 6. Конфиг C — все поля
# =============================================================================
step "Конфиг C — проверка полей"

C_LISTEN_PORT=$(yaml_get_in_block "$CFG_C" 'name:[[:space:]]*vless-in' "port")
[[ "$C_LISTEN_PORT" == "$PORT_C" ]] && ok "C: listener.port == PORT_C" || fail "C: listener.port ($C_LISTEN_PORT) != PORT_C ($PORT_C)"

C_DEST=$(yaml_get "$CFG_C" "dest")
C_DEST_HOST="${C_DEST%%:*}"
[[ "$C_DEST_HOST" == "$SERVERNAME" ]] && ok "C: reality-config.dest.host == SERVERNAME" || fail "C: reality-config.dest.host ($C_DEST_HOST) != SERVERNAME"

C_SNAMES=$(yaml_server_names "$CFG_C")
[[ "$C_SNAMES" == "$SERVERNAME" ]] && ok "C: server-names[0] == SERVERNAME" || fail "C: server-names[0] ($C_SNAMES) != SERVERNAME"

C_PRIV=$(yaml_get "$CFG_C" "private-key")
[[ "$C_PRIV" == "${ENV_KEYS[PRIVATE_KEY_C]:-}" ]] && ok "C: private-key == PRIVATE_KEY_C" || fail "C: private-key mismatch"

C_SID=$(yaml_short_id_listener "$CFG_C")
[[ "$C_SID" == "${ENV_KEYS[SHORT_ID_C]:-}" ]] && ok "C: short-id == SHORT_ID_C" || fail "C: short-id mismatch"

C_UUID_B=$(yaml_user_uuid "$CFG_C" "serverB")
[[ "$C_UUID_B" == "${ENV_KEYS[UUID_BC]:-}" ]] && ok "C: serverB.uuid == UUID_BC" || fail "C: serverB.uuid mismatch"

C_UUID_D=$(yaml_user_uuid "$CFG_C" "serverD")
[[ "$C_UUID_D" == "${ENV_KEYS[UUID_DC]:-}" ]] && ok "C: serverD.uuid == UUID_DC" || fail "C: serverD.uuid ($(mask "$C_UUID_D")) != UUID_DC"

for u in $USERS_C; do
    uu=$(yaml_user_uuid "$CFG_C" "$u")
    expect="${ENV_KEYS[UUID_C_${u}]:-}"
    [[ "$uu" == "$expect" ]] && ok "C: user '$u' uuid == UUID_C_$u" || fail "C: user '$u' uuid mismatch"
    uflow=$(yaml_get_in_block "$CFG_C" "username:[[:space:]]*$u" "flow")
    [[ "$uflow" == "$FLOW_USERS" ]] && ok "C: user '$u' flow == FLOW_USERS" || fail "C: user '$u' flow ($uflow) != FLOW_USERS"
done

C_P_UUID=$(yaml_get_in_block "$CFG_C" 'name:[[:space:]]*"to-serverB"' "uuid")
[[ "$C_P_UUID" == "${ENV_KEYS[UUID_BC]:-}" ]] && ok "C: to-serverB.uuid == UUID_BC" || fail "C: to-serverB.uuid mismatch"

C_P_SRV=$(yaml_get_in_block "$CFG_C" 'name:[[:space:]]*"to-serverB"' "server")
[[ "$C_P_SRV" == "$IP_B" ]] && ok "C: to-serverB.server == IP_B" || fail "C: to-serverB.server mismatch"

C_P_PORT=$(yaml_get_in_block "$CFG_C" 'name:[[:space:]]*"to-serverB"' "port")
[[ "$C_P_PORT" == "$PORT_B" ]] && ok "C: to-serverB.port == PORT_B" || fail "C: to-serverB.port mismatch"

C_P_SNI=$(yaml_get_in_block "$CFG_C" 'name:[[:space:]]*"to-serverB"' "servername")
[[ "$C_P_SNI" == "$SERVERNAME" ]] && ok "C: to-serverB.servername == SERVERNAME" || fail "C: to-serverB.servername mismatch"

C_P_PK=$(yaml_get_in_block "$CFG_C" 'name:[[:space:]]*"to-serverB"' "public-key")
[[ "$C_P_PK" == "${ENV_KEYS[PUBLIC_KEY_B]:-}" ]] && ok "C: to-serverB.public-key == PUBLIC_KEY_B" || fail "C: to-serverB.public-key mismatch"

C_P_SID=$(yaml_get_in_block "$CFG_C" 'name:[[:space:]]*"to-serverB"' "short-id")
[[ "$C_P_SID" == "${ENV_KEYS[SHORT_ID_B]:-}" ]] && ok "C: to-serverB.short-id == SHORT_ID_B" || fail "C: to-serverB.short-id mismatch"

C_P_FLOW=$(yaml_get_in_block "$CFG_C" 'name:[[:space:]]*"to-serverB"' "flow")
[[ "$C_P_FLOW" == "$FLOW_AB" ]] && ok "C: to-serverB.flow == FLOW_AB" || fail "C: to-serverB.flow mismatch"

C_BA=$(yaml_get "$CFG_C" "bind-address")
if [[ "$C_BA" == "127.0.0.1" || "$C_BA" == "localhost" ]]; then
    fail "C: bind-address ($C_BA) — заворачивает исходящие в loopback"
else
    ok "C: bind-address не 127.0.0.1 ($C_BA)"
fi

if grep -qE '^external-ui:' "$CFG_C"; then
    warn "C: external-ui задан — mihomo ретраит скачивание UI"
fi

# =============================================================================
# 7. Конфиг D — все поля
# =============================================================================
step "Конфиг D — проверка полей"

D_TPROXY=$(yaml_get "$CFG_D" "tproxy-port")
[[ "$D_TPROXY" == "$PORT_D" ]] && ok "D: tproxy-port == PORT_D ($PORT_D)" || fail "D: tproxy-port ($D_TPROXY) != PORT_D ($PORT_D)"

D_MIXED=$(yaml_get "$CFG_D" "mixed-port")
[[ "$D_MIXED" == "7890" ]] && ok "D: mixed-port == 7890" || fail "D: mixed-port ($D_MIXED) != 7890"

D_SECRET=$(yaml_get "$CFG_D" "secret")
[[ "$D_SECRET" == "$SECRET_KEY_D" ]] && ok "D: secret == SECRET_KEY_D" || fail "D: secret mismatch"

D_GEO=$(yaml_get "$CFG_D" "geo-auto-update")
[[ "$D_GEO" == "false" ]] && ok "D: geo-auto-update: false" || warn "D: geo-auto-update ($D_GEO) != false (GeoSite.dat уже подложен)"

D_C_UUID=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverC"' "uuid")
[[ "$D_C_UUID" == "${ENV_KEYS[UUID_DC]:-}" ]] && ok "D: to-serverC.uuid == UUID_DC" || fail "D: to-serverC.uuid ($(mask "$D_C_UUID")) != UUID_DC"

D_C_SRV=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverC"' "server")
[[ "$D_C_SRV" == "$IP_C" ]] && ok "D: to-serverC.server == IP_C" || fail "D: to-serverC.server ($D_C_SRV) != IP_C"

D_C_PORT=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverC"' "port")
[[ "$D_C_PORT" == "$PORT_C" ]] && ok "D: to-serverC.port == PORT_C" || fail "D: to-serverC.port ($D_C_PORT) != PORT_C"

D_C_PK=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverC"' "public-key")
[[ "$D_C_PK" == "${ENV_KEYS[PUBLIC_KEY_C]:-}" ]] && ok "D: to-serverC.public-key == PUBLIC_KEY_C" || fail "D: to-serverC.public-key mismatch"

D_C_SID=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverC"' "short-id")
[[ "$D_C_SID" == "${ENV_KEYS[SHORT_ID_C]:-}" ]] && ok "D: to-serverC.short-id == SHORT_ID_C" || fail "D: to-serverC.short-id mismatch"

D_B_UUID=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverB"' "uuid")
[[ "$D_B_UUID" == "${ENV_KEYS[UUID_DB]:-}" ]] && ok "D: to-serverB.uuid == UUID_DB" || fail "D: to-serverB.uuid ($(mask "$D_B_UUID")) != UUID_DB"

D_B_SRV=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverB"' "server")
[[ "$D_B_SRV" == "$IP_B" ]] && ok "D: to-serverB.server == IP_B" || fail "D: to-serverB.server ($D_B_SRV) != IP_B"

D_B_PORT=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverB"' "port")
[[ "$D_B_PORT" == "$PORT_B" ]] && ok "D: to-serverB.port == PORT_B" || fail "D: to-serverB.port ($D_B_PORT) != PORT_B"

D_B_PK=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverB"' "public-key")
[[ "$D_B_PK" == "${ENV_KEYS[PUBLIC_KEY_B]:-}" ]] && ok "D: to-serverB.public-key == PUBLIC_KEY_B" || fail "D: to-serverB.public-key mismatch"

D_B_SID=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverB"' "short-id")
[[ "$D_B_SID" == "${ENV_KEYS[SHORT_ID_B]:-}" ]] && ok "D: to-serverB.short-id == SHORT_ID_B" || fail "D: to-serverB.short-id mismatch"

# GEO_MODE
case "$GEO_MODE" in
    local)
        if grep -qE 'GEOSITE,category-ru,DIRECT' "$CFG_D"; then
            ok "D: GEO_MODE=local, GEOSITE,category-ru,DIRECT есть"
        else
            fail "D: GEO_MODE=local, но нет GEOSITE,category-ru,DIRECT"
        fi
        if grep -qE 'GEOIP,RU,DIRECT' "$CFG_D"; then
            ok "D: GEO_MODE=local, GEOIP,RU,DIRECT есть"
        else
            fail "D: GEO_MODE=local, но нет GEOIP,RU,DIRECT"
        fi
        ;;
    remote)
        if grep -qE 'GEOSITE,category-ru,DIRECT' "$CFG_D"; then
            fail "D: GEO_MODE=remote, но есть GEOSITE,category-ru,DIRECT (должно быть только MATCH,PROXY)"
        else
            ok "D: GEO_MODE=remote, без category-ru"
        fi
        ;;
    *)
        fail "D: GEO_MODE=$GEO_MODE — допустимо: local, remote"
        ;;
esac

# D-config
if [[ -f "$D_CONFIG" ]]; then
    if grep -q '{{' "$D_CONFIG"; then
        fail "D: D-config содержит {{ }} — не отрендерен"
    else
        ok "D: D-config без {{ }}"
    fi
    D_CFG_GEO=$(grep -E '^GEO_MODE=' "$D_CONFIG" | cut -d= -f2)
    [[ "$D_CFG_GEO" == "$GEO_MODE" ]] && ok "D: D-config.GEO_MODE == params.env.GEO_MODE" || fail "D: D-config.GEO_MODE ($D_CFG_GEO) != params.env.GEO_MODE ($GEO_MODE)"
fi

# .env
if [[ -f "$D_ENV" ]]; then
    if grep -q '{{' "$D_ENV"; then
        fail "D: .env содержит {{ }} — не отрендерен"
    else
        ok "D: .env без {{ }}"
    fi
fi

# mihomo.service
if [[ -f "$SVC_D" ]]; then
    if grep -q '{{' "$SVC_D"; then
        fail "D: mihomo.service содержит {{ }} — не отрендерен"
    else
        ok "D: mihomo.service без {{ }}"
    fi
    if grep -qE "ExecStart=/bin/bash .*entrypoint.sh" "$SVC_D"; then
        ok "D: mihomo.service запускает entrypoint.sh"
    else
        fail "D: mihomo.service не запускает entrypoint.sh"
    fi
fi

# tunnel.service
if [[ -f "$SVC_D_TUNNEL" ]]; then
    if grep -q '{{' "$SVC_D_TUNNEL"; then
        fail "D: tunnel.service содержит {{ }} — не отрендерен"
    else
        ok "D: tunnel.service без {{ }}"
    fi
    if grep -q "127.0.0.1:${TUNNEL_REMOTE_PORT}:localhost:22" "$SVC_D_TUNNEL"; then
        ok "D: tunnel.service -R 127.0.0.1:${TUNNEL_REMOTE_PORT}:localhost:22"
    else
        fail "D: tunnel.service не содержит 127.0.0.1:${TUNNEL_REMOTE_PORT}:localhost:22 (проверьте TUNNEL_REMOTE_PORT в params.env и рендер шаблона)"
    fi
    if grep -q "0.0.0.0:${TUNNEL_REMOTE_PORT}" "$SVC_D_TUNNEL"; then
        fail "D: tunnel.service содержит 0.0.0.0:${TUNNEL_REMOTE_PORT} — порт откроется наружу!"
    else
        ok "D: tunnel.service без 0.0.0.0:${TUNNEL_REMOTE_PORT}"
    fi
    if grep -qE "IdentitiesOnly=yes" "$SVC_D_TUNNEL"; then
        ok "D: tunnel.service IdentitiesOnly=yes"
    else
        warn "D: tunnel.service без IdentitiesOnly=yes"
    fi
    # §5.2: формулировка исправлена. Ключ может быть в файле,
    # но grep не найдёт из-за неверного TUNNEL_KEY в params.env (с inline-комментарием,
    # до §5.4-доп). Теперь TUNNEL_KEY очищен от комментария, и grep работает.
    if grep -qE -- "-i ${TUNNEL_KEY}" "$SVC_D_TUNNEL"; then
        ok "D: tunnel.service -i $TUNNEL_KEY"
    else
        fail "D: tunnel.service не содержит '-i $TUNNEL_KEY' (проверьте TUNNEL_KEY в params.env и рендер шаблона)"
    fi
fi

# =============================================================================
# 8. Клиентские шаблоны
# =============================================================================
step "Клиентские шаблоны (с рендером)"

render_extract() {
    local tpl="$1" field="$2"
    [[ -f "$tpl" && -x "$TEMPLATER" ]] || { echo ""; return; }
    local tmp; tmp=$(mktemp)
    "$TEMPLATER" -e "$PARAMS_ENV" -e "$KEYS_ENV" -o "$tmp" "$tpl" >/dev/null 2>&1 || true
    yaml_get "$tmp" "$field"
    rm -f "$tmp"
}

render_extract_sni() {
    local tpl="$1"
    [[ -f "$tpl" && -x "$TEMPLATER" ]] || { echo ""; return; }
    local tmp; tmp=$(mktemp)
    "$TEMPLATER" -e "$PARAMS_ENV" -e "$KEYS_ENV" -o "$tmp" "$tpl" >/dev/null 2>&1 || true
    grep -oE 'sni=[^&]+' "$tmp" 2>/dev/null | head -1 | sed 's/^sni=//'
    rm -f "$tmp"
}

YAML_TPL_SNI=$(render_extract "$USER_YAML_TPL" "servername")
TXT_TPL_SNI=$(render_extract_sni "$USER_TXT_TPL")

[[ -n "$YAML_TPL_SNI" ]] && ok "user.yaml.j3 → servername = $YAML_TPL_SNI" || fail "user.yaml.j3: servername не извлёкся"
[[ -n "$TXT_TPL_SNI"  ]] && ok "user.txt.j3 → sni = $TXT_TPL_SNI"        || fail "user.txt.j3: sni не извлёкся"

[[ "$YAML_TPL_SNI" == "$SERVERNAME" ]] && ok "user.yaml.j3.servername == SERVERNAME" || fail "user.yaml.j3.servername ($YAML_TPL_SNI) != SERVERNAME"
[[ "$TXT_TPL_SNI"  == "$SERVERNAME" ]] && ok "user.txt.j3.sni == SERVERNAME"        || fail "user.txt.j3.sni ($TXT_TPL_SNI) != SERVERNAME"

# =============================================================================
# 9. Отрендеренные клиенты A/C
# =============================================================================
step "Отрендеренные клиенты build/users, build/web"

for srv in A C; do
    case "$srv" in
        A) users="$USERS_A"; ip="$IP_A"; port="$PORT_A"; pk="${ENV_KEYS[PUBLIC_KEY_A]:-}"; sid="${ENV_KEYS[SHORT_ID_A]:-}" ;;
        C) users="$USERS_C"; ip="$IP_C"; port="$PORT_C"; pk="${ENV_KEYS[PUBLIC_KEY_C]:-}"; sid="${ENV_KEYS[SHORT_ID_C]:-}" ;;
    esac
    [[ -z "$users" ]] && continue

    for u in $users; do
        yf="$PROJECT_ROOT/build/users/${srv}_${u}.yaml"
        tf="$PROJECT_ROOT/build/web/${srv}_${u}.txt"
        expect_uuid="${ENV_KEYS[UUID_${srv}_${u}]:-}"

        if [[ -f "$yf" ]]; then
            s_sni=$(yaml_get "$yf" "servername")
            s_uuid=$(yaml_get "$yf" "uuid")
            s_srv=$(yaml_get "$yf" "server")
            s_port=$(yaml_get "$yf" "port")
            s_pk=$(yaml_get "$yf" "public-key")
            s_sid=$(yaml_get "$yf" "short-id")

            [[ "$s_sni"  == "$SERVERNAME" ]] && ok "${srv}_${u}.yaml: servername == SERVERNAME"   || fail "${srv}_${u}.yaml: servername mismatch"
            [[ "$s_uuid" == "$expect_uuid" ]] && ok "${srv}_${u}.yaml: uuid == UUID_${srv}_${u}"  || fail "${srv}_${u}.yaml: uuid mismatch"
            [[ "$s_srv"  == "$ip" ]]          && ok "${srv}_${u}.yaml: server == IP_${srv}"      || fail "${srv}_${u}.yaml: server mismatch"
            [[ "$s_port" == "$port" ]]        && ok "${srv}_${u}.yaml: port == PORT_${srv}"      || fail "${srv}_${u}.yaml: port mismatch"
            [[ "$s_pk"   == "$pk" ]]          && ok "${srv}_${u}.yaml: public-key == PUBLIC_KEY_${srv}" || fail "${srv}_${u}.yaml: public-key mismatch"
            [[ "$s_sid"  == "$sid" ]]         && ok "${srv}_${u}.yaml: short-id == SHORT_ID_${srv}"     || fail "${srv}_${u}.yaml: short-id mismatch"
        else
            fail "нет $yf"
        fi

        if [[ -f "$tf" ]]; then
            dec=$(base64 -d "$tf" 2>/dev/null || cat "$tf")
            t_uuid=$(printf '%s' "$dec" | sed -nE 's|^vless://([^@]+)@.*|\1|p' | head -1)
            t_sni=$(printf '%s' "$dec" | grep -oE 'sni=[^&]+' | head -1 | sed 's/^sni=//')
            t_pbk=$(printf '%s' "$dec" | grep -oE 'pbk=[^&]+' | head -1 | sed 's/^pbk=//')
            t_sid=$(printf '%s' "$dec" | grep -oE 'sid=[^&#]+' | head -1 | sed 's/^sid=//')
            t_at=$(printf '%s' "$dec" | sed -nE 's|^vless://[^@]+@([^:]+):([0-9]+).*|\1|p' | head -1)
            t_port=$(printf '%s' "$dec" | sed -nE 's|^vless://[^@]+@([^:]+):([0-9]+).*|\2|p' | head -1)

            [[ -n "$t_uuid" ]]                && ok "${srv}_${u}.txt: uuid извлечён"           || fail "${srv}_${u}.txt: uuid не извлечён"
            [[ "$t_uuid" == "$expect_uuid" ]] && ok "${srv}_${u}.txt: uuid == UUID_${srv}_${u}" || fail "${srv}_${u}.txt: uuid mismatch"
            [[ "$t_sni"  == "$SERVERNAME" ]] && ok "${srv}_${u}.txt: sni == SERVERNAME"     || fail "${srv}_${u}.txt: sni mismatch"
            [[ "$t_pbk"  == "$pk" ]]          && ok "${srv}_${u}.txt: pbk == PUBLIC_KEY_${srv}" || fail "${srv}_${u}.txt: pbk mismatch"
            [[ "$t_sid"  == "$sid" ]]         && ok "${srv}_${u}.txt: sid == SHORT_ID_${srv}"   || fail "${srv}_${u}.txt: sid mismatch"
            [[ "$t_at"   == "$ip" ]]          && ok "${srv}_${u}.txt: host == IP_${srv}"        || fail "${srv}_${u}.txt: host mismatch"
            [[ "$t_port" == "$port" ]]        && ok "${srv}_${u}.txt: port == PORT_${srv}"      || fail "${srv}_${u}.txt: port mismatch"
        else
            fail "нет $tf"
        fi
    done
done

# =============================================================================
# 10. Ключи X25519 — парность
# =============================================================================
step "Пары X25519"

if have openssl && have xxd; then
    for srv in A B C D; do
        priv="${ENV_KEYS[PRIVATE_KEY_$srv]:-}"
        pub="${ENV_KEYS[PUBLIC_KEY_$srv]:-}"
        [[ -z "$priv" || -z "$pub" ]] && { fail "$srv: нет ключей"; continue; }

        ph=$(printf '%s' "$priv" | tr '_-' '/+' | awk '{while(length($0)%4)$0=$0"=";print}' | base64 -d 2>/dev/null | xxd -p -c 256)
        uh=$(printf '%s' "$pub"  | tr '_-' '/+' | awk '{while(length($0)%4)$0=$0"=";print}' | base64 -d 2>/dev/null | xxd -p -c 256)
        [[ ${#ph} -ne 64 || ${#uh} -ne 64 ]] && { warn "$srv: ключи не 32 байта"; continue; }

        tmp=$(mktemp)
        printf '302e020100300506032b656e04220420%s' "$ph" | xxd -r -p > "$tmp"
        ex=$(openssl pkey -inform DER -in "$tmp" -pubout -outform DER 2>/dev/null | xxd -p -c 256)
        rm -f "$tmp"
        ex_raw="${ex:24}"
        [[ "$ex_raw" == "$uh" ]] && ok "$srv: PRIVATE_KEY ↔ PUBLIC_KEY — ПАРНЫЕ" || fail "$srv: PRIVATE_KEY ↔ PUBLIC_KEY — НЕ ПАРНЫЕ"
    done
else
    fail "нет openssl или xxd — парность не проверена"
fi

# =============================================================================
# 11. Форматы ключей
# =============================================================================
step "Формат ключей в keys.env"
fmt_bad=0
for name in "${!ENV_KEYS[@]}"; do
    v="${ENV_KEYS[$name]}"
    case "$name" in
        UUID_*)         is_uuid "$v"     || { fail "$name — не UUID"; fmt_bad=$((fmt_bad+1)); } ;;
        PRIVATE_KEY_*|PUBLIC_KEY_*) is_x25519 "$v" || { fail "$name — не X25519 (len ${#v})"; fmt_bad=$((fmt_bad+1)); } ;;
        SHORT_ID_*)     is_short_id "$v" || { fail "$name — не hex 1-16"; fmt_bad=$((fmt_bad+1)); } ;;
    esac
done
(( fmt_bad == 0 )) && ok "все ключи/UUID/short_id корректны"

# =============================================================================
# 12. support-x25519mlkem768 и FINGERPRINT
# =============================================================================
a_client_mlkem=$(yaml_get_in_block "$CFG_A" 'name:[[:space:]]*"to-serverB"' "support-x25519mlkem768")
b_server_mlkem=$(yaml_get_in_block "$CFG_B" 'reality-config' "support-x25519mlkem768")
if [[ "$a_client_mlkem" == "$b_server_mlkem" || ( -z "$a_client_mlkem" && "$b_server_mlkem" == "false" ) || ( -z "$b_server_mlkem" && "$a_client_mlkem" == "false" ) ]]; then
    ok "A→B: support-x25519mlkem768 согласован"
else
    fail "A→B: support-x25519mlkem768 не согласован (client=$a_client_mlkem, server=$b_server_mlkem)"
fi

c_client_mlkem=$(yaml_get_in_block "$CFG_C" 'name:[[:space:]]*"to-serverB"' "support-x25519mlkem768")
if [[ "${c_client_mlkem:-false}" == "${b_server_mlkem:-false}" ]]; then
    ok "C→B: support-x25519mlkem768 согласован"
else
    fail "C→B: support-x25519mlkem768 не согласован"
fi

b_client_mlkem=$(yaml_get_in_block "$CFG_B" 'name:[[:space:]]*"to-serverC"' "support-x25519mlkem768")
c_server_mlkem=$(yaml_get_in_block "$CFG_C" 'reality-config' "support-x25519mlkem768")
if [[ "${b_client_mlkem:-false}" == "${c_server_mlkem:-false}" ]]; then
    ok "B→C: support-x25519mlkem768 согласован"
else
    fail "B→C: support-x25519mlkem768 не согласован"
fi

# D→C / D→B
d_client_mlkem=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverC"' "support-x25519mlkem768")
if [[ "${d_client_mlkem:-false}" == "${c_server_mlkem:-false}" ]]; then
    ok "D→C: support-x25519mlkem768 согласован"
else
    fail "D→C: support-x25519mlkem768 не согласован"
fi
d_client_b_mlkem=$(yaml_get_in_block "$CFG_D" 'name:[[:space:]]*"to-serverB"' "support-x25519mlkem768")
if [[ "${d_client_b_mlkem:-false}" == "${b_server_mlkem:-false}" ]]; then
    ok "D→B: support-x25519mlkem768 согласован"
else
    fail "D→B: support-x25519mlkem768 не согласован"
fi

for pair in "A:$CFG_A:to-serverB" "B:$CFG_B:to-serverC" "C:$CFG_C:to-serverB" "D:$CFG_D:to-serverC" "D:$CFG_D:to-serverB"; do
    IFS=':' read -r srv cfg proxy <<< "$pair"
    fp=$(yaml_get_in_block "$cfg" "name:[[:space:]]*\"$proxy\"" "client-fingerprint")
    if [[ "$fp" == "$FINGERPRINT" ]]; then
        ok "$srv: $proxy.client-fingerprint == FINGERPRINT ($FINGERPRINT)"
    else
        fail "$srv: $proxy.client-fingerprint ($fp) != FINGERPRINT ($FINGERPRINT)"
    fi
done

# =============================================================================
# 13. Удалённая проверка
# =============================================================================
if [[ "$NO_REMOTE" == true ]]; then
    step "Удалённая проверка пропущена (--no-remote)"
else
    step "Удалённая проверка серверов"

    check_remote() {
        local name="$1" host="$2" port="$3" dir="$4" cfg="$5"
        [[ -z "$host" ]] && { warn "$name: IP не задан"; return; }

        local target; target=$(ssh_target "$host")

        if ! "${SSH[@]}" "$target" "true" 2>/dev/null; then
            fail "$name ($target): SSH недоступен"
            return
        fi
        ok "$name: SSH OK"

        local remote_cfg; remote_cfg=$(mktemp)
        if "${SSH[@]}" "$target" "cat '$dir/config.yaml'" > "$remote_cfg" 2>/dev/null; then
            ok "$name: remote config.yaml получен"

            r_dest=$(yaml_get "$remote_cfg" "dest"); r_dest_host="${r_dest%%:*}"
            [[ "$r_dest_host" == "$SERVERNAME" ]] && ok "$name remote: dest.host == SERVERNAME" || fail "$name remote: dest.host"

            r_snames=$(yaml_server_names "$remote_cfg")
            [[ "$r_snames" == "$SERVERNAME" ]] && ok "$name remote: server-names[0] == SERVERNAME" || fail "$name remote: server-names[0]"

            r_port=$(yaml_get_in_block "$remote_cfg" 'name:[[:space:]]*vless-in' "port")
            [[ "$r_port" == "$port" ]] && ok "$name remote: port == $port" || fail "$name remote: port"

            if [[ "$name" == "B" ]]; then
                r_ua=$(yaml_user_uuid "$remote_cfg" "serverA")
                [[ "$r_ua" == "${ENV_KEYS[UUID_BA]:-}" ]] && ok "B remote: serverA.uuid == UUID_BA" || fail "B remote: serverA.uuid mismatch"
                r_uc=$(yaml_user_uuid "$remote_cfg" "serverC")
                [[ "$r_uc" == "${ENV_KEYS[UUID_BC]:-}" ]] && ok "B remote: serverC.uuid == UUID_BC" || fail "B remote: serverC.uuid mismatch"
                r_ud=$(yaml_user_uuid "$remote_cfg" "serverD")
                [[ "$r_ud" == "${ENV_KEYS[UUID_DB]:-}" ]] && ok "B remote: serverD.uuid == UUID_DB" || fail "B remote: serverD.uuid mismatch"
            fi
            if [[ "$name" == "C" ]]; then
                r_ub=$(yaml_user_uuid "$remote_cfg" "serverB")
                [[ "$r_ub" == "${ENV_KEYS[UUID_BC]:-}" ]] && ok "C remote: serverB.uuid == UUID_BC" || fail "C remote: serverB.uuid mismatch"
                r_ud=$(yaml_user_uuid "$remote_cfg" "serverD")
                [[ "$r_ud" == "${ENV_KEYS[UUID_DC]:-}" ]] && ok "C remote: serverD.uuid == UUID_DC" || fail "C remote: serverD.uuid mismatch"
                for u in $USERS_C; do
                    ru=$(yaml_user_uuid "$remote_cfg" "$u")
                    exp="${ENV_KEYS[UUID_C_${u}]:-}"
                    [[ "$ru" == "$exp" ]] && ok "C remote: user '$u' uuid == UUID_C_$u" || fail "C remote: user '$u' uuid mismatch"
                done
            fi

            if diff -q "$cfg" "$remote_cfg" >/dev/null 2>&1; then
                ok "$name: config.yaml на сервере == build/$name/config.yaml"
            else
                warn "$name: config.yaml на сервере отличается от build/$name/config.yaml"
                diff "$cfg" "$remote_cfg" | head -10 | sed 's/^/      /'
            fi
        else
            fail "$name: не удалось прочитать $dir/config.yaml"
        fi
        rm -f "$remote_cfg"

        if "${SSH[@]}" "$target" "ss -tln 2>/dev/null | grep -qE ':$port '" 2>/dev/null; then
            ok "$name: :$port слушает"
        else
            fail "$name: :$port НЕ слушает"
        fi

        if "${SSH[@]}" "$target" "systemctl is-active --quiet mihomo" 2>/dev/null; then
            ok "$name: mihomo active"
        else
            fail "$name: mihomo НЕ active"
        fi

        if [[ -n "$SERVERNAME" ]]; then
            tls_out=$("${SSH[@]}" "$target" "timeout 10 openssl s_client -connect ${SERVERNAME}:443 -servername ${SERVERNAME} </dev/null 2>&1 | head -20" 2>/dev/null || echo "")
            if printf '%s' "$tls_out" | grep -q "CONNECTED"; then
                ok "$name: TLS к $SERVERNAME:443 — OK"
            else
                fail "$name: TLS к $SERVERNAME:443 — FAIL"
                printf '%s\n' "$tls_out" | head -5 | sed 's/^/      /'
            fi
        fi
    }

    if [[ "$LOCAL_A" == "1" ]]; then
        info "A: LOCAL_A=1 — SSH не проверяется"
    elif [[ -n "$IP_A" ]]; then
        check_remote "A" "$IP_A" "$PORT_A" "$DIR_A" "$CFG_A"
    fi
    [[ -n "$IP_B" ]] && check_remote "B" "$IP_B" "$PORT_B" "$DIR_B" "$CFG_B"
    [[ -n "$IP_C" ]] && check_remote "C" "$IP_C" "$PORT_C" "$DIR_C" "$CFG_C"

    # --- D через ProxyCommand C ---
    step "Удалённая проверка D (через ProxyCommand C)"
    if [[ -n "$IP_D" && -n "$IP_C" ]]; then
        local_proxy="ssh -p $TUNNEL_C_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new $TUNNEL_C_USER@$TUNNEL_C_HOST -W %h:%p"
        SSH_D=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o "ProxyCommand=$local_proxy" -p "$TUNNEL_REMOTE_PORT")
        target_D="${JUMP_D_USER:-root}@localhost"

        if ! "${SSH_D[@]}" "$target_D" true 2>/dev/null; then
            fail "D: SSH через ProxyCommand C недоступен (bootstrap не выполнен или туннель не работает)"
        else
            ok "D: SSH через ProxyCommand C OK"

            if "${SSH_D[@]}" "$target_D" "systemctl is-active --quiet mihomo" 2>/dev/null; then
                ok "D: mihomo active"
            else
                fail "D: mihomo НЕ active"
            fi

            if "${SSH_D[@]}" "$target_D" "systemctl is-active --quiet tunnel" 2>/dev/null; then
                ok "D: tunnel active"
            else
                fail "D: tunnel НЕ active"
            fi

            if "${SSH_D[@]}" "$target_D" "nft list table clash >/dev/null 2>&1"; then
                ok "D: nft table clash есть"
            else
                fail "D: nft table clash отсутствует"
            fi

            if "${SSH_D[@]}" "$target_D" "ip rule show | grep -Eq 'fwmark 0x1 (.* )?lookup 100'"; then
                ok "D: ip rule fwmark 0x1 lookup 100 есть"
            else
                fail "D: ip rule fwmark 0x1 lookup 100 отсутствует"
            fi

            if "${SSH_D[@]}" "$target_D" "ss -tln | grep -q ':${PORT_D} '"; then
                ok "D: :${PORT_D} (tproxy) слушает"
            else
                fail "D: :${PORT_D} (tproxy) НЕ слушает"
            fi

            if "${SSH_D[@]}" "$target_D" "ss -tln | grep -q ':1053 '"; then
                ok "D: :1053 (DNS) слушает"
            else
                fail "D: :1053 (DNS) НЕ слушает"
            fi

            # Порт на C
            if "${SSH[@]}" "$(ssh_target "$TUNNEL_C_HOST")" "ss -tln | grep -q '127.0.0.1:${TUNNEL_REMOTE_PORT} '" 2>/dev/null; then
                ok "C: 127.0.0.1:${TUNNEL_REMOTE_PORT} слушает"
            else
                fail "C: 127.0.0.1:${TUNNEL_REMOTE_PORT} НЕ слушает"
            fi
            if "${SSH[@]}" "$(ssh_target "$TUNNEL_C_HOST")" "ss -tln | grep -q '0.0.0.0:${TUNNEL_REMOTE_PORT} '" 2>/dev/null; then
                fail "C: 0.0.0.0:${TUNNEL_REMOTE_PORT} слушает — GatewayPorts включён!"
            else
                ok "C: 0.0.0.0:${TUNNEL_REMOTE_PORT} НЕ слушает (хорошо)"
            fi
        fi
    else
        warn "D: IP_D или IP_C не заданы — пропуск удалённой проверки D"
    fi

    # Сетевая достижимость B ↔ C
    step "Сетевая достижимость B ↔ C"
    if [[ -n "$IP_B" && -n "$IP_C" ]]; then
        "${SSH[@]}" "$(ssh_target "$IP_C")" "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/$IP_B/$PORT_B'" 2>/dev/null && ok "C → B:$PORT_B TCP" || fail "C → B:$PORT_B недоступен"
        "${SSH[@]}" "$(ssh_target "$IP_B")" "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/$IP_C/$PORT_C'" 2>/dev/null && ok "B → C:$PORT_C TCP" || fail "B → C:$PORT_C недоступен"
    fi

    # Часы
    step "Проверка часов B и C"
    if [[ -n "$IP_B" ]]; then
        clock_b=$("${SSH[@]}" "$(ssh_target "$IP_B")" 'date -u; timedatectl status | grep synchronized' 2>/dev/null)
        [[ -n "$clock_b" ]] && ok "B: $clock_b" || fail "B: не удалось получить время"
    fi
    if [[ -n "$IP_C" ]]; then
        clock_c=$("${SSH[@]}" "$(ssh_target "$IP_C")" 'date -u; timedatectl status | grep synchronized' 2>/dev/null)
        [[ -n "$clock_c" ]] && ok "C: $clock_c" || fail "C: не удалось получить время"
    fi
fi

# =============================================================================
# Итоги
# =============================================================================
step "Итоги"

err_color="$C_GREEN"; (( ERRORS > 0 )) && err_color="$C_RED"
warn_color="$C_GREEN"; (( WARNINGS > 0 )) && warn_color="$C_YELLOW"

printf '\n  Успешных проверок: %s%d%s\n' "$C_GREEN" "$OK_COUNT" "$C_RESET"
printf '  Ошибок: %s%d%s\n' "$err_color" "$ERRORS" "$C_RESET"
printf '  Предупреждений: %s%d%s\n' "$warn_color" "$WARNINGS" "$C_RESET"

if (( ERRORS > 0 )); then
    printf '\n%s  ✗ Есть проблемы%s\n' "$C_RED" "$C_RESET" >&2
    exit 1
fi
printf '\n%s  ✓ Все проверки пройдены%s\n' "$C_GREEN" "$C_RESET"
exit 0