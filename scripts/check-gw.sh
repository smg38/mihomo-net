#!/usr/bin/env bash
set -euo pipefail
GATEWAY="${1:-192.168.10.43}"
HOST="${2:-ifconfig.me}"
TARGET_IP=$(dig +short A "$HOST" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print; exit}')
if [[ -z "$TARGET_IP" ]]; then
  echo "Не удалось разрешить $HOST в IPv4. Проверьте сеть и dig." >&2
  exit 1
fi
echo "Целевой IP ($HOST): $TARGET_IP"
ROUTE_ADDED=0
if ip route get "$TARGET_IP" | grep -q "via $GATEWAY"; then
  echo "Маршрут уже настроен через шлюз $GATEWAY."
else
  echo "Добавляем временный маршрут: $TARGET_IP через $GATEWAY"
  sudo ip route add "$TARGET_IP/32" via "$GATEWAY"
  ROUTE_ADDED=1
fi
cleanup() {
  if (( ROUTE_ADDED )); then
    echo "Удаляем временный маршрут."
    sudo ip route del "$TARGET_IP/32" via "$GATEWAY" || true
  fi
}
trap cleanup EXIT
curl --fail --silent --show-error -- "$HOST"
echo
