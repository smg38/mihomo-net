#!/bin/bash
# =============================================================================
# scripts/lib/yaml.sh — единые YAML-парсеры для check-keys-sync.sh и diagnose.sh
# Версия: 3.2.0   2026-11-5
# Автор: @smg38
# Все функции читают файл построчно через awk и НЕ исполняют его.
# Никаких зависимостей от yq (работает и на серверах без yq, и локально).
#
# Использование:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/lib/yaml.sh"
# =============================================================================

# yaml_get <file> <top-level-field>
# Верхнеуровневое поле (в начале строки, без отступа). Возвращает первое вхождение.
yaml_get() {
    local file="$1" field="$2"
    [[ -f "$file" ]] || return 0
    awk -v fld="$field" '
        $0 ~ "^[[:space:]]*"fld":" {
            v=$0
            sub("^[[:space:]]*"fld":[[:space:]]*", "", v)
            gsub(/^[[:space:]"]+/, "", v)
            gsub(/[[:space:]"]+$/, "", v)
            print v
            exit
        }
    ' "$file"
}

# yaml_get_in_block <file> <trigger-regex> <field>
# Поле field внутри блока, начатого строкой, матчащей trigger-regex.
# Завершается на следующем "- name:" или "- username:".
yaml_get_in_block() {
    local file="$1" trigger="$2" field="$3"
    [[ -f "$file" ]] || return 0
    awk -v trg="$trigger" -v fld="$field" '
        $0 ~ trg { armed=1; next }
        armed && /^[[:space:]]*-[[:space:]]+(name|username):/ { exit }
        armed && $0 ~ "^[[:space:]]*"fld":" {
            v=$0
            sub("^[[:space:]]*"fld":[[:space:]]*", "", v)
            gsub(/^[[:space:]"]+/, "", v)
            gsub(/[[:space:]"]+$/, "", v)
            print v
            exit
        }
    ' "$file"
}

# yaml_user_uuid <file> <username>
# UUID из блока users с username=<username>.
# Блок заканчивается на следующем "- username:" (с отступом).
yaml_user_uuid() {
    local file="$1" user="$2"
    [[ -f "$file" ]] || return 0
    awk -v u="$user" '
        $0 ~ "username:[[:space:]]*"u"([[:space:]]|$)" { armed=1; next }
        armed && /^[[:space:]]*-[[:space:]]+username:/ { exit }
        armed && /^[[:space:]]*uuid:/ {
            v=$0
            sub(/^[[:space:]]*uuid:[[:space:]]*/, "", v)
            gsub(/[[:space:]"]/, "", v)
            print v
            exit
        }
    ' "$file"
}

# yaml_proxy_field <file> <proxy-name> <field>
# Поле field в proxy с name=<proxy-name> (значение name в кавычках или без).
# Блок заканчивается на следующем "  - name:".
yaml_proxy_field() {
    local file="$1" name="$2" field="$3"
    [[ -f "$file" ]] || return 0
    awk -v n="$name" -v f="$field" '
        $0 ~ "name:[[:space:]]*\"?"n"\"?[[:space:]]*$" { armed=1; next }
        armed && /^  - name:/ { exit }
        armed && $0 ~ "^[[:space:]]*"f":[[:space:]]*" {
            v=$0
            sub("^[[:space:]]*"f":[[:space:]]*", "", v)
            gsub(/^[[:space:]"]+/, "", v)
            gsub(/[[:space:]"]+$/, "", v)
            print v
            exit
        }
    ' "$file"
}

# yaml_server_names <file>
# Первое значение в server-names: (с учётом "- " элементов списка).
yaml_server_names() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    awk '/server-names:/{f=1;next}
         f && /^[[:space:]]*-[[:space:]]/{
             v=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); gsub(/[[:space:]"]/, "", v)
             print v; exit
         }' "$file"
}

# yaml_short_id_listener <file>
# Первое значение в short-id: (с учётом "- " элементов списка).
yaml_short_id_listener() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    awk '/short-id:/{f=1;next}
         f && /^[[:space:]]*-[[:space:]]/{
             v=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); gsub(/[[:space:]"]/, "", v)
             print v; exit
         }' "$file"
}