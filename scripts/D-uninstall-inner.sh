#!/bin/bash
# =============================================================================
# uninstall.sh — удаление сервера D (запускается НА D)
# Версии: 3.2.0   2026-11-5
# Автор: @smg38
# =============================================================================
set -euo pipefail

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[0;33m⚠\033[0m %s\n' "$*" >&2; }
fail() { printf '  \033[0;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Запускать от root"
[[ "$(uname -s)" == "Linux" ]] || fail "Только Linux"
[[ -d /run/systemd/system ]] || fail "Нужен systemd"

KEEP=false
[[ "${1:-}" == "--keep-config" ]] && KEEP=true
DIR_D="${DIR_D:-/opt/mihomo}"

log "Остановка служб"
systemctl stop mihomo.service 2>/dev/null || true
systemctl disable mihomo.service 2>/dev/null || true
systemctl stop tunnel.service 2>/dev/null || true
systemctl disable tunnel.service 2>/dev/null || true

log "Удаление unit-файлов"
rm -f /etc/systemd/system/mihomo.service
rm -f /etc/systemd/system/tunnel.service
systemctl daemon-reload || true

log "Очистка nftables и policy routing"
nft list table clash >/dev/null 2>&1 && nft delete table clash || true
ip rule del fwmark 1 lookup 100 2>/dev/null || true
ip route flush table 100 2>/dev/null || true

log "Удаление бинаря"
rm -f /usr/local/bin/mihomo

log "Удаление $DIR_D"
if $KEEP; then
    [[ -f "$DIR_D/config.yaml" ]] && cp "$DIR_D/config.yaml" "$HOME/mihomo-D-config-backup.yaml" && ok "config.yaml сохранён: $HOME/mihomo-D-config-backup.yaml"
    [[ -f "$DIR_D/.env" ]] && cp "$DIR_D/.env" "$HOME/mihomo-D-env-backup.env" && ok ".env сохранён: $HOME/mihomo-D-env-backup.env"
fi
rm -rf "$DIR_D"

log "Удаление ключа туннеля"
rm -f /root/.ssh/id_ed25519_tunnel /root/.ssh/id_ed25519_tunnel.pub
rm -f /root/.ssh/known_hosts_tunnel

warn "Ключ D->C в ~/.ssh/authorized_keys на C НЕ удалён. Удалите вручную на C:"
warn "  grep -v 'tunnel-D-to-C' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new && mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys"

ok "D удалён"