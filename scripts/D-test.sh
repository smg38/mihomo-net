#!/bin/bash
# =============================================================================
# D-test.sh — самопроверка сервера D (запускать НА D).
# Версия: 3.2.0   2026-11-5
# Автор: @smg38
# Проверяет: порты, nftables/routing, DNS, связь с C/B, direct, socks5-через-D,
# Reality-апстримы, TProxy-перехват LAN-трафика, геофильтрацию, health-check.
# Возвращает 0 при успехе, 1 при провале.
# =============================================================================
set -uo pipefail

PASS=0
FAIL=0
WARN=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[0;31m✗\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
warn() { printf '  \033[0;33m⚠\033[0m %s\n' "$*" >&2; WARN=$((WARN+1)); }
info() { printf '  · %s\n' "$*"; }
hdr()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

DIR_D="${DIR_D:-/opt/mihomo}"
CONFIG="$DIR_D/config.yaml"
[[ -f "$CONFIG" ]] || { echo "Нет $CONFIG"; exit 1; }

if [[ -f "$DIR_D/D-config" ]]; then
  # shellcheck disable=SC1091
  source "$DIR_D/D-config"
fi
SECRET=$(awk -F'"' '/^secret:/{print $2; exit}' "$CONFIG")
API_AUTH=""
[[ -n "$SECRET" ]] && API_AUTH="Authorization: Bearer $SECRET"

# --- 1. Порты ---
hdr "1. Порты mihomo"
for spec in "tcp:7890" "tcp:7893" "tcp:1053" "udp:7890" "udp:7893" "udp:1053"; do
  proto="${spec%%:*}"; port="${spec##*:}"
  if [[ "$proto" == "tcp" ]]; then
    ss -tln | grep -q ":${port} " && ok "$proto :$port LISTEN" || bad "$proto :$port не слушает"
  else
    ss -uln | grep -q ":${port} " && ok "$proto :$port UNCONN" || bad "$proto :$port не слушает"
  fi
done

# --- 2. nftables / routing ---
hdr "2. nftables / routing"
if nft list table clash >/dev/null 2>&1; then
  ok "nft table clash"
else
  bad "nft table clash отсутствует"
fi

check_nft_chain() {
  local label="$1" chain="$2" pattern="$3"
  if nft list chain clash "$chain" 2>/dev/null | grep -qF "$pattern"; then
    ok "nft $chain: $label"
  else
    bad "nft $chain: $label отсутствует"
  fi
}
check_nft_chain "tproxy to :7893"    PREROUTING     'tproxy to :7893'
check_nft_chain "fwmark 1"           PREROUTING     'mark set 0x00000001'
check_nft_chain "dns redirect :1053" PREROUTING_DNS 'redirect to :1053'

n=$(ip rule show | grep -cE '^[0-9]+:[[:space:]]+from all fwmark 0x1 lookup 100$')
(( n == 1 )) && ok "ip rule fwmark 0x1 lookup 100 (ровно одна)" || bad "ip rule fwmark 0x1: $n шт."
ip route show table 100 | grep -qE '^local[[:space:]]+default[[:space:]].*dev[[:space:]]+lo([[:space:]]|$)' \
  && ok "ip route local default dev lo table 100" || bad "ip route local default отсутствует"

# --- 3. DNS ---
hdr "3. DNS"
for h in cp.cloudflare.com www.google.com www.gstatic.com; do
  if timeout 5 getent ahosts "$h" >/dev/null 2>&1; then
    ok "DNS $h"
  else
    bad "DNS $h (timeout 5s)"
  fi
done

# --- 4. TCP до B и C ---
hdr "4. TCP до апстримов"
: "${IP_C:?IP_C не задан}"; : "${PORT_C:?PORT_C не задан}"
: "${IP_B:?IP_B не задан}"; : "${PORT_B:?PORT_B не задан}"
timeout 5 bash -c "cat < /dev/null > /dev/tcp/${IP_C}/${PORT_C}" && ok "TCP C:$PORT_C" || bad "TCP C:$PORT_C"
timeout 5 bash -c "cat < /dev/null > /dev/tcp/${IP_C}/22"          && ok "TCP C:22"    || bad "TCP C:22"
timeout 5 bash -c "cat < /dev/null > /dev/tcp/${IP_B}/${PORT_B}" && ok "TCP B:$PORT_B" || bad "TCP B:$PORT_B"

# --- 5. Direct ---
hdr "5. Прямой исходящий трафик (для сравнения)"
c=$(curl -sS --max-time 10 https://www.google.com/generate_204 -o /dev/null -w '%{http_code}')
[[ "$c" == "204" ]] && ok "google direct 204" || bad "google direct: $c"
direct_ip=$(curl -sS --max-time 10 https://ifconfig.me 2>/dev/null)
if [[ -n "$direct_ip" ]]; then
  ok "direct ifconfig.me → $direct_ip (это NAT D, НЕ C)"
else
  bad "ifconfig.me direct пуст"
fi

# --- 6. Через mihomo mixed-port (Reality-туннели) ---
hdr "6. Через mixed-port (socks5) → C/B"
c=$(curl --noproxy '*' -x socks5h://127.0.0.1:7890 -sS --connect-timeout 3 --max-time 10 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)
[[ "$c" == "204" ]] && ok "gstatic via socks5: 204" || bad "gstatic via socks5: $c"

out_ip=$(curl --noproxy '*' -x socks5h://127.0.0.1:7890 -sS --connect-timeout 3 --max-time 10 https://ifconfig.me 2>/dev/null)
if [[ -z "$out_ip" ]]; then
  bad "socks5-выход ifconfig.me: пусто"
elif [[ "$out_ip" == "${IP_C}" ]]; then
  ok "socks5-выход = C ($IP_C)"
elif [[ "$out_ip" == "${IP_B}" ]]; then
  ok "socks5-выход = B ($IP_B, fallback)"
else
  bad "socks5-выход = $out_ip — НЕ C ($IP_C) и НЕ B ($IP_B). Трафик ушёл в DIRECT!"
  [[ "$out_ip" == "$direct_ip" ]] && info "  (совпадает с прямым выходом D → точно DIRECT)"
fi

# --- 7. Геофильтрация (по правилам в config.yaml) ---
hdr "7. Геофильтрация (по правилам)"
grep -q 'GEOSITE,category-ru,DIRECT' "$CONFIG" && ok "config: GEOSITE,category-ru,DIRECT" || bad "config: нет GEOSITE,category-ru,DIRECT"
grep -q 'GEOSITE,cn,DIRECT'          "$CONFIG" && ok "config: GEOSITE,cn,DIRECT"          || bad "config: нет GEOSITE,cn,DIRECT"
grep -q 'MATCH,PROXY'                "$CONFIG" && ok "config: MATCH,PROXY"                || bad "config: нет MATCH,PROXY"

# --- 7a. Проверка маршрутизации ifconfig.me через API ---
hdr "7a. Куда реально ушёл ifconfig.me"
conn=$(curl -sS -m 5 ${API_AUTH:+-H "$API_AUTH"} "http://127.0.0.1:9900/connections" 2>/dev/null)
if [[ -z "$conn" ]]; then
  warn "API :9900/connections не отвечает — пропуск"
else
  route=$(printf '%s' "$conn" | tr ',' '\n' | grep -A20 '"host":"ifconfig.me"' | grep -o '"chains":\[[^]]*\]' | head -1)
  if [[ -n "$route" ]]; then
    ok "активное соединение ifconfig.me: $route"
    if echo "$route" | grep -q 'PROXY'; then
      ok "  → через PROXY"
    elif echo "$route" | grep -q 'DIRECT'; then
      bad "  → через DIRECT (должно быть PROXY)"
    fi
  else
    info "нет активного соединения ifconfig.me (запрос уже завершён — смотри журнал)"
  fi
fi

# --- 7b. Резолв ifconfig.me через DNS D ---
hdr "7b. Резолв ifconfig.me через DNS D"
resolved=$(dig @127.0.0.1 -p 1053 ifconfig.me +short 2>/dev/null | head -3 | tr '\n' ' ')
if [[ -n "$resolved" ]]; then
  ok "ifconfig.me → $resolved"
  # Если хоть один IP попадает в GEOIP RU/CN — это объясняет DIRECT
  for ip in $resolved; do
    geo=$(curl -sS -m 3 "https://ipinfo.io/${ip}/json" 2>/dev/null | grep -o '"country":"[A-Z]*"' | cut -d'"' -f4)
    [[ -n "$geo" ]] && info "  ${ip} → country=${geo}"
  done
else
  warn "dig не вернул IP для ifconfig.me"
fi

# --- 8. Health-check апстримов через API ---
hdr "8. Health-check апстримов (API :9900)"
for p in to-serverC to-serverB; do
  resp=$(curl -sS -m 5 ${API_AUTH:+-H "$API_AUTH"} "http://127.0.0.1:9900/proxies/$p" 2>/dev/null)
  if [[ -z "$resp" ]]; then
    bad "$p: API :9900 не отвечает"
    continue
  fi
  alive=$(printf '%s' "$resp" | grep -o '"alive":[a-z]*' | head -1 | cut -d: -f2)
  delay=$(printf '%s' "$resp" | grep -o '"delay":[0-9]*' | head -1 | cut -d: -f2)
  if [[ "$alive" == "true" ]]; then
    ok "$p alive=true, delay=${delay}ms"
  else
    bad "$p alive=false, delay=${delay:-?}ms"
    # Показать, по какому URL идёт health-check
    url=$(printf '%s' "$resp" | grep -o '"https://[^"]*"' | head -1)
    [[ -n "$url" ]] && info "  health-check URL: $url"
  fi
done

# --- 9. Входящие LAN-соединения (из журнала) ---
hdr "9. Входящие LAN-соединения и матчинг правил"
journal_have=false
if timeout 10 journalctl -u mihomo --no-pager -q -n 500 >/dev/null 2>&1; then
  journal_have=true
fi

if ! $journal_have; then
  warn "journalctl -u mihomo недоступен — шаг пропущен"
else
  matches=$(timeout 10 journalctl -u mihomo --no-pager -q -n 500 2>/dev/null | grep -E '\-\->.*match' | tail -10)
  if [[ -n "$matches" ]]; then
    ok "в журнале есть входящие соединения (LAN → D):"
    echo "$matches" | sed 's/^/    /'
    # Проверить, есть ли явные ошибки Reality
    if timeout 10 journalctl -u mihomo --no-pager -q -n 500 2>/dev/null | grep -q 'REALITY Authentication: false'; then
      bad "в журнале есть REALITY Authentication: false"
    fi
  else
    warn "в журнале mihomo нет входящих соединений в последних 500 строках"
  fi
fi

# --- 10. Проверка Reality-аутентификации в журнале ---
hdr "10. Reality-аутентификация (по журналу)"
if $journal_have; then
  reality_true=$(timeout 10 journalctl -u mihomo --no-pager -q -n 1000 2>/dev/null | grep -c 'REALITY Authentication: true')
  reality_false=$(timeout 10 journalctl -u mihomo --no-pager -q -n 1000 2>/dev/null | grep -c 'REALITY Authentication: false')
  if (( reality_true > 0 )); then
    ok "Reality Authentication: true — $reality_true раз"
  else
    warn "Reality Authentication: true — не найдено"
  fi
  if (( reality_false > 0 )); then
    bad "Reality Authentication: false — $reality_false раз"
  fi
fi

# --- 11. Управляющий reverse-туннель ---
hdr "11. Reverse SSH tunnel D -> C"
systemctl is-active --quiet tunnel.service && ok "tunnel.service active" || bad "tunnel.service не активен"
if ssh -i "$TUNNEL_KEY" -p "$TUNNEL_C_PORT" -o BatchMode=yes -o ConnectTimeout=5 \
       -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/known_hosts_tunnel \
       "$TUNNEL_C_USER@$TUNNEL_C_HOST" \
       "ss -tln | grep -q '127.0.0.1:${TUNNEL_REMOTE_PORT} '" 2>/dev/null; then
  ok "C: 127.0.0.1:${TUNNEL_REMOTE_PORT} слушает"
else
  bad "C: 127.0.0.1:${TUNNEL_REMOTE_PORT} НЕ слушает"
fi

# --- Итог ---
printf '\n\033[1mИтог:\033[0m %s✓%d%s  %s✗%d%s  %s⚠%d%s\n' \
  $'\033[0;32m' "$PASS" $'\033[0m' \
  $'\033[0;31m' "$FAIL" $'\033[0m' \
  $'\033[0;33m' "$WARN" $'\033[0m'
if (( FAIL > 0 )); then
  exit 1
fi
exit 0