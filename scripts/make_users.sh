#!/bin/bash
set -uo pipefail

server="${1:-C}"
# shellcheck disable=SC1091
source build/keys/params.env
USERNAME="${2:-user1}"
PASSWORD="${3:-Test1234Test}"

# Косвенное раскрытие переменных IP_<server>, PORT_<server>
ip_var="IP_${server}"
port_var="PORT_${server}"
IP="${!ip_var:-}"
PORT="${!port_var:-}"

[[ -n "$IP"   ]] || { echo "нет IP_${server} в params.env";   exit 1; }
[[ -n "$PORT" ]] || { echo "нет PORT_${server} в params.env"; exit 1; }

SNI="$SERVERNAME"
METHOD="${METHOD:-chacha20-ietf-poly1305}"
# base64 от строки "chacha20-ietf-poly1305:<pass>"
# Для trojan-подписки пароль часто кодируют как base64(cipher:password)
#PASS=$(printf '%s' "$METHOD:$PASSWORD" | base64 -w0)
SS_B64=$(printf '%s' "${METHOD}:${PASSWORD}" | base64 -w0)
# Экспорт в окружение для templater.sh
export SS_B64 USERNAME PASSWORD IP PORT SNI

# Проверка, что шаблон есть
[[ -f template/trojan.txt.j3 ]] || { echo "нет шаблона template/trojan.txt.j3"; exit 1; }

# Рендер в stdout
scripts/templater.sh template/trojan.txt.j3

#printf 'password=%s\n' "$PASS"