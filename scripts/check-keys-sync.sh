#!/bin/bash
# =============================================================================
# check-keys-sync.sh — проверка и восстановление синхронизации ключей/UUID
#                      и параметров между keys.env, params.env, build/* и
#                      реальными серверами A/B/C/D (по SSH).
# Версия: 3.3.0
# Дата:   2026-11-07
# Автор:  @smg38
#
# Назначение:
#   Ловит рассинхрон, из-за которого сервер D не может аутентифицироваться
#   на B/C (UUID_DB/UUID_DC, PUBLIC_KEY_C/SHORT_ID_C на C), а также пустые/
#   неверные TUNNEL_* и PORT_D.
#
#   ВАЖНО: проверяет не только build/* и keys.env, но и ФАКТИЧЕСКИЕ
#   /opt/mihomo/config.yaml на серверах A/B/C/D. Если на C старый
#   private-key/short-id/server-names — D не пройдёт Reality, и
#   health-check to-serverC будет alive=false (delay=0, Timeout).
#
# Использование (на A, из корня проекта):
#   scripts/check-keys-sync.sh              # проверка локально + удалённо
#   scripts/check-keys-sync.sh --no-remote  # только локальные артефакты
#   scripts/check-keys-sync.sh --fix        # починить keys.env из build/*
#   scripts/check-keys-sync.sh --fix-env    # починить params.env (TUNNEL_*, PORT_D)
#
# Что проверяет:
#   ЛОКАЛЬНО:
#   1. UUID_DB  в keys.env == serverD.uuid в build/B/config.yaml == build/D/config.yaml
#   2. UUID_DC  в keys.env == serverD.uuid в build/C/config.yaml == build/D/config.yaml
#   3. UUID_BA  в keys.env == serverA.uuid в build/B/config.yaml
#   4. UUID_BC  в keys.env == serverC.uuid в build/B/config.yaml
#   5. UUID_BC  в keys.env == serverB.uuid в build/C/config.yaml
#   6. PRIVATE_KEY_*/PUBLIC_KEY_* — парность X25519 в keys.env
#   7. PORT_D   в params.env == tproxy-port в build/D/config.yaml
#   8. TUNNEL_KEY / TUNNEL_REMOTE_PORT / TUNNEL_C_* в params.env не пусты
#      и реально подставлены в build/D/tunnel.service (без {{ }})
#   9. SERVERNAME/FINGERPRINT в params.env не пусты
#
#   УДАЛЁННО (--no-remote отключает):
#  10. На каждом сервере /opt/mihomo/config.yaml:
#      - private-key == PRIVATE_KEY_<srv> из keys.env
#      - public-key  (в reality-opts) == PUBLIC_KEY_<srv> из keys.env
#      - short-id    (в reality-config) == SHORT_ID_<srv> из keys.env
#      - server-names[0] == SERVERNAME
#      - для C: serverD.uuid == UUID_DC, serverB.uuid == UUID_BC,
#        user '<u>'.uuid == UUID_C_<u> для каждого USERS_C
#      - для B: serverA.uuid == UUID_BA, serverC.uuid == UUID_BC,
#        serverD.uuid == UUID_DB
#   11. На C: ss -tln | grep PORT_C (mihomo слушает), nft не блокирует PORT_C
#   12. Парность PRIVATE_KEY_<srv> (с сервера) ↔ PUBLIC_KEY_<srv> (keys.env)
#       — X25519: если на сервере старый приватный ключ, публичный не сойдётся
#
# Коды выхода:
#   0 — всё синхронно
#   1 — есть рассинхрон (см. вывод)
#   2 — не найдены входные файлы
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || { echo "не найден проект: $PROJECT_ROOT" >&2; exit 2; }

# --- Единые YAML-парсеры (используются и в diagnose.sh) ---
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

MODE_CHECK=true
MODE_FIX_KEYS=false
MODE_FIX_ENV=false
NO_REMOTE=false
for arg in "$@"; do
    case "$arg" in
        --fix)        MODE_FIX_KEYS=true;  MODE_CHECK=false ;;
        --fix-env)    MODE_FIX_ENV=true;   MODE_CHECK=false ;;
        --no-remote)  NO_REMOTE=true ;;
        --help|-h)
            sed -n '2,50p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный аргумент: $arg" >&2; exit 2 ;;
    esac
done

# -----------------------------------------------------------------------------
# Входные файлы
# -----------------------------------------------------------------------------
KEYS_ENV="$PROJECT_ROOT/build/keys/keys.env"
PARAMS_ENV="$PROJECT_ROOT/build/keys/params.env"
CFG_A="$PROJECT_ROOT/build/A/config.yaml"
CFG_B="$PROJECT_ROOT/build/B/config.yaml"
CFG_C="$PROJECT_ROOT/build/C/config.yaml"
CFG_D="$PROJECT_ROOT/build/D/config.yaml"
SVC_D_TUNNEL="$PROJECT_ROOT/build/D/tunnel.service"

