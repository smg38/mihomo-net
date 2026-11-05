#!/bin/bash
# =============================================================================
# C-test.sh — самопроверка сервера C (запускать НА C).
# Проверяет: порты, mihomo active, TLS к SERVERNAME, nginx-выдачу, TLS/Reality,
# TCP до B, GEO-правила, health-check апстримов.
# Версия: 3.2.0
# Дата:   2026-11-05
# Автор:  @smg38
# =============================================================================
set -uo pipefail
PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[0;31m✗\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
warn() { printf '  \033[0;33m⚠\033[0m %s\n' "$*" >&2; WARN=$((WARN+1)); }
hdr()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

DIR_C="${DIR_C:-/opt/mihomo}"
CONFIG="$DIR_C/config.yaml"
[[ -f "$CONFIG" ]] || { echo "Нет $CONFIG"; exit 1; }
if command -v yq >/dev/null 2>&1; then
  SERVERNAME=$(yq -r '.listeners[] | select(.name=="vless-in") | .reality-config.server-names[0] // empty' "$CONFIG" 2>/dev/null)
  SECRET=$(yq -r '.secret // empty' "$CONFIG" 2>/dev/null)
  PORT_C=$(yq -r '.listeners[] | select(.name=="vless-in") | .port // empty' "$CONFIG" 2>/dev/null)
else
  # Fallback: awk для .port у vless-in
  PORT_C=$(awk '/^  - name: vless-in/{f=1;next} f && /^    port:/{print $2; exit}' "$CONFIG")
  SERVERNAME=$(awk '/^      server-names:/{getline; gsub(/[ \t-]/,""); print; exit}' "$CONFIG")
  SECRET=$(awk -F'"' '/^secret:/{print $2; exit}' "$CONFIG")
fi
[[ -n "$PORT_C" ]]   || { echo "C-test: не извлечён PORT_C"; exit 1; }
[[ -n "$SERVERNAME" ]] || { echo "C-test: не извлечён SERVERNAME"; exit 1; }

# --- 1. mihomo active ---
hdr "1. mihomo.service"
systemctl is-active --quiet mihomo.service && ok "mihomo.service active" || bad "mihomo.service не активен"

# --- 2. Порты mihomo ---
hdr "2. Порты"
ss -tln | grep -q ":${PORT_C} " && ok "tcp :$PORT_C LISTEN" || bad "tcp :$PORT_C не слушает"
ss -tln | grep -q ':9900 ' && ok "tcp :9900 (API)" || bad "tcp :9900 не слушает"

# --- 3. nft / iptables не блокируют C ---
hdr "3. Фаервол"
nft list ruleset 2>/dev/null | grep -iE "dport ${PORT_C} .*(drop|reject)" >/dev/null && bad "nft: :$PORT_C drop/reject" || ok "nft: :$PORT_C не блокирован"

# --- 4. TLS/Reality на :PORT_C ---
hdr "4. TLS/Reality на :$PORT_C"
tls_out=$(timeout 10 openssl s_client -connect "127.0.0.1:${PORT_C}" -servername "$SERVERNAME" </dev/null 2>&1 || true)
if printf '%s' "$tls_out" | grep -q 'CONNECTED'; then
  ok "openssl CONNECTED на 127.0.0.1:$PORT_C"
else
  bad "openssl НЕ CONNECTED на 127.0.0.1:$PORT_C"
fi

# --- 5. nginx и выдача ---
hdr "5. nginx и выдача подписок"
systemctl is-active --quiet nginx && ok "nginx active" || bad "nginx не активен"
ss -tln | grep -q ':80 ' && ok "tcp :80 (nginx)" || bad "tcp :80 не слушает"
if ! command -v nginx >/dev/null 2>&1; then
  bad "nginx не найден в PATH"
elif nginx -t 2>&1 | grep -q 'syntax is ok'; then #echo 'nginx -t (syntax is ok)'; fi
  ok "nginx -t (syntax is ok)"
else
  nginx -t 2>&1 | tail -5 | sed 's/^/    /' >&2
  bad "nginx -t провален"
fi
#elif nginx -t 2>&1 | grep -q 'syntax is ok'; then

# --- 6. Связь с апстримом (через API) ---
hdr "6. Связь с апстримом (to-serverB)"
api=$(curl -sS -m 5 -H "Authorization: Bearer ${SECRET}" http://127.0.0.1:9900/proxies 2>/dev/null)
if [[ -z "$api" ]]; then
  bad "API :9900 не отвечает"
else
  alive=$(printf '%s' "$api" | grep -o '"to-serverB":{[^}]*}' | grep -o '"alive":[^,]*' | cut -d: -f2)
  if [[ "$alive" == "true" ]]; then
    ok "to-serverB alive (health-check)"
  else
    warn "to-serverB alive=false (health-check; проверьте логи C)"
  fi
fi

# --- 7. Геофильтрация ---
hdr "7. Геофильтрация (по правилам)"
grep -q 'GEOSITE,category-ru,DIRECT' "$CONFIG" && ok "config: GEOSITE,category-ru,DIRECT" || bad "config: нет GEOSITE,category-ru,DIRECT"
grep -q 'MATCH,PROXY'                "$CONFIG" && ok "config: MATCH,PROXY"                || bad "config: нет MATCH,PROXY"

# --- 8. Апстримы через API ---
hdr "8. Статус апстримов (API :9900)"
api=$(curl -sS -m 5 -H "Authorization: Bearer ${SECRET}" http://127.0.0.1:9900/proxies 2>/dev/null)
if [[ -z "$api" ]]; then
  bad "API :9900 не отвечает"
else
  for p in $(printf '%s' "$api" | grep -oE '"to-server[A-Za-z]+"' | tr -d '"' | sort -u); do
    alive=$(printf '%s' "$api" | grep -o "\"$p\":{[^}]*}" | grep -o '"alive":[^,]*' | cut -d: -f2)
    [[ "$alive" == "true" ]] && ok "$p alive" || warn "$p alive=false"
  done
fi

# --- 9. HEALTH-CHECK LITERAL (curl через mixed-port на C) ---
hdr "9. Проверка исходящего через C (mixed-port)"
c=$(curl --noproxy '*' -x socks5h://127.0.0.1:7890 -sS --max-time 10 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)
[[ "$c" == "204" ]] && ok "gstatic via socks5: 204" || bad "gstatic via socks5: $c"

# --- Итог ---
printf '\n\033[1mИтог:\033[0m %s✓%d%s  %s✗%d%s  %s⚠%d%s\n' \
  $'\033[0;32m' "$PASS" $'\033[0m' \
  $'\033[0;31m' "$FAIL" $'\033[0m' \
  $'\033[0;33m' "$WARN" $'\033[0m'
(( FAIL > 0 )) && exit 1
exit 0  