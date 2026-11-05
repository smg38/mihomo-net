#!/bin/bash
# =============================================================================
# grant.sh — выдача доступа к user*.txt на сервере C
# Версия: 3.2.0   2026.11.5
# Автор: @smg38
#
# Использование (запускать на C):
#   grant.sh list                 — список юзеров
#   grant.sh grant <user>         — постоянный токен
#   grant.sh once <user> [ttl]    — одноразовая ссылка (по умолчанию 300 сек)
#   grant.sh revoke <user>        — отозвать все токены юзера
#   grant.sh list-tokens          — активные токены
# =============================================================================

set -euo pipefail

WEB_DIR="/var/www/html/mihomo"
KEYS_DIR="/opt/mihomo/keys"
SUB_DIR="$WEB_DIR/sub"
ONCE_DIR="$WEB_DIR/once"
TTL_DEFAULT=300
HOST="{{ WEB_IP }}"
if [ "${HOST[0]}" == "{{" ]; then
        # shellcheck disable=SC1091
        source ./lib/env.sh
        load_env_file build/keys/params.env  || true
        #WEB_IP=$(cat build/keys/params.env | grep WEB_IP | sed -e 's/WEB_IP=//g
        HOST="${WEB_IP:-}"
fi
#HOST="${HOST:-$(hostname -I | awk '{print $1}')}"

mkdir -p "$SUB_DIR" "$ONCE_DIR"
chmod 755 "$SUB_DIR" "$ONCE_DIR"

usage() {
    cat <<EOF
Использование:
  grant.sh list                 — список юзеров
  grant.sh grant <user>         — постоянный токен (URL подписки)
  grant.sh once <user> [ttl]    — одноразовая ссылка на ttl сек
  grant.sh revoke <user>        — отозвать все токены юзера
  grant.sh list-tokens          — показать активные токены
EOF
    exit 1
}

case "${1:-}" in
    list)
        ls "$KEYS_DIR" | grep '\.txt$' | sed 's/\.txt$//'
        ;;

    grant)
            user="${2:?Укажи пользователя}"
            src="$KEYS_DIR/$user.txt"
            [ -f "$src" ] || { echo "Нет такого: $user"; exit 1; }
            token=$(openssl rand -hex 8)
            # Копия, а не симлинк: работает с disable_symlinks on
            cp "$src" "$SUB_DIR/$token" || { echo "Не удалось создать копию $$SUB_DIR/$token"; exit 1; }
            #ln -s "$src" "$SUB_DIR/$token" || { echo "Не удалось создать симлинк $$SUB_DIR/$token"; exit 1; }
            chmod 644 "$SUB_DIR/$token"
            echo "Постоянный URL подписки:"
            echo "  http://$HOST/mihomo/sub/$token"
        ;;

    once)
        user="${2:?Укажи пользователя}"
        ttl="${3:-$TTL_DEFAULT}"
        src="$KEYS_DIR/$user.txt"
        [ -f "$src" ] || { echo "Нет такого: $user"; exit 1; }
        token=$(openssl rand -hex 8)
        target="$ONCE_DIR/$token.txt"
        cp "$src" "$target"
        chmod 644 "$target"
        echo "Одноразовая ссылка (действует $ttl сек):"
        echo "  http://$HOST/mihomo/once/$token.txt"
        ( sleep "$ttl"; rm -f "$target" ) &
        disown
        ;;

    revoke)
        user="${2:?Укажи пользователя}"
        target="$KEYS_DIR/$user.txt"
        count=0
        # Постоянные: ищем копии по содержимому
        for f in "$SUB_DIR"/*; do
            [ -f "$f" ] || continue
            if cmp -s "$f" "$target"; then
                rm -f "$f"
                count=$((count + 1))
            fi
        done
        # Одноразовые: тоже по содержимому
        for f in "$ONCE_DIR"/*; do
            [ -f "$f" ] || continue
            if cmp -s "$f" "$target"; then
                rm -f "$f"
                count=$((count + 1))
            fi
        done
        echo "Отозвано токенов: $count"
        ;;

    list-tokens)
        echo "Постоянные (sub/):"
        for f in "$SUB_DIR"/*; do
            [ -f "$f" ] || continue
            token=$(basename "$f")
            # Ищем, какому user*.txt соответствует содержимое
            user="?"
            for k in "$KEYS_DIR"/*.txt; do
                [ -f "$k" ] || continue
                if cmp -s "$f" "$k"; then
                    user=$(basename "$k" .txt)
                    break
                fi
            done
            echo "  $token → $user"
        done
        echo
        echo "Одноразовые (once/):"
        ls "$ONCE_DIR" 2>/dev/null || echo "  (нет)"
        ;;

    *)
        usage
        ;;
esac