for f in "$KEYS_ENV" "$PARAMS_ENV" "$CFG_B" "$CFG_C" "$CFG_D" "$SVC_D_TUNNEL"; do
    [[ -f "$f" ]] || { echo "Нет обязательного файла: $f" >&2; exit 2; }
done
validate_env_file_literal "$PARAMS_ENV" \
    || { echo "Ошибка в $PARAMS_ENV: используйте только буквальные значения" >&2; exit 2; }

# -----------------------------------------------------------------------------
# Значение env-файла извлекается через общий dotenv-парсер из deploy/lib/env.sh.
# Сам файл остаётся данными: load_env_file не исполняет его как shell-код.
# -----------------------------------------------------------------------------
env_file_value() {
    local file="$1" name="$2"
    load_env_file "$file" || return 1
    [[ -v "$name" ]] || return 1
    printf '%s' "${!name}"
}

# -----------------------------------------------------------------------------
# X25519: парность приватного (hex) и публичного (base64url) ключа
# -----------------------------------------------------------------------------
x25519_pair() {  # x25519_pair <priv_base64url> <pub_base64url>
    local priv="$1" pub="$2" ph uh tmp ex
    command -v openssl >/dev/null 2>&1 && command -v xxd >/dev/null 2>&1 || return 2
    ph=$(printf '%s' "$priv" | tr '_-' '/+' | awk '{while(length($0)%4)$0=$0"=";print}' | base64 -d 2>/dev/null | xxd -p -c 256)
    uh=$(printf '%s' "$pub"  | tr '_-' '/+' | awk '{while(length($0)%4)$0=$0"=";print}' | base64 -d 2>/dev/null | xxd -p -c 256)
    [[ ${#ph} -eq 64 && ${#uh} -eq 64 ]] || return 1
    tmp=$(mktemp)
    printf '302e020100300506032b656e04220420%s' "$ph" | xxd -r -p > "$tmp"
    ex=$(openssl pkey -inform DER -in "$tmp" -pubout -outform DER 2>/dev/null | xxd -p -c 256)
    rm -f "$tmp"
    ex="${ex:24}"
    [[ "$ex" == "$uh" ]] || return 1
    return 0
}

# -----------------------------------------------------------------------------
# Сверка UUID + запись в keys.env (вариант B)
# -----------------------------------------------------------------------------
declare -A UUID_EXPECTED
declare -A UUID_SOURCES

record_expected() {
    local key="$1" value="$2" source="$3"
    [[ -z "$value" ]] && return
    if [[ -z "${UUID_EXPECTED[$key]:-}" ]]; then
        UUID_EXPECTED[$key]="$value"
        UUID_SOURCES[$key]="$source"
    elif [[ "${UUID_EXPECTED[$key]}" != "$value" ]]; then
        fail "$key: расхождение между ${UUID_SOURCES[$key]} ($value) и $source (${UUID_EXPECTED[$key]})"
    fi
}

step "Сбор эталонных UUID из build/B, build/C, build/D"

# B: serverD.uuid -> UUID_DB
v=$(yaml_user_uuid "$CFG_B" "serverD")
if [[ -z "$v" ]]; then
    fail "build/B serverD: UUID не извлечён (парсер сломан или блок отсутствует)"
else
    record_expected "UUID_DB" "$v" "build/B serverD"
fi
# B: serverA.uuid -> UUID_BA
v=$(yaml_user_uuid "$CFG_B" "serverA")
if [[ -z "$v" ]]; then
    fail "build/B serverA: UUID не извлечён"
else
    record_expected "UUID_BA" "$v" "build/B serverA"
fi
# B: serverC.uuid -> UUID_BC
v=$(yaml_user_uuid "$CFG_B" "serverC")
if [[ -z "$v" ]]; then
    fail "build/B serverC: UUID не извлечён"
else
    record_expected "UUID_BC" "$v" "build/B serverC"
fi

# C: serverD.uuid -> UUID_DC
v=$(yaml_user_uuid "$CFG_C" "serverD")
if [[ -z "$v" ]]; then
    fail "build/C serverD: UUID не извлечён (парсер сломан или блок отсутствует)"
else
    record_expected "UUID_DC" "$v" "build/C serverD"
fi
# C: serverB.uuid -> UUID_BC (должен совпасть с B serverC)
v=$(yaml_user_uuid "$CFG_C" "serverB")
if [[ -z "$v" ]]; then
    fail "build/C serverB: UUID не извлечён"
else
    record_expected "UUID_BC" "$v" "build/C serverB"
fi

# D: to-serverC.uuid -> UUID_DC
v=$(yaml_proxy_field "$CFG_D" "to-serverC" "uuid")
if [[ -z "$v" ]]; then
    fail "build/D to-serverC: UUID не извлечён"
else
    record_expected "UUID_DC" "$v" "build/D to-serverC"
fi
# D: to-serverB.uuid -> UUID_DB
v=$(yaml_proxy_field "$CFG_D" "to-serverB" "uuid")
if [[ -z "$v" ]]; then
    fail "build/D to-serverB: UUID не извлечён"
else
    record_expected "UUID_DB" "$v" "build/D to-serverB"
fi

for required in UUID_DB UUID_DC UUID_BA UUID_BC; do
    if [[ -z "${UUID_EXPECTED[$required]:-}" ]]; then
        fail "$required: эталон не собран ни из одного build/* — сверка с keys.env невозможна"
    fi
done

if (( ERRORS == 0 )); then
    ok "все эталонные UUID согласованы между build/B, build/C, build/D"
fi

# -----------------------------------------------------------------------------
# Сверка с keys.env
# -----------------------------------------------------------------------------
step "Сверка keys.env с эталонными UUID"

FIX_KEYS=()
for key in "${!UUID_EXPECTED[@]}"; do
    want="${UUID_EXPECTED[$key]}"
    result="${want:0:2}...${want: -2}"
    have=$(env_file_value "$KEYS_ENV" "$key" || true)
    if [[ -z "$have" ]]; then
        fail "$key: отсутствует в keys.env (эталон: $result из ${UUID_SOURCES[$key]})"
        FIX_KEYS+=("$key=$want")
    elif [[ "$have" != "$want" ]]; then
        fail "$key: keys.env=$have, эталон=$want (${UUID_SOURCES[$key]})"
        FIX_KEYS+=("$key=$want")
    else
        ok "$key: keys.env == эталон ($result)"
    fi
done

# -----------------------------------------------------------------------------
# PORT_D vs tproxy-port в config_D
# -----------------------------------------------------------------------------
step "PORT_D vs tproxy-port в build/D/config.yaml"
PORT_D=$(env_file_value "$PARAMS_ENV" "PORT_D" || true)
TPROXY=$(yaml_get "$CFG_D" "tproxy-port")
if [[ -z "$PORT_D" ]]; then
    fail "PORT_D отсутствует в params.env (эталон по шаблону entrypoint.sh: 7893)"
    FIX_ENV_PORT=true
elif [[ "$PORT_D" != "7893" ]]; then
    fail "PORT_D=$PORT_D в params.env, но entrypoint.sh жёстко ставит tproxy to :7893 — нужно PORT_D=7893"
    FIX_ENV_PORT=true
else
    ok "PORT_D=7893 (совпадает с entrypoint.sh)"
fi
if [[ -n "$TPROXY" ]]; then
    if [[ "$TPROXY" == "$PORT_D" ]]; then
        ok "tproxy-port в config.yaml == PORT_D ($TPROXY)"
    else
        fail "tproxy-port в config.yaml=$TPROXY, PORT_D=$PORT_D — шаблон должен быть 'tproxy-port: {{ PORT_D }}'"
    fi
fi

# -----------------------------------------------------------------------------
# TUNNEL_* в params.env и в tunnel.service
# -----------------------------------------------------------------------------
step "TUNNEL_* в params.env и подстановка в build/D/tunnel.service"

TUNNEL_KEY_ENV=$(env_file_value "$PARAMS_ENV" "TUNNEL_KEY" || true)
TUNNEL_REMOTE_PORT_ENV=$(env_file_value "$PARAMS_ENV" "TUNNEL_REMOTE_PORT" || true)
TUNNEL_C_HOST_ENV=$(env_file_value "$PARAMS_ENV" "TUNNEL_C_HOST" || true)
TUNNEL_C_USER_ENV=$(env_file_value "$PARAMS_ENV" "TUNNEL_C_USER" || true)
TUNNEL_C_PORT_ENV=$(env_file_value "$PARAMS_ENV" "TUNNEL_C_PORT" || true)

FIX_ENV_TUNNEL=()
if [[ -z "$TUNNEL_KEY_ENV" ]]; then
    fail "TUNNEL_KEY отсутствует в params.env"
    FIX_ENV_TUNNEL+=("TUNNEL_KEY=/root/.ssh/id_ed25519_tunnel")
else
    ok "TUNNEL_KEY=$TUNNEL_KEY_ENV"
fi
if [[ -z "$TUNNEL_REMOTE_PORT_ENV" ]]; then
    fail "TUNNEL_REMOTE_PORT отсутствует в params.env"
    FIX_ENV_TUNNEL+=("TUNNEL_REMOTE_PORT=2222")
else
    ok "TUNNEL_REMOTE_PORT=$TUNNEL_REMOTE_PORT_ENV"
fi
if [[ -z "$TUNNEL_C_HOST_ENV" ]]; then
    warn "TUNNEL_C_HOST отсутствует в params.env (build_D подставит IP_C)"
else
    ok "TUNNEL_C_HOST=$TUNNEL_C_HOST_ENV"
fi
if [[ -z "$TUNNEL_C_USER_ENV" ]]; then
    warn "TUNNEL_C_USER отсутствует в params.env (build_D подставит root)"
else
    ok "TUNNEL_C_USER=$TUNNEL_C_USER_ENV"
fi
if [[ -z "$TUNNEL_C_PORT_ENV" ]]; then
    warn "TUNNEL_C_PORT отсутствует в params.env (build_D подставит 22)"
else
    ok "TUNNEL_C_PORT=$TUNNEL_C_PORT_ENV"
fi

if grep -q '{{' "$SVC_D_TUNNEL"; then
    fail "build/D/tunnel.service содержит {{ ... }} — templater.sh не подставил переменные"
    grep -n '{{' "$SVC_D_TUNNEL" | sed 's/^/    /'
else
    ok "build/D/tunnel.service без {{ }}"
fi

if grep -q '127.0.0.1:.*:localhost:22' "$SVC_D_TUNNEL"; then
    port_in_svc=$(grep -oE '127\.0\.0\.1:[0-9]+:localhost:22' "$SVC_D_TUNNEL" | head -1 | sed 's/127\.0\.0\.1:\([0-9]*\):localhost:22/\1/')
    ok "tunnel.service: -R 127.0.0.1:${port_in_svc}:localhost:22"
    if [[ -n "$TUNNEL_REMOTE_PORT_ENV" && "$port_in_svc" != "$TUNNEL_REMOTE_PORT_ENV" ]]; then
        fail "tunnel.service: порт $port_in_svc != TUNNEL_REMOTE_PORT=$TUNNEL_REMOTE_PORT_ENV"
    fi
else
    fail "tunnel.service не содержит -R 127.0.0.1:PORT:localhost:22"
fi

if grep -q -- '-i /' "$SVC_D_TUNNEL"; then
    key_in_svc=$(grep -oE -- '-i [^ ]+' "$SVC_D_TUNNEL" | head -1 | sed 's/^-i //')
    ok "tunnel.service: -i $key_in_svc"
    if [[ -n "$TUNNEL_KEY_ENV" && "$key_in_svc" != "$TUNNEL_KEY_ENV" ]]; then
        fail "tunnel.service: -i $key_in_svc != TUNNEL_KEY=$TUNNEL_KEY_ENV"
    fi
else
    fail "tunnel.service не содержит -i /путь/к/ключу"
fi

if grep -q '0\.0\.0\.0:[0-9]*' "$SVC_D_TUNNEL"; then
    fail "tunnel.service содержит 0.0.0.0:PORT — порт откроется наружу!"
else
    ok "tunnel.service без 0.0.0.0:PORT"
fi

# -----------------------------------------------------------------------------
# SERVERNAME/FINGERPRINT
# -----------------------------------------------------------------------------
step "SERVERNAME / FINGERPRINT в params.env"
SERVERNAME=$(env_file_value "$PARAMS_ENV" "SERVERNAME" || true)
FINGERPRINT=$(env_file_value "$PARAMS_ENV" "FINGERPRINT" || true)
[[ -n "$SERVERNAME" ]] && ok "SERVERNAME=$SERVERNAME" || fail "SERVERNAME не задан в params.env"
[[ -n "$FINGERPRINT" ]] && ok "FINGERPRINT=$FINGERPRINT" || fail "FINGERPRINT не задан в params.env"

# -----------------------------------------------------------------------------
# Парность X25519 в keys.env
# -----------------------------------------------------------------------------
step "Парность X25519 в keys.env (PRIVATE_KEY_* ↔ PUBLIC_KEY_*)"
if command -v openssl >/dev/null 2>&1 && command -v xxd >/dev/null 2>&1; then
    for srv in A B C D; do
        priv=$(env_file_value "$KEYS_ENV" "PRIVATE_KEY_$srv" || true)
        pub=$(env_file_value "$KEYS_ENV" "PUBLIC_KEY_$srv" || true)
        if [[ -z "$priv" || -z "$pub" ]]; then
            fail "$srv: нет PRIVATE_KEY_$srv или PUBLIC_KEY_$srv"
            continue
        fi
        if x25519_pair "$priv" "$pub"; then
            ok "$srv: PRIVATE_KEY ↔ PUBLIC_KEY — ПАРНЫЕ"
        else
            fail "$srv: PRIVATE_KEY ↔ PUBLIC_KEY — НЕ ПАРНЫЕ"
        fi
    done
else
    warn "нет openssl/xxd — парность X25519 не проверена"
fi

# =============================================================================
# УДАЛЁННАЯ ПРОВЕРКА СЕРВЕРОВ
# =============================================================================
# Для каждого сервера (A/B/C/D) через SSH (D — через ProxyCommand C) берём
# /opt/mihomo/config.yaml и сверяем:
#   - private-key  сервера == PRIVATE_KEY_<srv> из keys.env
#   - public-key   (в reality-opts) == PUBLIC_KEY_<srv> из keys.env
#   - short-id     (в reality-config) == SHORT_ID_<srv> из keys.env
#   - server-names[0] == SERVERNAME
#   - UUID пользователей (для B: serverA/serverC/serverD; для C: serverB/serverD/user*)
#   - Парность PRIVATE_KEY_<srv> (с сервера) ↔ PUBLIC_KEY_<srv> (keys.env)
#     — если на сервере старый приватный ключ, публичный не сойдётся.
#   - На C: ss -tln | grep PORT_C (mihomo слушает), отсутствие nft-блока PORT_C.
# Это ловит случай «на C развёрнута старая сборка с другими ключами»,
# когда локально всё синхронно, а D не проходит Reality.
# =============================================================================
if $NO_REMOTE; then
    step "Удалённая проверка пропущена (--no-remote)"
else
    step "Удалённая проверка серверов (ключи и UUID в /opt/mihomo/config.yaml)"

    SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
    REMOTE_USER="${REMOTE_USER:-root}"
    IP_A=$(env_file_value "$PARAMS_ENV" "IP_A" || true)
    IP_B=$(env_file_value "$PARAMS_ENV" "IP_B" || true)
    IP_C=$(env_file_value "$PARAMS_ENV" "IP_C" || true)
    IP_D=$(env_file_value "$PARAMS_ENV" "IP_D" || true)
    LOCAL_A=$(env_file_value "$PARAMS_ENV" "LOCAL_A" || true); LOCAL_A="${LOCAL_A:-1}"
    DIR_A=$(env_file_value "$PARAMS_ENV" "DIR_A" || true); DIR_A="${DIR_A:-/opt/mihomo}"
    DIR_B=$(env_file_value "$PARAMS_ENV" "DIR_B" || true); DIR_B="${DIR_B:-/opt/mihomo}"
    DIR_C=$(env_file_value "$PARAMS_ENV" "DIR_C" || true); DIR_C="${DIR_C:-/opt/mihomo}"
    DIR_D=$(env_file_value "$PARAMS_ENV" "DIR_D" || true); DIR_D="${DIR_D:-/opt/mihomo}"
    PORT_C=$(env_file_value "$PARAMS_ENV" "PORT_C" || true)
    USERS_C=$(env_file_value "$PARAMS_ENV" "USERS_C" || true)
    USERS_A=$(env_file_value "$PARAMS_ENV" "USERS_A" || true)
    TUNNEL_C_HOST="${TUNNEL_C_HOST_ENV:-$IP_C}"
    TUNNEL_C_USER="${TUNNEL_C_USER_ENV:-root}"
    TUNNEL_C_PORT="${TUNNEL_C_PORT_ENV:-22}"
    TUNNEL_REMOTE_PORT="${TUNNEL_REMOTE_PORT_ENV:-2222}"

    ssh_target() { local h="$1"; [[ "$h" == *@* ]] && printf '%s' "$h" || printf '%s@%s' "$REMOTE_USER" "$h"; }

    # public-key в reality-opts — это ключ АПСТРИМА, а не свой.
    # На B: to-serverC.reality-opts.public-key == PUBLIC_KEY_C
    # На C: to-serverB.reality-opts.public-key == PUBLIC_KEY_B
    # На D: to-serverC.reality-opts.public-key == PUBLIC_KEY_C,
    #       to-serverB.reality-opts.public-key == PUBLIC_KEY_B
    check_reality_opts_public_keys() {
        local srv="$1" cfg="$2"
        local proxy_name expected_upstream expected_pub got
        case "$srv" in
            B)
                proxy_name="to-serverC"; expected_upstream="PUBLIC_KEY_C" ;;
            C)
                proxy_name="to-serverB"; expected_upstream="PUBLIC_KEY_B" ;;
            D)
                # у D два прокси — проверяем оба
                for pair in "to-serverC:PUBLIC_KEY_C" "to-serverB:PUBLIC_KEY_B"; do
                    proxy_name="${pair%%:*}"; expected_upstream="${pair##*:}"
                    expected_pub=$(env_file_value "$KEYS_ENV" "$expected_upstream" || true)
                    got=$(yaml_proxy_field "$cfg" "$proxy_name" "public-key")
                    if [[ -z "$expected_pub" ]]; then
                        fail "$srv: $expected_upstream отсутствует в keys.env"
                    elif [[ "$got" == "$expected_pub" ]]; then
                        ok "$srv: $proxy_name.reality-opts.public-key == $expected_upstream"
                    else
                        fail "$srv: $proxy_name.reality-opts.public-key != $expected_upstream"
                    fi
                done
                return ;;
            A)
                # у A один прокси to-serverB -> PUBLIC_KEY_B
                proxy_name="to-serverB"; expected_upstream="PUBLIC_KEY_B" ;;
        esac
        expected_pub=$(env_file_value "$KEYS_ENV" "$expected_upstream" || true)
        got=$(yaml_proxy_field "$cfg" "$proxy_name" "public-key")
        if [[ -z "$expected_pub" ]]; then
            fail "$srv: $expected_upstream отсутствует в keys.env"
        elif [[ "$got" == "$expected_pub" ]]; then
            ok "$srv: $proxy_name.reality-opts.public-key == $expected_upstream"
        else
            fail "$srv: $proxy_name.reality-opts.public-key != $expected_upstream"
        fi
    }
    
    # check_remote_keys <srv> <host> <dir> <via>  (via = "" | "proxy")
    #   $1 — имя (A/B/C/D)
    #   $2 — host (для D при via=proxy — "localhost")
    #   $3 — каталог (/opt/mihomo)
    #   $4 — "" (прямой SSH) | "proxy" (через C)
    check_remote_keys() {
        local srv="$1" host="$2" dir="$3" via="${4:-}"
        local target tmp_cfg
        local -a ssh_cmd
        local expected_priv expected_pub expected_sid

        expected_priv=$(env_file_value "$KEYS_ENV" "PRIVATE_KEY_$srv" || true)
        expected_pub=$(env_file_value "$KEYS_ENV"  "PUBLIC_KEY_$srv"  || true)
        expected_sid=$(env_file_value "$KEYS_ENV"  "SHORT_ID_$srv"    || true)

        if [[ "$via" == "proxy" ]]; then
            local proxy="ssh -p $TUNNEL_C_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new $TUNNEL_C_USER@$TUNNEL_C_HOST -W %h:%p"
            ssh_cmd=("${SSH[@]}" -o "ProxyCommand=$proxy" -p "$TUNNEL_REMOTE_PORT")
            target="${JUMP_D_USER:-root}@localhost"
        else
            ssh_cmd=("${SSH[@]}")
            target=$(ssh_target "$host")
        fi

        if ! "${ssh_cmd[@]}" "$target" "true" 2>/dev/null; then
            warn "$srv ($target): SSH недоступен — удалённая проверка ключей пропущена"
            return
        fi

        tmp_cfg=$(mktemp)
        if ! "${ssh_cmd[@]}" "$target" "cat '$dir/config.yaml'" > "$tmp_cfg" 2>/dev/null; then
            fail "$srv: не удалось прочитать $dir/config.yaml"
            rm -f "$tmp_cfg"
            return
        fi

        # D — только клиент: listeners/reality-config у него нет, проверяем одни апстримы
        if [[ "$srv" == "D" ]]; then
            local pair p ukey skey got want
            check_reality_opts_public_keys D "$tmp_cfg"
            for pair in "to-serverC:UUID_DC:SHORT_ID_C" "to-serverB:UUID_DB:SHORT_ID_B"; do
                IFS=: read -r p ukey skey <<< "$pair"
                got=$(yaml_proxy_field "$tmp_cfg" "$p" "uuid")
                want=$(read_env_key "$KEYS_ENV" "$ukey" || true)
                [[ -n "$want" && "$got" == "$want" ]] && ok "D: $p.uuid == $ukey" || fail "D: $p.uuid != $ukey"
                got=$(yaml_proxy_field "$tmp_cfg" "$p" "short-id")
                want=$(read_env_key "$KEYS_ENV" "$skey" || true)
                [[ -n "$want" && "$got" == "$want" ]] && ok "D: $p.short-id == $skey" || fail "D: $p.short-id != $skey"
            done
            rm -f "$tmp_cfg"
            return
        fi
        # private-key
        local r_priv r_pub r_sid r_snames
        r_priv=$(yaml_get "$tmp_cfg" "private-key")
        if [[ -z "$expected_priv" ]]; then
            fail "$srv: PRIVATE_KEY_$srv отсутствует в keys.env"
        elif [[ "$r_priv" != "$expected_priv" ]]; then
            fail "$srv: private-key на сервере != PRIVATE_KEY_$srv (старая сборка на сервере?)"
        else
            ok "$srv: private-key на сервере == PRIVATE_KEY_$srv"
        fi

        check_reality_opts_public_keys "$srv" "$tmp_cfg"

        # short-id (в reality-config)
        r_sid=$(yaml_short_id_listener "$tmp_cfg")
        if [[ -z "$expected_sid" ]]; then
            fail "$srv: SHORT_ID_$srv отсутствует в keys.env"
        elif [[ "$r_sid" != "$expected_sid" ]]; then
            fail "$srv: short-id на сервере != SHORT_ID_$srv"
        else
            ok "$srv: short-id на сервере == SHORT_ID_$srv"
        fi

        # server-names[0]
        r_snames=$(yaml_server_names "$tmp_cfg")
        if [[ "$r_snames" != "$SERVERNAME" ]]; then
            fail "$srv: server-names[0] ($r_snames) != SERVERNAME ($SERVERNAME)"
        else
            ok "$srv: server-names[0] == SERVERNAME"
        fi

        # UUID пользователей — по серверу
        case "$srv" in
            B)
                for u in serverA:UUID_BA serverC:UUID_BC serverD:UUID_DB; do
                    local uname="${u%%:*}" ukey="${u##*:}"
                    local got=$(yaml_user_uuid "$tmp_cfg" "$uname")
                    local want=$(env_file_value "$KEYS_ENV" "$ukey" || true)
                    if [[ -n "$want" && "$got" == "$want" ]]; then
                        ok "B: $uname.uuid == $ukey"
                    else
                        fail "B: $uname.uuid ($got) != $ukey ($want)"
                    fi
                done
                ;;
            C)
                for u in serverB:UUID_BC serverD:UUID_DC; do
                    local uname="${u%%:*}" ukey="${u##*:}"
                    local got=$(yaml_user_uuid "$tmp_cfg" "$uname")
                    local want=$(env_file_value "$KEYS_ENV" "$ukey" || true)
                    if [[ -n "$want" && "$got" == "$want" ]]; then
                        ok "C: $uname.uuid == $ukey"
                    else
                        fail "C: $uname.uuid ($got) != $ukey ($want)"
                    fi
                done
                for u in $USERS_C; do
                    local got=$(yaml_user_uuid "$tmp_cfg" "$u")
                    local want=$(env_file_value "$KEYS_ENV" "UUID_C_$u" || true)
                    if [[ -n "$want" && "$got" == "$want" ]]; then
                        ok "C: user '$u'.uuid == UUID_C_$u"
                    else
                        fail "C: user '$u'.uuid ($got) != UUID_C_$u ($want)"
                    fi
                done
                ;;
            A)
                for u in $USERS_A; do
                    local got=$(yaml_user_uuid "$tmp_cfg" "$u")
                    local want=$(env_file_value "$KEYS_ENV" "UUID_A_$u" || true)
                    if [[ -n "$want" && "$got" == "$want" ]]; then
                        ok "A: user '$u'.uuid == UUID_A_$u"
                    else
                        fail "A: user '$u'.uuid ($got) != UUID_A_$u ($want)"
                    fi
                done
                ;;
        esac

        # Парность PRIVATE_KEY_<srv> (с сервера) ↔ PUBLIC_KEY_<srv> (keys.env)
        # Это ловит случай «на сервере старый приватный ключ, публичный в keys.env
        # не сходится» — именно тогда D не проходит Reality, хотя UUID совпадают.
        if [[ -n "$r_priv" && -n "$expected_pub" ]]; then
            if x25519_pair "$r_priv" "$expected_pub"; then
                ok "$srv: PRIVATE_KEY (с сервера) ↔ PUBLIC_KEY_$srv (keys.env) — ПАРНЫЕ"
            else
                fail "$srv: PRIVATE_KEY (с сервера) ↔ PUBLIC_KEY_$srv (keys.env) — НЕ ПАРНЫЕ (на сервере старая сборка!)"
            fi
        fi

        rm -f "$tmp_cfg"
    }

    # --- A ---
    if [[ "$LOCAL_A" == "1" ]]; then
        info "A: LOCAL_A=1 — удалённая проверка ключей пропущена"
    elif [[ -n "$IP_A" ]]; then
        check_remote_keys "A" "$IP_A" "$DIR_A" ""
    fi

    # --- B ---
    [[ -n "$IP_B" ]] && check_remote_keys "B" "$IP_B" "$DIR_B" ""

    # --- C ---
    [[ -n "$IP_C" ]] && check_remote_keys "C" "$IP_C" "$DIR_C" ""

    # --- D (через ProxyCommand C) ---
    if [[ -n "$IP_D" && -n "$IP_C" ]]; then
        check_remote_keys "D" "localhost" "$DIR_D" "proxy"
    else
        warn "D: IP_D или IP_C не заданы — удалённая проверка ключей D пропущена"
    fi

    # =========================================================================
    # §11. На C: ss -tln | grep PORT_C (mihomo слушает), nft не блокирует PORT_C
    # =========================================================================
    if [[ -n "$IP_C" && -n "$PORT_C" ]]; then
        step "C: порт PORT_C и nft"
        target_C=$(ssh_target "$IP_C")
        if "${SSH[@]}" "$target_C" "ss -tln 2>/dev/null | grep -qE ':${PORT_C} '" 2>/dev/null; then
            ok "C: TCP :$PORT_C слушает"
        else
            fail "C: TCP :$PORT_C НЕ слушает (mihomo не поднял listener)"
        fi
        # nft может отсутствовать — тогда iptables-nft управляет nat, это не ошибка
        if "${SSH[@]}" "$target_C" "command -v nft >/dev/null 2>&1"; then
            if "${SSH[@]}" "$target_C" "nft list ruleset 2>/dev/null | grep -E 'dport ${PORT_C} .*(drop|reject)'" 2>/dev/null | grep -q .; then
                fail "C: nft блокирует :$PORT_C (drop/reject)"
            else
                ok "C: nft не блокирует :$PORT_C"
            fi
        else
            info "C: nft не установлен — проверка nft пропущена (iptables-nft управляет nat)"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# --fix: записать эталонные UUID в keys.env (вариант B)
