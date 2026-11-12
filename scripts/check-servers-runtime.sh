#!/bin/bash
# =============================================================================
# check-servers-runtime.sh — проверка runtime B/C/D. Прямой SSH к D, если есть,
# иначе — через ProxyCommand C. Версии Mihomo, порты, REALITY auth, health-check,
# TLS, ML-KEM, reverse-туннель.
#
# Версия: 3.3.0
# Дата:   2026-11-07
# Автор:  @smg38
#
#   scripts/check-servers-runtime.sh            # авто: прямой D → fallback C
#   scripts/check-servers-runtime.sh --no-d     # без D
#   scripts/check-servers-runtime.sh --via-c    # принудительно через C
#   scripts/check-servers-runtime.sh --instance D2 # проверить экземпляр D2
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || { echo "не найден проект: $PROJECT_ROOT" >&2; exit 2; }

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'

ERRORS=0; WARNINGS=0; OK_COUNT=0
WITH_D=true
FORCE_VIA_C=false
INSTANCE_ID=D
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-d)    WITH_D=false ;;
        --via-c)   FORCE_VIA_C=true ;;
        --instance)
            [[ $# -ge 2 ]] || { echo "--instance требует ID" >&2; exit 2; }
            INSTANCE_ID="$2"
            shift 2
            continue
            ;;
        --help|-h) sed -n '2,13p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$INSTANCE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_]*$ ]] || { echo "Недопустимый ID: $INSTANCE_ID" >&2; exit 2; }

step() { printf '\n%s%s==>%s %s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$1"; }
info() { printf '%s  ·%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; OK_COUNT=$((OK_COUNT+1)); }
skip() { printf '%s  =%s %s\n' "$C_DIM" "$C_RESET" "$1"; }
warn() { printf '%s  ⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$1"; ERRORS=$((ERRORS+1)); }

# -----------------------------------------------------------------------------
# Входные
# -----------------------------------------------------------------------------
KEYS_ENV="$PROJECT_ROOT/build/keys/keys.env"
PARAMS_ENV="$PROJECT_ROOT/build/keys/params.env"
ENV_LIB="$PROJECT_ROOT/deploy/lib/env.sh"
for f in "$PARAMS_ENV" "$KEYS_ENV" "$ENV_LIB"; do
    [[ -f "$f" ]] || { echo "Нет $f" >&2; exit 2; }
done
# shellcheck disable=SC1090
source "$ENV_LIB"
load_env_file_literal "$PARAMS_ENV" || { echo "Не удалось загрузить $PARAMS_ENV" >&2; exit 2; }
if [[ "$INSTANCE_ID" != D ]]; then
    INSTANCE_ENV="$PROJECT_ROOT/build/instances/$INSTANCE_ID.env"
    [[ -f "$INSTANCE_ENV" ]] || { echo "Нет $INSTANCE_ENV" >&2; exit 2; }
    validate_d_instance_file "$INSTANCE_ENV" || { echo "Ошибка в $INSTANCE_ENV" >&2; exit 2; }
    load_env_file_literal "$INSTANCE_ENV" || { echo "Не удалось загрузить $INSTANCE_ENV" >&2; exit 2; }
fi
load_env_file "$KEYS_ENV"   || { echo "Не удалось загрузить $KEYS_ENV" >&2; exit 2; }

: "${IP_B:?IP_B не задан}"
: "${PORT_B:?PORT_B не задан}"
: "${IP_C:?IP_C не задан}"
: "${PORT_C:?PORT_C не задан}"
: "${IP_D:?IP_D не задан}"
: "${SERVERNAME:?SERVERNAME не задан}"
: "${FINGERPRINT:?FINGERPRINT не задан}"
: "${SECRET_KEY_D:?SECRET_KEY_D не задан}"

LOCAL_A="${LOCAL_A:-1}"
DIR_B="${DIR_B:-/opt/mihomo}"
DIR_C="${DIR_C:-/opt/mihomo}"
DIR_D="${DIR_D:-/opt/mihomo}"

D_CONFIG="$PROJECT_ROOT/build/$INSTANCE_ID/D-config"
if [[ -f "$D_CONFIG" ]]; then
    load_env_file "$D_CONFIG" || { echo "Не удалось загрузить $D_CONFIG" >&2; exit 2; }
elif [[ "$WITH_D" == true ]]; then
    echo "Нет $D_CONFIG (сначала соберите экземпляр $INSTANCE_ID)" >&2
    exit 2
fi
: "${TUNNEL_C_HOST:=$IP_C}"
: "${TUNNEL_C_USER:=root}"
: "${TUNNEL_C_PORT:=22}"
: "${TUNNEL_REMOTE_PORT:=2222}"
: "${REMOTE_PORT_D:=$TUNNEL_REMOTE_PORT}"
: "${JUMP_D_USER:=root}"

REMOTE_USER="${REMOTE_USER:-root}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

ssh_target() { local h="$1"; [[ "$h" == *@* ]] && printf '%s' "$h" || printf '%s@%s' "$REMOTE_USER" "$h"; }
ssh_run()    { local h="$1"; shift; ssh "${SSH_OPTS[@]}" "$(ssh_target "$h")" "$@" 2>/dev/null; }

# -----------------------------------------------------------------------------
# D: выбор маршрута (прямой → fallback ProxyCommand C)
# -----------------------------------------------------------------------------
D_MODE=""
ssh_d() {
    local cmd="$*"
    case "$D_MODE" in
        direct)  timeout 20 ssh "${SSH_OPTS[@]}" "$(ssh_target "$IP_D")" "$cmd" ;;
        via_c)   timeout 20 ssh "${SSH_OPTS[@]}" \
                     -o "ProxyCommand=ssh -p $TUNNEL_C_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new $TUNNEL_C_USER@$TUNNEL_C_HOST -W %h:%p" \
                     -p "$REMOTE_PORT_D" "$JUMP_D_USER@localhost" "$cmd" ;;
        *)       return 1 ;;
    esac 2>/dev/null
}

select_d_route() {
    $WITH_D || return 0
    if $FORCE_VIA_C; then
        D_MODE="via_c"
        info "D: принудительно через ProxyCommand C (--via-c)"
        return 0
    fi
    # 1) прямой SSH до D
    if timeout 10 ssh "${SSH_OPTS[@]}" "$(ssh_target "$IP_D")" true 2>/dev/null; then
        D_MODE="direct"
        ok "D: прямой SSH ($IP_D) доступен — используем его"
        return 0
    fi
    # 2) fallback: через C
    local proxy="ssh -p $TUNNEL_C_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new $TUNNEL_C_USER@$TUNNEL_C_HOST -W %h:%p"
    if timeout 10 ssh "${SSH_OPTS[@]}" -o "ProxyCommand=$proxy" -p "$REMOTE_PORT_D" "$JUMP_D_USER@localhost" true 2>/dev/null; then
        D_MODE="via_c"
        warn "D: прямой SSH недоступен — fallback через ProxyCommand C"
        return 0
    fi
    D_MODE=""
    fail "D: недоступен ни напрямую ($IP_D), ни через C"
    info "  → проверь sshd и tunnel.service на D"
    return 1
}

# -----------------------------------------------------------------------------
# Нормализация grep -c (устраняет "0\n0" в (( )))
# -----------------------------------------------------------------------------
count_matches() {  # <host> <pattern> [via_d]
    local host="$1" pat="$2" use_d="${3:-false}" raw
    if [[ "$use_d" == "true" ]]; then
        raw=$(ssh_d "journalctl -u mihomo --no-pager -q -n 1000 2>/dev/null | grep -c '$pat' || true")
    else
        raw=$(ssh_run "$host" "journalctl -u mihomo --no-pager -q -n 1000 2>/dev/null | grep -c '$pat' || true")
    fi
    raw="${raw//$'\n'/ }"
    printf '%s' "$raw" | awk '{s=0; for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; print s+0}'
}

parse_ver() { local raw="$1"; [[ "$raw" =~ \ (v[0-9]+\.[0-9]+\.[0-9]+)[[:space:]] ]] && printf '%s' "${BASH_REMATCH[1]}" || printf '%s' "$raw"; }

# =============================================================================
# 0. SSH B/C + выбор маршрута к D
# =============================================================================
step "0. Доступность B/C и маршрут к D"
for v in IP_B IP_C; do
    h="${!v}"
    ssh_run "$h" true && ok "$v ($h): SSH OK" || fail "$v ($h): SSH недоступен"
done
select_d_route || true
D_REACHABLE=false
[[ -n "$D_MODE" ]] && ssh_d true && D_REACHABLE=true
$D_REACHABLE && ok "D: маршрут $D_MODE работает" || { $WITH_D && fail "D: маршрут не работает"; }

# =============================================================================
# 1. Версии Mihomo
# =============================================================================
step "1. Версии Mihomo на B/C/D"
ver_b=$(ssh_run "$IP_B" "mihomo -v 2>&1 | head -1" || true)
ver_c=$(ssh_run "$IP_C" "mihomo -v 2>&1 | head -1" || true)
pv_b=$(parse_ver "$ver_b"); pv_c=$(parse_ver "$ver_c")
[[ -n "$ver_b" ]] && ok "B: $ver_b" || fail "B: версия неизвестна"
[[ -n "$ver_c" ]] && ok "C: $ver_c" || fail "C: версия неизвестна"
if $D_REACHABLE; then
    ver_d=$(ssh_d "mihomo -v 2>&1 | head -1" || true)
    pv_d=$(parse_ver "$ver_d")
    [[ -n "$ver_d" ]] && ok "D: $ver_d" || fail "D: версия неизвестна"
fi
[[ -n "$pv_b" && "$pv_b" == "$pv_c" ]] && ok "B == C ($pv_b)" || fail "B != C"
if $D_REACHABLE && [[ -n "${pv_d:-}" ]]; then
    [[ "$pv_d" == "$pv_c" ]] && ok "D == C ($pv_d)" || fail "D ($pv_d) != C ($pv_c)"
fi

# =============================================================================
# 2. Mihomo active + порты
# =============================================================================
step "2. Mihomo active и порты"
check_svc_port() {
    local host="$1" label="$2" port="$3" via_d="$4"
    if [[ "$via_d" == "true" ]]; then
        ssh_d "systemctl is-active --quiet mihomo" && ok "$label: mihomo active" || fail "$label: mihomo НЕ active"
        ssh_d "ss -tln | grep -q ':${port} '" && ok "$label: TCP :${port}" || fail "$label: TCP :${port} НЕ слушает"
    else
        ssh_run "$host" "systemctl is-active --quiet mihomo" && ok "$label: mihomo active" || fail "$label: mihomo НЕ active"
        ssh_run "$host" "ss -tln | grep -q ':${port} '" && ok "$label: TCP :${port}" || fail "$label: TCP :${port} НЕ слушает"
    fi
}
check_svc_port "$IP_B" "B" "$PORT_B" false
check_svc_port "$IP_C" "C" "$PORT_C" false
if $D_REACHABLE; then
    for p in 7890 7893 1053; do
        ssh_d "ss -tln | grep -q ':${p} '" && ok "D: TCP :${p}" || fail "D: TCP :${p} НЕ слушает"
    done
fi
[[ "$(ssh_d 'sysctl -n net.ipv4.ip_forward')" == 1 ]] && ok "D: ip_forward=1" || warn "D: ip_forward=0" 

# =============================================================================
# 3. TCP D → C/B
# =============================================================================
if $D_REACHABLE; then
    step "3. TCP D → C/B"
    for spec in "C:$IP_C:$PORT_C" "B:$IP_B:$PORT_B"; do
        L="${spec%%:*}"; R="${spec#*:}"; h="${R%%:*}"; p="${R##*:}"
        ssh_d "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/${h}/${p}'" && ok "D → $L ($h:$p)" || fail "D → $L ($h:$p) недоступен"
    done
fi

# =============================================================================
# 4. TLS D → C/B
# =============================================================================
if $D_REACHABLE; then
    step "4. TLS-хендшейк D → C/B (SNI=$SERVERNAME)"
    for spec in "C:$IP_C:$PORT_C" "B:$IP_B:$PORT_B"; do
        L="${spec%%:*}"; R="${spec#*:}"; h="${R%%:*}"; p="${R##*:}"
        out=$(ssh_d "timeout 10 openssl s_client -connect ${h}:${p} -servername ${SERVERNAME} </dev/null 2>&1" || true)
        if printf '%s' "$out" | grep -q 'BEGIN CERTIFICATE'; then
            ok "D → $L: на ClientHello получен сертификат dest"
        else
            fail "D → $L: на ClientHello нет ответа (данные не проходят D→$L)"
        fi
    done
fi

# =============================================================================
# 5. REALITY auth в журнале B/C
# =============================================================================
step "5. REALITY Authentication на B/C"
for spec in "C:$IP_C" "B:$IP_B"; do
    L="${spec%%:*}"; h="${spec#*:}"
    t=$(count_matches "$h" 'REALITY Authentication: true' false)
    f=$(count_matches "$h" 'REALITY Authentication: false' false)
    (( t > 0 )) && ok "$L: REALITY true ($t)" || warn "$L: REALITY true не найдено. Актуально только для debug."
    (( f > 0 )) && fail "$L: REALITY false ($f)"
done

# =============================================================================
# 6. Health-check API :9900 на D
# =============================================================================
if $D_REACHABLE; then
    step "6. Health-check API :9900 на D"
    # for p in to-serverC to-serverB; do
    #     resp=$(ssh_d "curl -sS -m 5 -H 'Authorization: Bearer ${SECRET_KEY_D}' 'http://127.0.0.1:9900/proxies/${p}'" || true)
    #     if [[ -z "$resp" ]]; then fail "D: API не отвечает для $p"; continue; fi
    #     alive=$(printf '%s' "$resp" | grep -o '"alive":[a-z]*' | head -1 | cut -d: -f2)
    #     delay=$(printf '%s' "$resp" | grep -o '"delay":[0-9]*' | head -1 | cut -d: -f2)
    #     [[ "$alive" == "true" ]] && ok "D: $p alive=true delay=${delay}ms" || fail "D: $p alive=false delay=${delay:-?}ms"
    # done
    for p in to-serverC to-serverB; do
    resp=$(ssh_d "curl -sS -m 10 -H 'Authorization: Bearer ${SECRET_KEY_D}' 'http://127.0.0.1:9900/proxies/${p}/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000'" || true)
    delay=$(printf '%s' "$resp" | grep -o '"delay":[0-9]*' | cut -d: -f2)
    [[ -n "$delay" ]] && ok "D: $p delay=${delay}ms" || fail "D: $p: ${resp:-нет ответа}"
done
fi

# =============================================================================
# 7. REALITY auth в журнале D
# =============================================================================
if $D_REACHABLE; then
    step "7. REALITY Authentication на D"
    t=$(count_matches "" 'REALITY Authentication: true' true)
    f=$(count_matches "" 'REALITY Authentication: false' true)
    (( t > 0 )) && ok "D: REALITY true ($t)" || warn "D: REALITY true не найдено. Актуально только для debug."
    (( f > 0 )) && fail "D: REALITY false ($f)"
fi

# =============================================================================
# 8. C/B выходят в интернет
# =============================================================================
step "8. C/B выходят в интернет"
for spec in "C:$IP_C" "B:$IP_B"; do
    L="${spec%%:*}"; h="${spec#*:}"
    code=$(ssh_run "$h" "curl -sS --max-time 10 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204" || echo 000)
    [[ "$code" == "204" ]] && ok "$L: gstatic 204" || fail "$L: gstatic $code"
done

# =============================================================================
# 9. ML-KEM client↔server
# =============================================================================
step "9. support-x25519mlkem768"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ssh_run "$IP_B" "cat '$DIR_B/config.yaml'" > "$tmp/b.yaml" 2>/dev/null || true
ssh_run "$IP_C" "cat '$DIR_C/config.yaml'" > "$tmp/c.yaml" 2>/dev/null || true
if $D_REACHABLE; then ssh_d "cat '$DIR_D/config.yaml'" > "$tmp/d.yaml" 2>/dev/null || true; fi
get_mlkem_client() { awk -v p="$2" '$0 ~ "name:[[:space:]]*\""p"\""{a=1;next} a&&/^  - name:/{exit} a&&/support-x25519mlkem768:/{v=$0;sub(/.*:[[:space:]]*/,"",v);gsub(/[[:space:]]/,"",v);print (v==""?"false":v);exit}' "$1" 2>/dev/null; }
get_mlkem_server() { awk '/name:[[:space:]]*vless-in/{a=1;next} a&&/^  - name:/{exit} a&&/support-x25519mlkem768:/{v=$0;sub(/.*:[[:space:]]*/,"",v);gsub(/[[:space:]]/,"",v);print (v==""?"false":v);exit}' "$1" 2>/dev/null; }
bc=$(get_mlkem_client "$tmp/b.yaml" "to-serverC"); cs=$(get_mlkem_server "$tmp/c.yaml")
[[ -n "$bc" && "$bc" == "$cs" ]] && ok "B→C: $bc" || fail "B→C: $bc != $cs"
cb=$(get_mlkem_client "$tmp/c.yaml" "to-serverB"); bs=$(get_mlkem_server "$tmp/b.yaml")
[[ -n "$cb" && "$cb" == "$bs" ]] && ok "C→B: $cb" || fail "C→B: $cb != $bs"
if $D_REACHABLE; then
    dc=$(get_mlkem_client "$tmp/d.yaml" "to-serverC"); [[ -n "$dc" && "$dc" == "$cs" ]] && ok "D→C: $dc" || fail "D→C: $dc != $cs"
    db=$(get_mlkem_client "$tmp/d.yaml" "to-serverB"); [[ -n "$db" && "$db" == "$bs" ]] && ok "D→B: $db" || fail "D→B: $db != $bs"
fi

# =============================================================================
# 10. Reverse tunnel D → C
# =============================================================================
if $D_REACHABLE; then
    step "10. Reverse SSH tunnel D → C"
    ssh_d "systemctl is-active --quiet tunnel.service" && ok "D: tunnel active" || fail "D: tunnel НЕ active"
fi
ssh_run "$IP_C" "ss -tln | grep -q '127.0.0.1:${TUNNEL_REMOTE_PORT} '" && ok "C: 127.0.0.1:${TUNNEL_REMOTE_PORT} слушает" || fail "C: 127.0.0.1:${TUNNEL_REMOTE_PORT} НЕ слушает"
ssh_run "$IP_C" "ss -tln | grep -q '0.0.0.0:${TUNNEL_REMOTE_PORT} '" && fail "C: 0.0.0.0:${TUNNEL_REMOTE_PORT} слушает (GatewayPorts!)" || ok "C: 0.0.0.0:${TUNNEL_REMOTE_PORT} НЕ слушает"

# =============================================================================
# Итог
# =============================================================================
step "Итоги"
printf '\n  ✓ %d   ', "$OK_COUNT"; (( ERRORS > 0 )) && printf '\033[0;31m✗ %d\033[0m   ' "$ERRORS" || printf '\033[0;32m✗ 0\033[0m   '; printf '\033[0;33m⚠ %d\033[0m\n' "$WARNINGS"
(( ERRORS > 0 )) && exit 1
exit 0