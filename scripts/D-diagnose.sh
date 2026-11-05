#!/bin/bash
# =============================================================================
# scripts/D-diagnose.sh — диагностика сервера D. Запускать на A (inspiron).
# Версия 3.2.0   2026-11-5
# Автор: @smg38
#
# Использование:
#   scripts/D-diagnose.sh               # полный прогон
#   scripts/D-diagnose.sh --no-client   # без клиентского теста (без sudo)
#   scripts/D-diagnose.sh --no-c        # без tcpdump на C и зондов с B
#   scripts/D-diagnose.sh --use-b       # переключить группу PROXY на D в to-serverB и выйти
#   scripts/D-diagnose.sh --use-c       # переключить группу PROXY на D в to-serverC и выйти
#
# Что проверяет:
#   1. D: службы, порты, ip rule, table 100, nft, ip_forward
#   2. D: группа PROXY (тип, текущий выбор)
#   3. D: реальный delay через to-serverC и to-serverB (Reality целиком)
#   4. Путь D→C: TCP, баннер SSH, MTU, TLS-зонды (разные SNI), контроль с B и A,
#      tcpdump на C во время зонда
#   5. D: ошибки dial за 10 минут и последние match
#   6. Клиентский тест с A через D (маршруты на /32, curl --noproxy)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || exit 2

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'

OK_N=0; BAD_N=0; WARN_N=0
step() { printf '\n%s%s==>%s %s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$1"; }
info() { printf '%s  ·%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; OK_N=$((OK_N+1)); }
bad()  { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$1"; BAD_N=$((BAD_N+1)); }
warn() { printf '%s  ⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; WARN_N=$((WARN_N+1)); }

# --- Аргументы ---------------------------------------------------------------
DO_CLIENT=true; DO_C=true; ACTION=""
for arg in "$@"; do
    case "$arg" in
        --no-client) DO_CLIENT=false ;;
        --no-c)      DO_C=false ;;
        --use-b)     ACTION="to-serverB" ;;
        --use-c)     ACTION="to-serverC" ;;
        -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Неизвестный аргумент: $arg" >&2; exit 2 ;;
    esac
done

# --- Параметры (deploy/lib/env.sh раскрывает ${IP_C} и т.п.) -----------------
source "$PROJECT_ROOT/deploy/lib/env.sh"
load_env_file "$PROJECT_ROOT/build/keys/params.env" || { echo "Нет build/keys/params.env" >&2; exit 2; }
for v in IP_D IP_B IP_C PORT_B PORT_C SERVERNAME SECRET_KEY_D; do
    [[ -n "${!v:-}" ]] || { echo "В params.env не задан $v" >&2; exit 2; }
done
PORT_D="${PORT_D:-7893}"
DIR_D="${DIR_D:-/opt/mihomo}"
REMOTE_USER="${REMOTE_USER:-root}"
TUNNEL_C_HOST="${TUNNEL_C_HOST:-$IP_C}"
TUNNEL_C_USER="${TUNNEL_C_USER:-root}"
TUNNEL_C_PORT="${TUNNEL_C_PORT:-22}"
TUNNEL_REMOTE_PORT="${TUNNEL_REMOTE_PORT:-2222}"

