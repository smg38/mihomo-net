#!/bin/bash
# =============================================================================
# scripts/probe-reality.sh — сквозная проверка Reality-аутентификации
# Версия: 3.2.0   2026-11-5
# Автор: @smg38
#
# Поднимает локальный клиент mihomo с ключами из build/keys и пробует
# подключиться к серверу C (как пользователь) или B (как сервер A),
# перебирая client-fingerprint.
#
# Использование (на машине A):
#   scripts/probe-reality.sh [C|B] [user] [fp ...]
#   scripts/probe-reality.sh C user1
#   scripts/probe-reality.sh B
#   scripts/probe-reality.sh C user1 chrome firefox
#
# Как читать результат:
#   все FAIL            -> проблема на сервере: версия ядра, часы, dest
#   работают не все fp  -> поменяйте fp в шаблонах user.* и config_*.j3
#   все OK              -> сервер исправен, смотрите клиентское приложение
#                          и то, что реально лежит в выданной ссылке/подписке
# =============================================================================
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

source deploy/lib/env.sh
load_env_file build/keys/params.env || { echo "нет params.env"; exit 1; }
load_env_file build/keys/keys.env   || { echo "нет keys.env"; exit 1; }

BIN="${MIHOMO_BIN:-.tmp/mihomo}"
[[ -x "$BIN" ]] || { echo "нет бинаря $BIN (./build-local.sh build)"; exit 1; }

target="${1:-C}"
user="${2:-user1}"
fps=("${@:3}")
[[ ${#fps[@]} -gt 0 ]] || fps=(chrome firefox safari ios android edge random)

case "$target" in
    C) ip="$IP_C"; port="$PORT_C"; uuid_var="UUID_C_${user}"
       pbk="$PUBLIC_KEY_C"; sid="$SHORT_ID_C"; flow="${FLOW_USERS:-xtls-rprx-vision}" ;;
    B) ip="$IP_B"; port="$PORT_B"; uuid_var="UUID_BA"
       pbk="$PUBLIC_KEY_B"; sid="$SHORT_ID_B"; flow="${FLOW_AB:-xtls-rprx-vision}" ;;
    *) echo "цель: C или B"; exit 1 ;;
esac
uuid="${!uuid_var:-}"
[[ -n "$uuid" ]] || { echo "нет $uuid_var в keys.env"; exit 1; }

echo "Цель: $target ($ip:$port), uuid=$uuid_var, flow=$flow, SNI=$SERVERNAME"
echo "Ядро клиента: $("$BIN" -v 2>&1 | head -1)"
echo

okcount=0
for fp in "${fps[@]}"; do
    d=$(mktemp -d)
    cat > "$d/c.yaml" <<EOF
mixed-port: 17890
bind-address: 127.0.0.1
allow-lan: false
mode: rule
log-level: debug
ipv6: false
proxies:
  - name: probe
    type: vless
    server: $ip
    port: $port
    uuid: "$uuid"
    flow: $flow
    network: tcp
    tls: true
    udp: false
    servername: $SERVERNAME
    client-fingerprint: $fp
    reality-opts:
      public-key: "$pbk"
      short-id: "$sid"
rules:
  - MATCH,probe
EOF
    "$BIN" -d "$d" -f "$d/c.yaml" >"$d/log_$fp" 2>&1 &
    pid=$!
    sleep 1
    code=$(curl --noproxy '*' -x http://127.0.0.1:17890 -s -o /dev/null -m 12 \
           -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)
    remote_ip=$(curl --noproxy '*' -x http://127.0.0.1:17890 -s -m 12 https://ifconfig.me 2>/dev/null)    
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    if [[ "$code" == "204" ]]; then
        printf '  \033[0;32m✓ OK  \033[0m fp=%s remote ip=%s\n' "$fp" "${remote_ip:-unknown}"
        okcount=$((okcount+1))
    else
        printf '  \033[0;31m✗ FAIL\033[0m fp=%s (http=%s)\n' "$fp" "${code:-000}"
        grep -iE 'error|fail|reality|tls|handshake' "$d/log_$fp" | tail -3 | sed 's/^/        /'
    fi
    #rm -rf "$d"
    echo "Журнал теста сохранён: $d/log_*"
done

echo
echo "Успешных fingerprint: $okcount из ${#fps[@]}"
