#!/bin/bash
# =============================================================================
# linux/uninstall.sh — Удаление Mihomo с Linux
# Версия: 1.0.0
#
# Использование:
#   curl -fsSL http://<IP_C>/linux/uninstall.sh | bash
#   ./uninstall.sh [--install-dir DIR] [--bin-dir DIR] [--keep-config] [--force]
# =============================================================================

set -euo pipefail

INSTALL_DIR="${HOME}/.config/mihomo"
BIN_DIR="${HOME}/.local/bin"
KEEP_CONFIG=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --bin-dir)     BIN_DIR="$2"; shift 2 ;;
        --keep-config) KEEP_CONFIG=true; shift ;;
        --force)       FORCE=true; shift ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

# --- Подтверждение ---
if [[ "$FORCE" != true ]]; then
    echo "Будет удалён Mihomo:"
    echo "  бинарь:  $BIN_DIR/mihomo"
    echo "  каталог: $INSTALL_DIR"
    [[ "$KEEP_CONFIG" == true ]] && echo "  (config.yaml будет сохранён)"
    read -r -p "Продолжить? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
fi

# --- Остановка служб ---
echo "[1/3] Остановка служб..."
if systemctl --user list-unit-files mihomo.service >/dev/null 2>&1; then
    systemctl --user stop mihomo.service 2>/dev/null || true
    systemctl --user disable mihomo.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/mihomo.service"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "  User-служба удалена."
fi

if systemctl list-unit-files mihomo.service >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
        sudo systemctl stop mihomo.service 2>/dev/null || true
        sudo systemctl disable mihomo.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/mihomo.service
        sudo systemctl daemon-reload 2>/dev/null || true
        echo "  Системная служба удалена."
    fi
fi

# Убить оставшиеся процессы
pkill -f "$BIN_DIR/mihomo" 2>/dev/null || true

# --- Сохранение конфига ---
echo "[2/3] Удаление файлов..."
if [[ "$KEEP_CONFIG" == true && -f "$INSTALL_DIR/config.yaml" ]]; then
    BACKUP="$HOME/mihomo-config-backup.yaml"
    cp "$INSTALL_DIR/config.yaml" "$BACKUP"
    echo "  Конфиг сохранён: $BACKUP"
fi

rm -f "$BIN_DIR/mihomo"
rm -rf "$INSTALL_DIR"

# Удалить записи PATH из rc-файлов
for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    if grep -q "BIN_DIR_MIHOMO" "$rc" 2>/dev/null; then
        sed -i.bak '/# Mihomo/d; /BIN_DIR_MIHOMO/d' "$rc"
        echo "  Очищен $rc"
    fi
done

echo "[3/3] Готово."
echo ""
echo "Удаление завершено."