# -----------------------------------------------------------------------------
if $MODE_FIX_KEYS; then
    step "Восстановление keys.env из build/* (вариант B)"
    if (( ${#FIX_KEYS[@]} == 0 )); then
        ok "нечего исправлять — keys.env уже синхронен"
    else
        backup="$KEYS_ENV.$(date +%Y%m%d-%H%M%S).bak"
        cp -a "$KEYS_ENV" "$backup"
        ok "бэкап: $backup"

        for kv in "${FIX_KEYS[@]}"; do
            key="${kv%%=*}"
            val="${kv#*=}"
            if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$KEYS_ENV"; then
                tmp=$(mktemp)
                awk -v key="$key" -v val="$val" '
                    BEGIN { done=0 }
                    $0 ~ "^[[:space:]]*(export[[:space:]]+)?"key"[[:space:]]*=" && !done {
                        print key "=" val
                        done=1
                        next
                    }
                    { print }
                ' "$KEYS_ENV" > "$tmp" && mv -f "$tmp" "$KEYS_ENV"
            else
                printf '%s=%s\n' "$key" "$val" >> "$KEYS_ENV"
            fi
            ok "keys.env: $key=$val"
        done
        ok "keys.env восстановлен из build/*"
        info "Теперь пересоберите D и задеплойте B/C:"
        info "  scripts/build-servers.sh B --build --deploy"
        info "  scripts/build-servers.sh C --build --deploy"
        info "  scripts/build-servers.sh D --build --publish"
    fi
fi

# -----------------------------------------------------------------------------
# --fix-env: записать PORT_D/TUNNEL_* в params.env
# -----------------------------------------------------------------------------
if $MODE_FIX_ENV; then
    step "Восстановление params.env (PORT_D, TUNNEL_*)"
    ENV_FIX=()
    [[ "${FIX_ENV_PORT:-false}" == true ]] && ENV_FIX+=("PORT_D=7893")
    for kv in "${FIX_ENV_TUNNEL[@]}"; do
        ENV_FIX+=("$kv")
    done
    if (( ${#ENV_FIX[@]} == 0 )); then
        ok "нечего исправлять — params.env уже синхронен"
    else
        backup="$PARAMS_ENV.$(date +%Y%m%d-%H%M%S).bak"
        cp -a "$PARAMS_ENV" "$backup"
        ok "бэкап: $backup"
        for kv in "${ENV_FIX[@]}"; do
            key="${kv%%=*}"
            val="${kv#*=}"
            if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$PARAMS_ENV"; then
                tmp=$(mktemp)
                awk -v key="$key" -v val="$val" '
                    BEGIN { done=0 }
                    $0 ~ "^[[:space:]]*(export[[:space:]]+)?"key"[[:space:]]*=" && !done {
                        print key "=" val
                        done=1
                        next
                    }
                    { print }
                ' "$PARAMS_ENV" > "$tmp" && mv -f "$tmp" "$PARAMS_ENV"
            else
                printf '%s=%s\n' "$key" "$val" >> "$PARAMS_ENV"
            fi
            ok "params.env: $key=$val"
        done
        ok "params.env восстановлен"
    fi
fi

# -----------------------------------------------------------------------------
# Итог
# -----------------------------------------------------------------------------
step "Итоги"
printf '\n  Успешных проверок: %s%d%s\n' "$C_GREEN" "$OK_COUNT" "$C_RESET"
err_color="$C_GREEN"; (( ERRORS > 0 )) && err_color="$C_RED"
warn_color="$C_GREEN"; (( WARNINGS > 0 )) && warn_color="$C_YELLOW"
printf '  Ошибок: %s%d%s\n' "$err_color" "$ERRORS" "$C_RESET"
printf '  Предупреждений: %s%d%s\n' "$warn_color" "$WARNINGS" "$C_RESET"

if (( ERRORS > 0 )); then
    if $MODE_CHECK; then
        printf '\n%s  ✗ Есть рассинхрон. Запустите для починки:%s\n' "$C_RED" "$C_RESET" >&2
        info "  scripts/check-keys-sync.sh --fix      # восстановить keys.env из build/*"
        info "  scripts/check-keys-sync.sh --fix-env  # восстановить PORT_D/TUNNEL_* в params.env"
        info "  Если ошибка в удалённых private-key/public-key/short-id/UUID:"
        info "    scripts/build-servers.sh B --build --deploy"
        info "    scripts/build-servers.sh C --build --deploy"
        info "    scripts/build-servers.sh D --build --publish"
    fi
    exit 1
fi
printf '\n%s  ✓ Всё синхронно (локально + удалённо)%s\n' "$C_GREEN" "$C_RESET"
exit 0