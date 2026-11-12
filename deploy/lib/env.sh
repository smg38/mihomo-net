#!/bin/bash
# =============================================================================
# deploy/lib/env.sh — единый парсер dotenv (данные, не shell).
# Версия: 3.3.0 2026-11-07
# Правила:
#   KEY=value            — значение до конца строки, inline "# ..." срезается
#   KEY="value"          — двойные кавычки: \n \t \" \\ \$ раскрываются,
#                          "${VAR}" / "$VAR" подставляются, '#' — часть значения
#   KEY='value'          — одинарные кавычки: всё буквально, включая '#' и $VAR
#   export KEY=value     — эквивалентно KEY=value
#   # ...                — комментарий целиком
#   пустая строка        — пропуск
#
# Подстановка ${VAR} и $VAR ищет переменную сначала среди уже загруженных
# ключей этого файла, затем в окружении. Поддерживаются ${VAR}, ${VAR:-d},
# ${VAR-d}, ${VAR:=d}, ${VAR=}, ${VAR:?msg}, ${VAR:?}, ${VAR:+alt}, ${VAR+alt}.
#
# Значения остаются данными: $(...), `...`, ;, |, &, > не исполняются.
# =============================================================================

# --- Вспомогательная: вырезать "${NAME}"/"$NAME" в строке -------------------
# $1 — строка, $2 — имя переменной; печатает результат в stdout.
_env_substitute_vars() {
    local input="$1"
    local out="" i=0 n=${#input}
    local ch next name op arg repl

    while (( i < n )); do
        ch="${input:i:1}"
        if [[ "$ch" != '$' ]]; then
            out+="$ch"
            (( i++ ))
            continue
        fi

        next="${input:i+1:1}"

        # ${NAME}, ${NAME:-d}, ${NAME-d}, ${NAME:=d}, ${NAME:?m}, ${NAME:+a}
        if [[ "$next" == "{" ]]; then
            local rest="${input:i+2}"
            # NAME — [A-Za-z_][A-Za-z0-9_]*
            if [[ "$rest" =~ ^([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; then
                name="${BASH_REMATCH[1]}"
                local tail="${BASH_REMATCH[2]}"
                op=""
                # Найти оператор до закрывающей }
                if [[ "$tail" == :* ]]; then
                    # ":op" — двоеточие уже в tail
                    if [[ "$tail" =~ ^:([-=+?])(.*)$ ]]; then
                        op=":${BASH_REMATCH[1]}"
                        arg="${BASH_REMATCH[2]}"
                    fi
                elif [[ "$tail" =~ ^([-=+?])(.*)$ ]]; then
                    op="${BASH_REMATCH[1]}"
                    arg="${BASH_REMATCH[2]}"
                else
                    # просто ${NAME}
                    if [[ "$tail" == "}"* ]]; then
                        # переменная уже могла быть загружена — берём из env
                        if [[ -n "${!name+set}" ]]; then
                            repl="${!name}"
                        else
                            repl=""
                        fi
                        out+="$repl"
                        # пропустить "${NAME}" (i + 2 + len(name) + 1)
                        (( i += 2 + ${#name} + 1 ))
                        continue
                    fi
                fi

                if [[ -n "$op" ]]; then
                    # Отделить arg от закрывающей }
                    local argvalue="$arg"
                    # arg заканчивается на '}...' — обрезаем до первого '}'
                    if [[ "$argvalue" == *"}"* ]]; then
                        argvalue="${argvalue%%\}*}"
                    fi

                    local cur=""
                    if [[ -n "${!name+set}" ]]; then
                        cur="${!name}"
                    fi

                    case "$op" in
                        ":-") [[ -n "$cur" ]] && repl="$cur" || repl="$argvalue" ;;
                        "-")  [[ -n "${!name+set}" ]] && repl="$cur" || repl="$argvalue" ;;
                        ":=") if [[ -z "$cur" ]]; then
                                  printf -v "$name" '%s' "$argvalue"
                                  export "${name?}"
                                  repl="$argvalue"
                              else repl="$cur"; fi ;;
                        "=")  if [[ -z "${!name+set}" ]]; then
                                  printf -v "$name" '%s' "$argvalue"
                                  export "${name?}"
                                  repl="$argvalue"
                              else repl="$cur"; fi ;;
                        ":?") [[ -n "$cur" ]] && repl="$cur" || {
                                  printf '[env] ${%s:?%s}\n' "$name" "${argvalue:-variable is not set}" >&2
                                  return 1
                              } ;;
                        "?")  [[ -n "${!name+set}" ]] && repl="$cur" || {
                                  printf '[env] ${%s?%s}\n' "$name" "${argvalue:-variable is not set}" >&2
                                  return 1
                              } ;;
                        ":+") [[ -n "$cur" ]] && repl="$argvalue" || repl="" ;;
                        "+")  [[ -n "${!name+set}" ]] && repl="$argvalue" || repl="" ;;
                    esac

                    out+="$repl"
                    # пропустить: "${" + name + op + argvalue + "}"
                    local consumed=$(( 2 + ${#name} + ${#op} + ${#argvalue} + 1 ))
                    (( i += consumed ))
                    continue
                fi
            fi
            # Не ${NAME...} — оставляем "${" как есть, чтобы не съесть скобку
            out+='${'
            (( i += 2 ))
            continue
        fi

        # $NAME — только если следующий символ — буква/подчёркивание
        if [[ "$next" =~ [A-Za-z_] ]]; then
            local rest="${input:i+1}"
            if [[ "$rest" =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]; then
                name="${BASH_REMATCH[1]}"
                if [[ -n "${!name+set}" ]]; then
                    repl="${!name}"
                else
                    repl=""
                fi
                out+="$repl"
                (( i += 1 + ${#name} ))
                continue
            fi
        fi

        # Одиночный $ — оставить как есть
        out+='$'
        (( i++ ))
    done

    printf '%s' "$out"
}

# --- Развернуть \n \t \" \\ \$ в double-quoted значении --------------------
_env_unescape_dq() {
    local s="$1"
    s="${s//\\n/$'\n'}"
    s="${s//\\t/$'\t'}"
    s="${s//\\\"/\"}"
    s="${s//\\\$/\$}"
    s="${s//\\\\/\\}"
    printf '%s' "$s"
}

# --- Срезать inline-комментарий у некавыченного значения -------------------
# FOO=bar # comment   -> bar
# FOO=bar#baz         -> bar#baz (без пробела перед # — часть значения)
# FOO=bar    #comment -> bar
_env_strip_inline_comment() {
    local v="$1"
    if [[ "$v" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then
        v="${BASH_REMATCH[1]}"
    elif [[ "$v" =~ ^([^[:space:]]+)[[:space:]]+#.*$ ]]; then
        v="${BASH_REMATCH[1]}"
    fi
    # Убрать хвостовые пробелы
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# --- Загрузить dotenv -------------------------------------------------------
load_env_file() {
    local env_file="$1"
    if [ ! -f "$env_file" ]; then
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        # Убрать CR (Windows-файлы)
        line="${line%$'\r'}"
        # Убрать внешние пробелы
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue

        local key=""
        local value=""
        local quoted=""   # "", "dq", "sq"

        if [[ "$line" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        fi

        if [ -n "$key" ]; then
            # Внешние пробелы значения
            value="${value#"${value%%[![:space:]]*}"}"

            if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
                quoted="dq"
                value="${value:1:${#value}-2}"
            elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
                quoted="sq"
                value="${value:1:${#value}-2}"
            fi

            case "$quoted" in
                sq)
                    # Всё буквально, включая '#' и $VAR.
                    ;;
                dq)
                    # \n \t \" \\ \$ — раскрыть, затем подставить ${VAR}/$VAR.
                    value=$(_env_unescape_dq "$value")
                    value=$(_env_substitute_vars "$value") || return 1
                    ;;
                "")
                    # Без кавычек: сначала срезать inline-комментарий,
                    # затем подставить ${VAR}/$VAR.
                    value=$(_env_strip_inline_comment "$value")
                    value=$(_env_substitute_vars "$value") || return 1
                    ;;
            esac

            printf -v "$key" '%s' "$value"
            export "${key?}"
        fi
    done < "$env_file"

    return 0
}

# Проверяет конфигурацию, в которой значения должны быть буквальными.
# Используется для params.env и файлов экземпляров: наследование выполняется
# через порядок загрузки файлов, а не через подстановки внутри значений.
validate_env_file_literal() {
    local env_file="$1" line value number=0 interpolation_re='\$[A-Za-z_{(]'
    [ -f "$env_file" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        ((number+=1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=(.*)$ ]] || continue
        value="${BASH_REMATCH[2]}"
        value="${value#"${value%%[![:space:]]*}"}"
        if [[ "$value" != \"*\" && "$value" != \'*\' ]]; then
            value=$(_env_strip_inline_comment "$value")
        fi
        if [[ "$value" =~ $interpolation_re ]]; then
            printf '[env] %s:%d: подстановка переменных запрещена; укажите буквальное значение\n' \
                "$env_file" "$number" >&2
            return 2
        fi
    done < "$env_file"

    return 0
}

# Загружает файл только после проверки, что его значения буквальные.
load_env_file_literal() {
    local env_file="$1"
    validate_env_file_literal "$env_file" || return $?
    load_env_file "$env_file"
}

validate_d_instance_file() {
    local file="$1" line name
    local allowed=' IP_D PORT_D DNS_PORT DIR_D ARCH_D SECRET_KEY_D GEO_MODE TUNNEL_C_HOST TUNNEL_C_USER TUNNEL_C_PORT TUNNEL_REMOTE_PORT TUNNEL_KEY CN_CIDR_URL RU_CIDR_URL GEOSITE_URL GEOIP_METADB_URL '
    validate_env_file_literal "$file" || return $?
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        name="${BASH_REMATCH[2]}"
        if [[ "$allowed" != *" $name "* ]]; then
            printf '[instances] %s: неизвестный параметр %s\n' "$file" "$name" >&2
            return 2
        fi
    done < "$file"
}

# Найденные переменные парсятся и экспортируются в текущее окружение.
# $1 — файл, $2 — имя или glob-шаблон ключа
# Экспортирует найденные переменные и печатает KEY=value.
env_get() {
    local file="$1" pattern="$2" found=0 line key value q
    [ -f "$file" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[2]}"; value="${BASH_REMATCH[3]}"
        [[ "$key" == $pattern ]] || continue

        value="${value#"${value%%[![:space:]]*}"}"
        q=""
        [[ "$value" == \"*\" && ${#value} -ge 2 ]] && { q=dq; value="${value:1:${#value}-2}"; }
        [[ "$value" == \'*\' && ${#value} -ge 2 ]] && { q=sq; value="${value:1:${#value}-2}"; }

        case "$q" in
            sq) ;;
            dq) value=$(_env_unescape_dq "$value"); value=$(_env_substitute_vars "$value") || return 1 ;;
            "") value=$(_env_strip_inline_comment "$value"); value=$(_env_substitute_vars "$value") || return 1 ;;
        esac

        printf -v "$key" '%s' "$value"; export "${key?}"
        printf '%s=%s\n' "$key" "$value"
        found=1
    done < "$file"

    (( found ))
}