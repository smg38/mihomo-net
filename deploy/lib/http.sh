#!/bin/bash
# Единственная реализация HTTP-загрузки: источники-кандидаты, независимый DNS, общий лимит времени и атомарная запись.
# DOWNLOAD_DOH_SERVERS — разделённые пробелами host:bootstrap-IP; пустое значение отключает внешний DoH.
# Не читает curlrc, не использует HTTP-прокси из окружения; прозрачный прокси всё ещё определяется правилами хост-сети.
# Передаёт только кадры прогресса curl; исходные ошибки не смешиваются с индикатором прогресса, унифицированный журнал сообщает код ошибки.
_http_progress_filter() {
    local frame shown=false allowed='^[[:space:]0-9.#%=O<>-]+$'
    while IFS= read -r -d $'\r' frame || [ -n "$frame" ]; do
        frame="${frame//$'\n'/}"
        case "$frame" in
            *%*|*'#'*|*'=O'*|*'O='*)
                if [[ "$frame" =~ $allowed ]]; then
                    printf '\r%s' "$frame" >&2
                    shown=true
                fi ;;
        esac
    done
    [ "$shown" != true ] || printf '\n' >&2
    return 0
}

_http_transfer() {
    local progress="$1" rc=0
    shift
    if [ "$progress" = true ]; then
        # Конвейер опустошает прогресс перед возвратом; PIPESTATUS сохраняет сбои curl
        # даже если pipefail не включён вызывающей стороной.
        if curl --disable --progress-bar "$@" 2>&1 | _http_progress_filter; then
            rc=${PIPESTATUS[0]}
        else
            rc=${PIPESTATUS[0]}
        fi
    else
        if curl --disable --silent "$@" 2>/dev/null; then rc=0; else rc=$?; fi
    fi
    return "$rc"
}

# Подсказка маршрутизации, а не кэшированные ответы DNS. Межпроцессное повторное использование сохраняет TTL DNS.
_http_remember_dns() (
    umask 077
    local state="$1" resolver="$2" pending
    mkdir -p "$state" && chmod 0700 "$state" || return 1
    pending=$(mktemp "$state/.download-dns.XXXXXX") || return 1
    trap 'rm -f "$pending"' EXIT
    printf '%s\n' "$resolver" > "$pending" && mv -f "$pending" "$state/download-dns"
)

