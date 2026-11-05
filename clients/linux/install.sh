#!/bin/bash
# =============================================================================
# linux/install.sh — Установка Mihomo на Linux
# Версия: 1.0.0
#
# Использование:
#   curl -fsSL http://<IP_C>/linux/install.sh | bash -s -- --config-url "URL"
#   ./install.sh --config-url "URL" [--install-dir DIR] [--skip-service]
#
# Поддерживаемые ОС: Debian/Ubuntu, CentOS/RHEL/Fedora, Arch, openSUSE
# =============================================================================

set -euo pipefail

# --- Параметры ---
CONFIG_URL=""
INSTALL_DIR="${HOME}/.config/mihomo"
BIN_DIR="${HOME}/.local/bin"
SKIP_SERVICE=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-url)    CONFIG_URL="$2"; shift 2 ;;
        --install-dir)   INSTALL_DIR="$2"; shift 2 ;;
        --bin-dir)       BIN_DIR="$2"; shift 2 ;;
        --skip-service)  SKIP_SERVICE=true; shift ;;
        --force)         FORCE=true; shift ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

if [[ -z "$CONFIG_URL" ]]; then
    echo "Использование: $0 --config-url <URL>"
    echo "  URL подписки: http://<IP_C>/mihomo/sub/<token>"
    exit 1
fi

# --- Проверка зависимостей ---
for cmd in curl tar gzip base64; do
    command -v "$cmd" >/dev/null || { echo "Требуется: $cmd"; exit 1; }
done

# --- Определение архитектуры ---
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)   MIHOMO_ARCH="amd64" ;;
    aarch64|arm64)  MIHOMO_ARCH="arm64" ;;
    armv7l)         MIHOMO_ARCH="armv7" ;;
    armv6l)         MIHOMO_ARCH="armv6" ;;
    i386|i686)      MIHOMO_ARCH="386" ;;
    *) echo "Неподдерживаемая архитектура: $ARCH"; exit 1 ;;
esac

echo "[1/6] Проверка существующей установки..."
if [[ -x "$BIN_DIR/mihomo" && "$FORCE" != true ]]; then
    echo "  Mihomo уже установлен в $BIN_DIR/mihomo"
    echo "  Используйте --force для переустановки или linux/uninstall.sh для удаления."
    exit 0
fi

echo "[2/6] Создание каталогов..."
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

echo "[3/6] Загрузка mihomo (${MIHOMO_ARCH})..."
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${MIHOMO_ARCH}-v1-compatible.gz"
TMP_GZ=$(mktemp)
curl -fL --progress-bar -o "$TMP_GZ" "$MIHOMO_URL"
gunzip -f "$TMP_GZ"
mv "${TMP_GZ%.gz}" "$BIN_DIR/mihomo"
chmod +x "$BIN_DIR/mihomo"
rm -f "$TMP_GZ"

echo "[4/6] Загрузка конфигурации..."
curl -fL -o "$INSTALL_DIR/config.yaml" "$CONFIG_URL"

echo "[5/6] Валидация конфигурации..."
"$BIN_DIR/mihomo" -t -d "$INSTALL_DIR" -f "$INSTALL_DIR/config.yaml" \
    || { echo "Конфигурация невалидна"; exit 1; }

echo "[6/6] Настройка..."
# PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
        [[ -f "$rc" ]] || continue
        grep -q "BIN_DIR_MIHOMO" "$rc" 2>/dev/null || {
            echo "" >> "$rc"
            echo "# Mihomo" >> "$rc"
            echo "export PATH=\"$BIN_DIR:\$PATH\" # BIN_DIR_MIHOMO" >> "$rc"
        }
    done
    export PATH="$BIN_DIR:$PATH"
fi

# Systemd (user) или systemd (system с sudo)
SERVICE_INSTALLED=false
if [[ "$SKIP_SERVICE" == false ]]; then
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user show-environment >/dev/null 2>&1; then
            # User systemd
            mkdir -p "$HOME/.config/systemd/user"
            cat > "$HOME/.config/systemd/user/mihomo.service" <<EOF
[Unit]
Description=Mihomo Proxy
After=network.target

[Service]
Type=simple
ExecStart=$BIN_DIR/mihomo -d $INSTALL_DIR
Restart=always
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=default.target
EOF
            systemctl --user daemon-reload
            systemctl --user enable --now mihomo.service
            SERVICE_INSTALLED=true
            echo "  Служба systemd (user) установлена и запущена."
        elif command -v sudo >/dev/null 2>&1; then
            # System systemd через sudo
            echo "  Установка системной службы (потребуется sudo)..."
            sudo tee /etc/systemd/system/mihomo.service >/dev/null <<EOF
[Unit]
Description=Mihomo Proxy
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$BIN_DIR/mihomo -d $INSTALL_DIR
Restart=always
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable --now mihomo.service
            SERVICE_INSTALLED=true
            echo "  Системная служба установлена и запущена."
        fi
    fi
fi

if [[ "$SERVICE_INSTALLED" == false ]]; then
    echo "  Служба не установлена. Ручной запуск:"
    echo "    $BIN_DIR/mihomo -d $INSTALL_DIR &"
fi

cat <<EOF

========================================
 Установка завершена!
========================================
 Каталог:      $INSTALL_DIR
 Бинарь:       $BIN_DIR/mihomo
 Конфигурация: $INSTALL_DIR/config.yaml
 Веб-панель:   http://127.0.0.1:9090/ui
 Прокси:       HTTP/SOCKS5 на порту 7890

 Управление:
   systemctl --user [status|restart|stop] mihomo   (user)
   sudo systemctl [status|restart|stop] mihomo     (system)

 Удаление:
   curl -fsSL <HOST>/linux/uninstall.sh | bash

 Альтернатива (GUI):
   Clash Verge Rev — https://github.com/clash-verge-rev/clash-verge-rev/releases/latest
   Mihomo Party    — https://github.com/mihomo-party-org/mihomo-party/releases/latest
EOF
