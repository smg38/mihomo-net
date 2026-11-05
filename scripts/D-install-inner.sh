#!/bin/bash
# =============================================================================
# install.sh — установка сервера D (внутри D-install.run, запускается НА D)
# Версия 3.2.0   2026-11-5
# Автор: @smg38
#
# Использование на D:
#   curl -fsSL <URL>.run | sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

help() { sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0; }
SKIP_TUNNEL=false
SKIP_MIHOMO=false
SKIP_TESTS=false
DO_UNINSTALL=false
KEEP_CONFIG=false
for arg in "$@"; do
  case "$arg" in
    --skip-tunnel) SKIP_TUNNEL=true ;;
    --skip-mihomo) SKIP_MIHOMO=true ;;
    --skip-tests)  SKIP_TESTS=true ;;
    --uninstall)   DO_UNINSTALL=true ;;
    --keep-config) KEEP_CONFIG=true ;;
    -h|--help) help ;;
    *) echo "Неизвестный аргумент: $arg" >&2; help ;;
  esac
done

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[2m=\033[0m %s\n' "$*"; } 
warn() { printf '  \033[0;33m⚠\033[0m %s\n' "$*" >&2; }
fail() { printf '  \033[0;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Запускать от root"
[[ "$(uname -s)" == "Linux" ]] || fail "Только Linux"
[[ -d /run/systemd/system ]] || fail "Нужен systemd"

# --- Uninstall ---
if $DO_UNINSTALL; then
    log "Удаление D"
    local_dir="${DIR_D:-/opt/mihomo}"

    systemctl stop mihomo.service 2>/dev/null || true
    systemctl disable mihomo.service 2>/dev/null || true
    systemctl stop tunnel.service 2>/dev/null || true
    systemctl disable tunnel.service 2>/dev/null || true

    rm -f /etc/systemd/system/mihomo.service
    rm -f /etc/systemd/system/tunnel.service
    systemctl daemon-reload || true

    nft list table clash >/dev/null 2>&1 && nft delete table clash || true
    ip rule del fwmark 1 lookup 100 2>/dev/null || true
    ip route flush table 100 2>/dev/null || true

    rm -f /usr/local/bin/mihomo

    if $KEEP_CONFIG; then
        [[ -f "$local_dir/config.yaml" ]] && cp "$local_dir/config.yaml" "$HOME/mihomo-D-config-backup.yaml" && ok "config.yaml сохранён: $HOME/mihomo-D-config-backup.yaml"
        [[ -f "$local_dir/.env" ]] && cp "$local_dir/.env" "$HOME/mihomo-D-env-backup.env" && ok ".env сохранён: $HOME/mihomo-D-env-backup.env"
    fi
    rm -f "$local_dir/install.sh"
    rm -rf "$local_dir"

    rm -f /root/.ssh/id_ed25519_tunnel /root/.ssh/id_ed25519_tunnel.pub
    rm -f /root/.ssh/known_hosts_tunnel

    warn "Ключ D->C в ~/.ssh/authorized_keys на C НЕ удалён. Удалите вручную на C:"
    warn "  grep -v 'tunnel-D-to-C' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new && mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys"
    ok "D удалён"
    exit 0
fi

# --- 1. Пакеты ---
log "Установка пакетов"
if command -v apt-get >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq openssh-client nftables curl ca-certificates tar gzip
elif command -v dnf >/dev/null; then
  dnf install -y -q openssh-clients nftables curl ca-certificates tar gzip
elif command -v yum >/dev/null; then
  yum install -y -q openssh-clients nftables curl ca-certificates tar gzip
elif command -v pacman >/dev/null; then
  pacman -Sy --noconfirm openssh nftables curl ca-certificates tar gzip
else
  fail "Неизвестный пакетный менеджер"
fi
ok "пакеты установлены"

# --- 2. D-config ---
log "Загрузка D-config"
[[ -f D-config ]] || fail "Нет D-config в архиве"
# shellcheck disable=SC1091
source ./D-config
: "${IP_C:?IP_C не задан}"
: "${TUNNEL_C_HOST:=$IP_C}"
: "${TUNNEL_C_USER:=root}"
: "${TUNNEL_C_PORT:=22}"
: "${TUNNEL_REMOTE_PORT:=2222}"
: "${TUNNEL_KEY:=/root/.ssh/id_ed25519_tunnel}"
: "${DIR_D:=/opt/mihomo}"
ok "IP_C=$IP_C  TUNNEL_REMOTE_PORT=$TUNNEL_REMOTE_PORT  DIR_D=$DIR_D"

# --- 3. Раскладка ---
log "Раскладка файлов в $DIR_D"
mkdir -p "$DIR_D/scripts" "$DIR_D/lib"
install -m 0755 mihomo                /usr/local/bin/mihomo
ln -sfn /usr/local/bin/mihomo         "$DIR_D/mihomo"
install -m 0755 entrypoint.sh         "$DIR_D/scripts/entrypoint.sh"
install -m 0644 lib/env.sh            "$DIR_D/lib/env.sh"
install -m 0644 lib/http.sh           "$DIR_D/lib/http.sh"
install -m 0644 config.yaml           "$DIR_D/config.yaml"
install -m 0600 env.sh                "$DIR_D/.env"
install -m 0644 mihomo.service        /etc/systemd/system/mihomo.service
install -m 0644 tunnel.service        /etc/systemd/system/tunnel.service
install -m 0644 D-config              "$DIR_D/D-config"
install -m 0755 "$0"                  "$DIR_D/install.sh"
install -m 0755 D-test.sh             "$DIR_D/D-test.sh"
ok "файлы разложены"

# # Объявить таблицу 100 в rt_tables, чтобы entrypoint.sh мог создать маршрут
# if ! grep -qE '^100[[:space:]]+tproxy' /etc/iproute2/rt_tables 2>/dev/null; then
#     echo '100 tproxy' >> /etc/iproute2/rt_tables
#     ok "таблица маршрутизации 100 (tproxy) объявлена в /etc/iproute2/rt_tables"
# fi

# Таблицу 100 объявляет entrypoint.sh перед ip route add — здесь дублировать не нужно.

# --- 4. GeoSite.dat / geoip.metadb ---
log "GeoSite.dat / geoip.metadb"
[[ -f geosite.dat ]] || fail "GeoSite.dat обязателен (category-ru), но его нет в архиве"
install -m 0644 geosite.dat "$DIR_D/GeoSite.dat"
ok "GeoSite.dat"
if [[ -f geoip.metadb ]]; then
  install -m 0644 geoip.metadb "$DIR_D/geoip.metadb"
  ok "geoip.metadb"
fi

# --- 5. CIDR (опционально, D скачает сам если нет) ---
for f in cn_cidr.txt ru_cidr.txt; do
  if [[ -f "$f" ]]; then
    install -m 0644 "$f" "$DIR_D/$f"
    ok "$f из архива"
  fi
done

# --- 6. Ключ D->C ---
log "Установка ключа D->C"
install -d -m 700 /root/.ssh
if [[ -f ssh/id_ed25519_tunnel ]]; then
    install -m 600 ssh/id_ed25519_tunnel     "$TUNNEL_KEY"
    install -m 644 ssh/id_ed25519_tunnel.pub "${TUNNEL_KEY}.pub"
    ok "ключ D->C из архива"
else
    fail "Нет ssh/id_ed25519_tunnel в архиве"
fi

# --- 6.5. Авторизация публичного ключа A для A→D (diagnose.sh, deploy_D) ---
log "Авторизация публичного ключа A в authorized_keys D"
if [[ -f A_authorized_key.pub ]]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    # Идемпотентно: не дублировать строку
    if ! grep -qxF "$(cat A_authorized_key.pub)" /root/.ssh/authorized_keys; then
        cat A_authorized_key.pub >> /root/.ssh/authorized_keys
        ok "ключ A добавлен в authorized_keys D"
    else
        skip "ключ A уже в authorized_keys D"
    fi
else
    warn "Нет A_authorized_key.pub в архиве — A не сможет зайти на D через ProxyCommand C"
    warn "Добавьте вручную на D: echo '<pub-key-A>' >> /root/.ssh/authorized_keys"
fi

# --- 7. Проверка GatewayPorts на C ---
log "Проверка GatewayPorts на C"
GP=$(ssh -i "$TUNNEL_KEY" -p "$TUNNEL_C_PORT" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/root/.ssh/known_hosts_tunnel \
    "$TUNNEL_C_USER@$TUNNEL_C_HOST" \
    "sshd -T 2>/dev/null | grep -i '^gatewayports' || echo 'gatewayports no'")
case "$GP" in
  *"no"*) ok "GatewayPorts no" ;;
  *) warn "GatewayPorts=$GP — порт может открыться на 0.0.0.0. Исправьте на C" ;;
esac

# --- 8. Запуск служб ---
systemctl daemon-reload

if ! $SKIP_TUNNEL; then
  log "Перезапуск tunnel.service (старый экземпляр останавливается)"

  # 1. Остановить старый экземпляр, если он есть — чтобы освободить порт на C.
  if systemctl is-active --quiet tunnel.service 2>/dev/null; then
    systemctl stop tunnel.service
    # Ждём, пока старый SSH-процесс завершится (максимум 5 секунд).
    for _ in $(seq 1 10); do
      systemctl is-active --quiet tunnel.service || break
      sleep 0.5
    done
  fi
  # На всякий случай добить осиротевшие ssh-процессы именно нашего туннеля
  pkill -f "ssh .*-R 127.0.0.1:${TUNNEL_REMOTE_PORT}:localhost:22" 2>/dev/null || true
  sleep 1

  # 2. Включить автозапуск и запустить заново.
  systemctl enable tunnel.service
  systemctl restart tunnel.service
  sleep 3

  if ! systemctl is-active --quiet tunnel.service; then
    journalctl -u tunnel.service --no-pager -n 30 >&2
    fail "tunnel.service не запустился"
  fi
  ok "tunnel.service active"
fi

if ! $SKIP_MIHOMO; then
  log "Перезапуск mihomo.service"
  systemctl enable mihomo.service
  systemctl restart mihomo.service
  sleep 2
  if ! systemctl is-active --quiet mihomo.service; then
    journalctl -u mihomo.service --no-pager -n 50 >&2
    fail "mihomo.service не запустился"
  fi
  ok "mihomo.service active"
fi

# --- 9. Тесты ---
if $SKIP_TESTS; then
  log "Тесты пропущены (--skip-tests)"
else
  log "Ожидание готовности mihomo (порты + nft + API)"
  # Ждём до 30 сек: порт 7890, порт 7893, nft table clash, API :9900
  ready=false
  for _ in $(seq 1 60); do
      if ss -tln 2>/dev/null | grep -q ':7890 ' \
         && ss -tln 2>/dev/null | grep -q ':7893 ' \
         && nft list table clash >/dev/null 2>&1 \
         && curl -sS -m 2 -o /dev/null -H "Authorization: Bearer ${SECRET_KEY_D:-}" \
              "http://127.0.0.1:9900/version" 2>/dev/null; then
          ready=true
          break
      fi
      sleep 0.5
  done
  if $ready; then
      ok "mihomo готов (порты, nft, API)"
  else
      warn "mihomo не готов за 30 сек — тесты могут быть ложными"
  fi
  # Дать fallback 5 сек на health-check
  sleep 5
  log "Тесты работоспособности: $DIR_D/D-test.sh"
  if timeout 120 "$DIR_D/D-test.sh"; then
      ok "все тесты пройдены"
  else
      rc=$?
      if [[ $rc -eq 124 ]]; then
          warn "D-test.sh завис (>120с), прерван. Проверьте вручную: $DIR_D/D-test.sh"
      else
          warn "тесты провалены (rc=$rc). Запустить вручную: $DIR_D/D-test.sh"
      fi
      # не fail — установка уже состоялась, службы активны
  fi
fi

#   if ! $SKIP_MIHOMO; then
#     check "mihomo active" systemctl is-active --quiet mihomo.service
#     check "tproxy :7893 слушает (TCP)" bash -c "ss -tln | grep -q ':7893 '"
#     check "tproxy :7893 слушает (UDP)" bash -c "ss -uln | grep -q ':7893 '"
#     check "DNS :1053 слушает (TCP)"   bash -c "ss -tln | grep -q ':1053 '"
#     check "DNS :1053 слушает (UDP)"   bash -c "ss -uln | grep -q ':1053 '"
#     check "nft table clash" bash -c "nft list table clash >/dev/null 2>&1"
#     check "ip rule fwmark 0x1 lookup 100" bash -c "ip rule show | grep -qE '^[0-9]+:[[:space:]]+from all fwmark 0x1 lookup 100$'"
#     check "ip rule fwmark 0x1 не дублируется" bash -c "[ \"\$(ip rule show | grep -cE '^[0-9]+:[[:space:]]+from all fwmark 0x1 lookup 100$')\" = 1 ]"
#     check "ip route table 100 local default" bash -c "ip route show table 100 | grep -qE '^local[[:space:]]+default[[:space:]].*dev[[:space:]]+lo([[:space:]]|$)'"
#     check "socks5 127.0.0.1:7890 -> google 204" \
#       curl --noproxy '*' -x socks5://127.0.0.1:7890 -fsS -m 15 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204
#   fi

#   if (( FAILED > 0 )); then
#     fail "Тесты: $FAILED провал(ов). Смотрите journalctl -u mihomo -u tunnel"
#   fi
#   ok "все тесты пройдены"
# fi

log "Готово"
cat <<EOF

D установлен. Установщик сохранён: $DIR_D/install.sh
  повторная установка:       sh $DIR_D/install.sh
  удаление:                  sh $DIR_D/install.sh --uninstall
  удаление, конфиг сохранен: sh $DIR_D/install.sh --uninstall --keep-config

Дальше с A:
  scripts/build-servers.sh D --deploy
  scripts/diagnose.sh

Настройте LAN:
  шлюз по умолчанию = $(hostname -I | awk '{print $1}')
  DNS                = $(hostname -I | awk '{print $1}')
EOF