http_download() (
    local output="$1" budget="$2" max_bytes="$3"
    shift 3
    [[ "$budget" =~ ^[1-9][0-9]*$ && "$max_bytes" =~ ^[1-9][0-9]*$ ]] && [ "$#" -gt 0 ] || return 2
    local configured=() resolvers=() modes=(system) resolver host ip
    read -r -a configured <<< "${DOWNLOAD_DOH_SERVERS-dns.alidns.com:223.5.5.5 cloudflare-dns.com:1.1.1.1}"
    # Bash 3.2 + nounset считает пустой массив неустановленным; сохраняем нулевые аргументы.
    for resolver in ${configured[@]+"${configured[@]}"}; do
        host="${resolver%%:*}"; ip="${resolver#*:}"
        if [[ ! "$host" =~ ^[a-zA-Z0-9.-]+$ || "$resolver" != *:* || ! "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
            printf '[Загрузка] Недопустимая конфигурация bootstrap DoH\n' >&2
            return 2
        fi
        case " ${resolvers[*]-} " in *" $resolver "*) ;; *) resolvers+=("$resolver") ;; esac
    done
    local progress=false
    case "${DOWNLOAD_PROGRESS:-auto}" in
        auto) if [ -t "${MIHOMO_DOWNLOAD_TERMINAL_FD:-2}" ] || [ "${MIHOMO_DOWNLOAD_TERMINAL:-0}" = 1 ]; then progress=true; fi ;;
        bar) progress=true ;;
        off) ;;
        *) printf '[Загрузка] DOWNLOAD_PROGRESS должен быть auto, bar или off\n' >&2; return 2 ;;
    esac
    local state="${MIHOMO_SOURCE_DIR:-$PWD}/.update-state" cached="" preferred=""
    if [ -f "$state/download-dns" ]; then IFS= read -r -n 512 cached < "$state/download-dns" || true; fi
    for resolver in system ${resolvers[@]+"${resolvers[@]}"}; do
        if [ "$cached" = "$resolver" ]; then preferred="$cached"; break; fi
    done
    if [ -n "$preferred" ]; then
        modes=("$preferred")
        for resolver in system ${resolvers[@]+"${resolvers[@]}"}; do
            [ "$resolver" = "$preferred" ] || modes+=("$resolver")
        done
    else modes+=(${resolvers[@]+"${resolvers[@]}"})
    fi
    local pending
    pending=$(mktemp "${output}.http.XXXXXX") || return 1
    trap 'rm -f "$pending"' EXIT
    local deadline=$((SECONDS + budget)) attempts_left=$(($# * ${#modes[@]}))
    local remaining attempt_timeout url log_url mode rc bytes redirect_protocols
    local dns_args=() header_args=()
    if [ -n "${HTTP_DOWNLOAD_HEADERS_FILE:-}" ]; then header_args=(--header "@${HTTP_DOWNLOAD_HEADERS_FILE}"); fi
    for url in "$@"; do
        case "$url" in
            https://*) redirect_protocols='=https' ;;
            http://*) redirect_protocols='=http,https' ;;
            *) printf '[Загрузка] Поддерживаются только источники HTTP/HTTPS\n' >&2; return 2 ;;
        esac
        # Сохраняем полный URL владельца; удаляем только управляющие символы терминала.
        log_url="${url//[[:cntrl:]]/}"
        printf '[Загрузка] %s（начало）\n' "$log_url" >&2
        # Приоритетное повторное использование успешного способа; после сбоя всё ещё尝试 остальные, без дублирования предпочтительного.
        for resolver in "${modes[@]}"; do
            remaining=$((deadline - SECONDS))
            [ "$remaining" -gt 0 ] || return 1
            if [ "$resolver" = "$preferred" ]; then
                # Известный рабочий маршрут получает оставшийся бюджет передачи. Ограничения
                # соединения/низкой скорости всё ещё быстро отбрасывают устаревшие маршруты.
                attempt_timeout="$remaining"
            else
                attempt_timeout=$((remaining / attempts_left))
            fi
            [ "$attempt_timeout" -gt 0 ] || attempt_timeout=1
            attempts_left=$((attempts_left - 1))
            dns_args=()
            mode="Системный DNS"
            if [ "$resolver" != system ]; then
                host="${resolver%%:*}"; ip="${resolver#*:}"
                [[ "$ip" != *:* ]] || ip="[$ip]"
                dns_args=(--doh-url "https://${host}/dns-query" --resolve "${host}:443:${ip}")
                mode="DoH $host"
            fi
            # libcurl также использует DoH для хоста после перенаправления; оба уровня TLS сохраняют проверку по умолчанию.
            # Исходные ошибки не смешиваются с индикатором прогресса, при сбое унифицированно сообщается URL, код ошибки и способ разрешения.
            if _http_transfer "$progress" --noproxy '*' --fail --location --max-redirs 5 \
                --proto '=http,https' --proto-redir "$redirect_protocols" --compressed \
                --connect-timeout 5 --max-time "$attempt_timeout" \
                --speed-limit 1024 --speed-time 15 --max-filesize "$max_bytes" \
                ${dns_args[@]+"${dns_args[@]}"} ${header_args[@]+"${header_args[@]}"} --output "$pending" --url "$url"; then
                bytes=$(wc -c < "$pending") || return 1
                if [ "$bytes" -gt 0 ] && [ "$bytes" -le "$max_bytes" ]; then
                    mv -f "$pending" "$output" || return 1
                    printf '[Загрузка] %s（завершено，%d байт）\n' "$log_url" "$bytes" >&2
                    if ! _http_remember_dns "$state" "$resolver" 2>/dev/null; then
                        printf '[Загрузка] %s（предупреждение：не удалось сохранить запись предпочтения DNS）\n' "$log_url" >&2
                    fi
                    return 0
                fi
                rc="Файл пуст или превышает ограничение размера"
            else
                rc="curl $?"
            fi
            printf '[Загрузка] %s（сбой запроса，%s；разрешение：%s）\n' "$log_url" "$rc" "$mode" >&2
        done
    done
    return 1
)

# Префикс прокси применяется только к публичным URL GitHub; подписка не меняет источник.
github_download() {
    local output="$1" budget="$2" max_bytes="$3" prefix="$4" url="$5"
    if [ -n "$prefix" ]; then
        http_download "$output" "$budget" "$max_bytes" "${prefix%/}/$url" "$url"
    else
        http_download "$output" "$budget" "$max_bytes" "$url"
    fi
}