# --- SSH-обёртки -------------------------------------------------------------
SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
D_MODE=""
ssh_d() {
    case "$D_MODE" in
        direct) timeout 45 ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$IP_D" "$*" ;;
        via_c)  timeout 45 ssh "${SSH_OPTS[@]}" \
                  -o "ProxyCommand=ssh -p $TUNNEL_C_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new $TUNNEL_C_USER@$TUNNEL_C_HOST -W %h:%p" \
                  -p "$TUNNEL_REMOTE_PORT" "$REMOTE_USER@localhost" "$*" ;;
        *) return 1 ;;
    esac 2>/dev/null
}
ssh_c() { timeout 45 ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$IP_C" "$*" 2>/dev/null; }
ssh_b() { timeout 45 ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$IP_B" "$*" 2>/dev/null; }
ssh_a() { bash -c "$*" 2>/dev/null; }          # «локально на A»

api_d()   { ssh_d "curl -sS -m 12 -H 'Authorization: Bearer ${SECRET_KEY_D}' 'http://127.0.0.1:9900$1'"; }
delay_of() {
    api_d "/proxies/$1/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000" \
        | grep -o '"delay":[0-9]*' | cut -d: -f2
}

# TLS-зонд: успех = пришёл сертификат (BEGIN CERTIFICATE). Слово CONNECTED
# openssl печатает уже после TCP-connect — как признак TLS оно бесполезно.
# tls_probe <runner> <host> <port> <sni>
tls_probe() {
    local n
    n=$("$1" "timeout 7 openssl s_client -connect $2:$3 -servername $4 -tls1_3 </dev/null 2>&1 | grep -c 'BEGIN CERTIFICATE'")
    [[ "${n:-0}" =~ ^[0-9]+$ ]] && (( n > 0 ))
}

# =============================================================================
# 0. Маршрут до D
# =============================================================================
step "0. Доступ к D"
if timeout 10 ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$IP_D" true 2>/dev/null; then
    D_MODE="direct"; ok "D: прямой SSH ($IP_D)"
elif timeout 10 ssh "${SSH_OPTS[@]}" \
      -o "ProxyCommand=ssh -p $TUNNEL_C_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new $TUNNEL_C_USER@$TUNNEL_C_HOST -W %h:%p" \
      -p "$TUNNEL_REMOTE_PORT" "$REMOTE_USER@localhost" true 2>/dev/null; then
    D_MODE="via_c"; warn "D: прямой SSH недоступен — работаю через C (туннель)"
else
    bad "D недоступен ни напрямую, ни через C"; exit 1
fi
C_OK=false; B_OK=false
if $DO_C; then
    ssh_c true && C_OK=true || warn "C: SSH недоступен — tcpdump на C пропущен"
    ssh_b true && B_OK=true || warn "B: SSH недоступен — контрольный зонд с B пропущен"
fi

if [[ -n "$ACTION" ]]; then
    code=$(ssh_d "curl -sS -m 8 -o /dev/null -w '%{http_code}' -X PUT -H 'Authorization: Bearer ${SECRET_KEY_D}' -d '{\"name\":\"$ACTION\"}' http://127.0.0.1:9900/proxies/PROXY")
    [[ "$code" == "204" ]] && ok "PROXY → $ACTION (до перезапуска mihomo)" || bad "переключение не удалось, HTTP $code (группа не select?)"
    exit 0
fi

D_PUB=$(ssh_d "curl --noproxy '*' -4 -s -m 8 https://api.ipify.org" | tr -d '[:space:]')
[[ "$D_PUB" =~ ^[0-9.]+$ ]] && info "Внешний IP D (DIRECT): $D_PUB" || { D_PUB=""; warn "внешний IP D не определён"; }

# =============================================================================
# 1. Состояние D
# =============================================================================
step "1. Службы, порты и сетевые правила на D"
ssh_d "systemctl is-active --quiet mihomo"  && ok "mihomo active" || bad "mihomo НЕ active"
ssh_d "systemctl is-active --quiet tunnel"  && ok "tunnel active" || warn "tunnel НЕ active (управление через C не работает)"
for p in 7890 $PORT_D 1053; do
    ssh_d "ss -tln | grep -q ':${p} '" && ok "TCP :$p слушает" || bad "TCP :$p НЕ слушает"
done
for p in $PORT_D 1053; do
    ssh_d "ss -uln | grep -q ':${p} '" && ok "UDP :$p слушает" || warn "UDP :$p НЕ слушает"
done
n=$(ssh_d "ip rule show | grep -c 'fwmark 0x1 lookup 100'")
[[ "$n" == "1" ]] && ok "ip rule fwmark 0x1 lookup 100 (ровно одно)" || bad "ip rule fwmark 0x1 lookup 100: найдено ${n:-?} (нужно 1)"
ssh_d "ip route show table 100 | grep -q 'local default dev lo'" \
    && ok "table 100: local default dev lo" || bad "table 100: нет local default dev lo"
chain=$(ssh_d "nft list chain ip clash PREROUTING")
printf '%s' "$chain" | grep -q "tproxy to :${PORT_D}" \
    && ok "nft clash/PREROUTING: tproxy to :${PORT_D}" || bad "nft clash/PREROUTING: нет tproxy to :${PORT_D}"
ssh_d "nft list chain ip clash PREROUTING_DNS | grep -q 'redirect to :1053'" \
    && ok "nft clash/PREROUTING_DNS: redirect to :1053" || bad "nft clash/PREROUTING_DNS: нет redirect to :1053"
fw=$(ssh_d "sysctl -n net.ipv4.ip_forward")
[[ "$fw" == "1" ]] && ok "net.ipv4.ip_forward=1" || warn "net.ipv4.ip_forward=${fw:-?} (для tproxy не критично, для остального трафика нужен 1)"
ssh_d "test -s ${DIR_D}/ru_cidr.txt -a -s ${DIR_D}/cn_cidr.txt" \
    && ok "cn_cidr.txt и ru_cidr.txt на месте" || warn "cn_cidr.txt/ru_cidr.txt нет или пусты (SKIP_*IP работать не будет)"

# =============================================================================
# 2. Группа PROXY
# =============================================================================
step "2. Группа PROXY на D"
g=$(api_d "/proxies/PROXY")
G_TYPE=$(printf '%s' "$g" | grep -o '"type":"[^"]*"' | head -1 | cut -d'"' -f4)
G_NOW=$(printf '%s' "$g"  | grep -o '"now":"[^"]*"'  | head -1 | cut -d'"' -f4)
if [[ -z "$G_TYPE" ]]; then
    bad "API :9900 не отвечает или нет группы PROXY (secret верный?)"
else
    info "тип=$G_TYPE, текущий выбор=${G_NOW:-?}"
    if [[ "$G_TYPE" == "Selector" ]]; then
        warn "PROXY — select: автоперехода C→B нет. Заменить на type: fallback в template/config_D.yaml.j3"
    else
        ok "PROXY — $G_TYPE (автопереключение есть)"
    fi
fi

# =============================================================================
# 3. Реальный delay через апстримы (Reality целиком)
# =============================================================================
step "3. Delay D → апстримы (полное Reality-рукопожатие + запрос)"
DELAY_C=$(delay_of to-serverC); DELAY_B=$(delay_of to-serverB)
[[ -n "$DELAY_C" ]] && ok "to-serverC: ${DELAY_C} мс" || bad "to-serverC: нет ответа (Timeout)"
[[ -n "$DELAY_B" ]] && ok "to-serverB: ${DELAY_B} мс" || bad "to-serverB: нет ответа (Timeout)"

# =============================================================================
# 4. Путь D → C
# =============================================================================
step "4. Путь D → C ($IP_C:$PORT_C)"
t0=$(date +%s.%N)
ssh_d "timeout 5 bash -c 'exec 3<>/dev/tcp/$IP_C/$PORT_C'" && TCP_C=true || TCP_C=false
$TCP_C && ok "TCP-connect D→C:$PORT_C" || bad "TCP-connect D→C:$PORT_C не проходит"

ssh_d "timeout 5 bash -c 'exec 3<>/dev/tcp/$IP_C/22; head -c 7 <&3'" | grep -q '^SSH-' \
    && { BANNER_C=true; ok "данные D↔C на порту 22 идут (получен баннер SSH)"; } \
    || { BANNER_C=false; warn "баннер SSH с C:22 не получен"; }
ssh_d "ping -c2 -W2 -M do -s 1372 $IP_C >/dev/null 2>&1" \
    && ok "ping 1400 байт без фрагментации D→C" || warn "ping 1400 байт D→C не прошёл (проверьте MTU)"

# tcpdump на C параллельно с основным зондом
CAP_SYN=""; CAP_DATA=""
if $C_OK && [[ -n "$D_PUB" ]]; then
    cap=$(mktemp)
    ssh_c "timeout 16 tcpdump -ni any -l 'tcp port $PORT_C and host $D_PUB' 2>/dev/null" > "$cap" &
    cap_pid=$!
    sleep 3
fi

TLS_DC_ANY=false
info "TLS-зонды D→C (успех = получен сертификат dest):"
for sni in "$SERVERNAME" www.google.com example.com; do
    if tls_probe ssh_d "$IP_C" "$PORT_C" "$sni"; then
        ok "D→C  SNI=$sni: сертификат получен"; TLS_DC_ANY=true
    else
        bad "D→C  SNI=$sni: ответа на ClientHello нет"
    fi
done

if [[ -n "${cap_pid:-}" ]]; then
    wait "$cap_pid" 2>/dev/null
    CAP_SYN=$(grep -c 'Flags \[S\]' "$cap")
    CAP_DATA=$(grep ' In ' "$cap" | grep -Ec 'length [1-9]')
    rm -f "$cap"
    info "tcpdump на C: SYN от D=$CAP_SYN, входящих пакетов с данными=$CAP_DATA"
fi

if tls_probe ssh_d "$IP_B" "$PORT_B" "$SERVERNAME"; then
    ok "D→B  SNI=$SERVERNAME: сертификат получен"; TLS_DB=true
else
    bad "D→B  SNI=$SERVERNAME: ответа нет"; TLS_DB=false
fi

info "Контрольные зонды в C с других точек (только для сравнения, ошибками не считаются):"
TLS_BC=""; TLS_AC=""
if $B_OK; then
    tls_probe ssh_b "$IP_C" "$PORT_C" "$SERVERNAME" && { TLS_BC=yes; info "B→C: сертификат получен"; } || { TLS_BC=no; info "B→C: ответа нет"; }
fi
tls_probe ssh_a "$IP_C" "$PORT_C" "$SERVERNAME" && { TLS_AC=yes; info "A→C: сертификат получен"; } || { TLS_AC=no; info "A→C: ответа нет"; }

# =============================================================================
# 5. Журнал D
# =============================================================================
step "5. Журнал D за 10 минут"
logs=$(ssh_d "journalctl -u mihomo --since '10 min ago' --no-pager -q")
e_c=$(printf '%s\n' "$logs" | grep -c "error: ${IP_C}:${PORT_C}")
e_b=$(printf '%s\n' "$logs" | grep -c "error: ${IP_B}:${PORT_B}")
m_n=$(printf '%s\n' "$logs" | grep -c ' match ')
info "соединений с match: $m_n; ошибки dial к C: $e_c; к B: $e_b"
(( m_n > 0 )) && ok "LAN-трафик доходит до mihomo (tproxy работает)" || warn "за 10 минут в журнале нет ни одного match (LAN не использует D или нет трафика)"
(( e_c > 0 )) && bad "dial к C падает ($e_c за 10 минут)"
(( e_b > 0 )) && bad "dial к B падает ($e_b за 10 минут)"
printf '%s\n' "$logs" | grep ' match ' | tail -5 | sed 's/^/      /'

# =============================================================================
# 6. Клиентский тест с A через D
# =============================================================================
if $DO_CLIENT; then
    step "6. Клиентский тест: A → D → интернет (нужен sudo)"
    IFACE=$(ip -4 route get "$IP_D" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    ADDED=()
    cleanup() { for r in "${ADDED[@]:-}"; do [[ -n "$r" ]] && sudo ip route del "$r" 2>/dev/null; done; }
    trap cleanup EXIT INT TERM
    if ! { sudo -n true 2>/dev/null || sudo -v; }; then
        warn "sudo недоступен — клиентский тест пропущен"
    else
        info "интерфейс A: $IFACE; в окружении A https_proxy=${https_proxy:-нет} — curl идёт с --noproxy"
        declare -A PIN
        for h in ya.ru www.baidu.com api.ipify.org www.gstatic.com; do
            ip=$(getent ahostsv4 "$h" | awk 'NR==1{print $1}')
            [[ -n "$ip" ]] || { warn "$h: нет A-записи"; continue; }
            PIN[$h]="$ip"
            sudo ip route replace "$ip/32" via "$IP_D" dev "$IFACE" onlink && ADDED+=("$ip/32")
            ip route get "$ip" | grep -q "via $IP_D" || warn "$h ($ip): маршрут через D не применился"
        done
        CURL=(curl --noproxy '*' -4 -sS -m 12)
        for h in ya.ru www.baidu.com; do
            [[ -n "${PIN[$h]:-}" ]] || continue
            code=$("${CURL[@]}" --resolve "$h:443:${PIN[$h]}" -o /dev/null -w '%{http_code}' "https://$h" 2>/dev/null)
            [[ "$code" =~ ^[23] ]] && ok "$h (ожидается DIRECT на D): HTTP $code" || bad "$h: HTTP ${code:-000}"
        done
        if [[ -n "${PIN[www.gstatic.com]:-}" ]]; then
            code=$("${CURL[@]}" --resolve "www.gstatic.com:443:${PIN[www.gstatic.com]}" -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)
            [[ "$code" == "204" ]] && ok "gstatic (через PROXY): 204" || bad "gstatic (через PROXY): HTTP ${code:-000}"
        fi
        if [[ -n "${PIN[api.ipify.org]:-}" ]]; then
            ext=$("${CURL[@]}" --resolve "api.ipify.org:443:${PIN[api.ipify.org]}" https://api.ipify.org 2>/dev/null)
            if   [[ "$ext" == "$IP_C" ]]; then ok "внешний IP = C ($IP_C): D→C работает"
            elif [[ "$ext" == "$IP_B" ]]; then ok "внешний IP = B ($IP_B): трафик идёт через fallback/B"
            elif [[ -n "$ext" && "$ext" == "$D_PUB" ]]; then bad "внешний IP = $ext — это DIRECT D, а должен быть C или B"
            elif [[ -z "$ext" ]]; then bad "api.ipify.org через D: нет ответа (PROXY не отвечает)"
            else bad "внешний IP = $ext — не C, не B, не D"; fi
        fi
        info "журнал D за последнюю минуту по этим хостам:"
        ssh_d "journalctl -u mihomo --since '1 min ago' --no-pager -q | grep -E 'ya.ru|baidu|ipify|gstatic' | tail -8" | sed 's/^/      /'
    fi
fi

# =============================================================================
# Вердикт
# =============================================================================
step "Вердикт"
if [[ -n "$DELAY_C" ]]; then
    ok "D→C работает (delay ${DELAY_C} мс)"
elif [[ -n "$DELAY_B" ]]; then
    bad "D→C не работает, D→B работает (delay ${DELAY_B} мс)"
    if ! $TLS_DC_ANY && [[ "${CAP_SYN:-0}" -gt 0 && "${CAP_DATA:-1}" -eq 0 ]]; then
        info "C получает SYN от D, но ни одного пакета с данными: ClientHello режется ДО C."
    elif ! $TLS_DC_ANY; then
        info "Ни один TLS-зонд D→C (три разных SNI) не получил ответа."
    fi
    if [[ "$TLS_BC" == "yes" ]]; then
        info "С B до C TLS проходит → C исправен, проблема на участке D↔C (сеть/провайдер D)."
    elif [[ "$TLS_BC" == "no" ]]; then
        info "С B до C тоже не проходит → проблема на стороне C (mihomo, файрвол, провайдер C)."
    fi
    [[ "$TLS_AC" == "no" && "$TLS_BC" == "yes" ]] && info "С A (та же сеть, что и D?) тоже не проходит → режет сеть, общая для A и D."
    #$BANNER_C && info "Порт 22 на C проходит, порт $PORT_C — нет: режется именно трафик на $PORT_C/TLS."
    info "Сейчас:  scripts/D-diagnose.sh --use-b   (временно)   и  type: fallback в config_D.yaml.j3 (постоянно)"
    info "Проверить: сменить PORT_C на 443 (или другой) и/или SERVERNAME, пересобрать B/C/D."
else
    bad "D не достаёт ни до C, ни до B"
fi

printf '\n  Успешных: %s%d%s   Ошибок: %s%d%s   Предупреждений: %s%d%s\n' \
    "$C_GREEN" "$OK_N" "$C_RESET" "$C_RED" "$BAD_N" "$C_RESET" "$C_YELLOW" "$WARN_N" "$C_RESET"
(( BAD_N > 0 )) && exit 1
exit 0