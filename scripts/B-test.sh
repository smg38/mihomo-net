#!/bin/bash
# =============================================================================
# B-test.sh — самопроверка сервера B (запускать НА B).
# Проверяет: порты, mihomo active, TLS/Reality, TCP до C, GEO, health-check.
# В случае ошибок выводит красным, в случае предупреждений — жёлтым.
# Версия: 3.2.0 2026-11-05
# =============================================================================
set -uo pipefail
PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[0;31m✗\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
warn() { printf '  \033[0;33m⚠\033[0m %s\n' "$*" >&2; WARN=$((WARN+1)); }
hdr()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

DIR_B="${DIR_B:-/opt/mihomo}"
CONFIG="$DIR_B/config.yaml"
[[ -f "$CONFIG" ]] || { echo "Нет $CONFIG"; exit 1; }
if command -v yq >/dev/null 2>&1; then
  SERVERNAME=$(yq -r '.listeners[] | select(.name=="vless-in") | .reality-config.server-names[0] // empty' "$CONFIG" 2>/dev/null)
  SECRET=$(yq -r '.secret // empty' "$CONFIG" 2>/dev/null)
  PORT_B=$(yq -r '.listeners[] | select(.name=="vless-in") | .port // empty' "$CONFIG" 2>/dev/null)
else
  PORT_B=$(awk '/^  - name: vless-in/{f=1;next} f && /^    port:/{print $2; exit}' "$CONFIG")
  SERVERNAME=$(awk '/^      server-names:/{getline; gsub(/[ \t-]/,""); print; exit}' "$CONFIG")
  SECRET=$(awk -F'"' '/^secret:/{print $2; exit}' "$CONFIG")
fi
[[ -n "$PORT_B" ]]    || { echo "B-test: не извлечён PORT_B"; exit 1; }
[[ -n "$SERVERNAME" ]] || { echo "B-test: не извлечён SERVERNAME"; exit 1; }

# --- 1. mihomo active ---
hdr "1. mihomo.service"
systemctl is-active --quiet mihomo.service && ok "mihomo.service active" || bad "mihomo.service не активен"

# --- 2. Порты ---
hdr "2. Порты"
ss -tln | grep -q ":${PORT_B} " && ok "tcp :$PORT_B LISTEN" || bad "tcp :$PORT_B не слушает"
ss -tln | grep -q ':9900 '      && ok "tcp :9900 (API)"    || bad "tcp :9900 не слушает"

# --- 3. Фаервол ---
hdr "3. Фаервол"
nft list ruleset 2>/dev/null | grep -iE "dport ${PORT_B} .*(drop|reject)" >/dev/null && bad "nft: :$PORT_B drop/reject" || ok "nft: :$PORT_B не блокирован"

# --- 4. TLS/Reality на :PORT_B ---
hdr "4. TLS/Reality на :$PORT_B"
tls_out=$(timeout 10 openssl s_client -connect "127.0.0.1:${PORT_B}" -servername "$SERVERNAME" </dev/null 2>&1 || true)
printf '%s' "$tls_out" | grep -q 'CONNECTED' && ok "openssl CONNECTED на 127.0.0.1:$PORT_B" || bad "openssl НЕ CONNECTED на 127.0.0.1:$PORT_B"

# --- 5. Связь с апстримом (через API) ---
hdr "5. Связь с апстримом (to-serverC)"
api=$(curl -sS -m 5 -H "Authorization: Bearer ${SECRET}" http://127.0.0.1:9900/proxies 2>/dev/null)
if [[ -z "$api" ]]; then
  bad "API :9900 не отвечает"
else
  alive=$(printf '%s' "$api" | grep -o '"to-serverC":{[^}]*}' | grep -o '"alive":[^,]*' | cut -d: -f2)
  if [[ "$alive" == "true" ]]; then
    ok "to-serverC alive (health-check)"
  else
    warn "to-serverC alive=false (health-check; проверьте логи B)"
  fi
fi

# --- 6. Геофильтрация ---
hdr "6. Геофильтрация (по правилам)"
grep -q 'MATCH,DIRECT' "$CONFIG" && ok "config: MATCH,DIRECT" || bad "config: нет MATCH,DIRECT"

# --- 7. Апстримы через API ---
hdr "7. Статус апстримов (API :9900)"
api=$(curl -sS -m 5 -H "Authorization: Bearer ${SECRET}" http://127.0.0.1:9900/proxies 2>/dev/null)
if [[ -z "$api" ]]; then
  bad "API :9900 не отвечает"
else
  for p in $(printf '%s' "$api" | grep -oE '"to-server[A-Za-z]+"' | tr -d '"' | sort -u); do
    alive=$(printf '%s' "$api" | grep -o "\"$p\":{[^}]*}" | grep -o '"alive":[^,]*' | cut -d: -f2)
    [[ "$alive" == "true" ]] && ok "$p alive" || warn "$p alive=false"
  done
fi

# --- 8. Проверка исходящего ---
hdr "8. Проверка исходящего через B (mixed-port)"
c=$(curl --noproxy '*' -x socks5h://127.0.0.1:7890 -sS --max-time 10 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)
[[ "$c" == "204" ]] && ok "gstatic via socks5: 204" || bad "gstatic via socks5: $c"

# --- Итог ---
printf '\n\033[1mИтог:\033[0m %s✓%d%s  %s✗%d%s  %s⚠%d%s\n' \
  $'\033[0;32m' "$PASS" $'\033[0m' \
  $'\033[0;31m' "$FAIL" $'\033[0m' \
  $'\033[0;33m' "$WARN" $'\033[0m'
(( FAIL > 0 )) && exit 1
exit 0