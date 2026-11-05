#!/bin/bash
# Версия 3.2.0  2026.10.20
# Скрипт ищет доступные серверы для проекта

target="${1:-C}"
user="${2:-root}"
source deploy/lib/env.sh

case "$target" in
    C) ip="$IP_C"; port="$PORT_C"; uuid_var="UUID_C_${user}"
       pbk="$PUBLIC_KEY_C"; sid="$SHORT_ID_C"; flow="${FLOW_USERS:-xtls-rprx-vision}" ;;
    B) ip="$IP_B"; port="$PORT_B"; uuid_var="$UUID_BA"
       pbk="$PUBLIC_KEY_B"; sid="$SHORT_ID_B"; flow="${FLOW_AB:-xtls-rprx-vision}" ;;
    *) echo "цель: C или B"; exit 1 ;;
esac

HOSTS=(dl.google.com www.apple.com itunes.apple.com www.microsoft.com addons.mozilla.org www.samsung.com www.adobe.com www.dropbox.com www.spotify.com stackoverflow.com www.bing.com www.ozon.ru www.avito.ru www.tinkoff.ru)
ATTEMPTS=20
TMPDIR_RESULTS="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RESULTS"' EXIT
echo "Server $target"
# Проверка TLS 1.3 на самом сервере (один раз)
ssh "$user@$ip" 'timeout 5 openssl s_client -connect www.apple.com:443 -servername www.apple.com -tls1_3 </dev/null 2>&1 | grep "Cipher is"'

# Запускаем проверку каждого хоста параллельно (в фоне)
for h in "${HOSTS[@]}"; do
    (
        t0=$(date +%s.%N)

        # Один SSH-сеанс: 20 проверок выполняются на удалённой стороне
        ok=$(ssh "$user@$ip" "
            ok=0
            for i in \$(seq $ATTEMPTS); do
                timeout 5 openssl s_client -connect $h:443 -servername $h -tls1_3 -alpn h2 </dev/null 2>&1 \
                    | grep -q 'TLSv1.3' && ok=\$((ok+1))
            done
            echo \$ok
        ")

        t1=$(date +%s.%N)
        elapsed=$(echo "$t1 - $t0" | bc)

        # Нормализуем ok (на случай ошибки ssh)
        [[ "$ok" =~ ^[0-9]+$ ]] || ok=0

        # Резолвим IP локально
        ips=$(getent ahosts "$h" | awk '{print $1}' | sort -u | head -3 | tr '\n' ' ')

        # Пишем результат в отдельный файл (безопасно при параллельной записи)
        printf '%s\t%s\t%s\t%s\n' "$h" "$ok" "$elapsed" "$ips" > "$TMPDIR_RESULTS/$h"
    ) &
done

# Ждём завершения всех фоновых задач
wait

# Печатаем результаты в исходном порядке HOSTS
printf '%-24s count  time  IP\n' 'host'
for h in "${HOSTS[@]}"; do
    f="$TMPDIR_RESULTS/$h"
    if [[ -f "$f" ]]; then
        IFS=$'\t' read -r host ok elapsed ips < "$f"
        printf '%-24s %2d/%d  %.1fs  IP: %s\n' "$host" "$ok" "$ATTEMPTS" "$elapsed" "$ips"
    else
        printf '%-24s  --/%d  --    IP: (нет результата)\n' "$h" "$ATTEMPTS"
    fi
done