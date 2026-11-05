#!/bin/bash
# Выбор активов выпуска и проверка целостности. amd64 всегда использует базовую линию v1, не сортирует по имени.
core_release_version() {
    local banner="${1%%$'\n'*}"
    # Только токены стабильной версии квалифицируются. Alpha/пользовательские баннеры не могут сравниться как равные.
    if [[ "$banner" =~ ^Mihomo(\ Meta)?\ (v[0-9]+\.[0-9]+\.[0-9]+)[[:space:]] ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
    else
        return 1
    fi
}

select_core_asset() {
    local metadata="$1" version="$2" os="$3" arch="$4" arm="$5" name
    case "$arch" in
        amd64) name="mihomo-${os}-amd64-v1-${version}.gz" ;;
        arm) name="mihomo-${os}-armv${arm%%,*}-${version}.gz" ;;
        *) name="mihomo-${os}-${arch}-${version}.gz" ;;
    esac
    if jq -e --arg name "$name" '.assets | any(.name == $name)' "$metadata" >/dev/null; then
        printf '%s\n' "$name"
    elif [ "$arch" = amd64 ]; then
        name="mihomo-${os}-amd64-${version}.gz"
        jq -e --arg name "$name" '.assets | any(.name == $name)' "$metadata" >/dev/null || return 1
        printf '%s\n' "$name"
    else
        return 1
    fi
}

asset_sha256() {
    jq -er --arg name "$2" '.assets[] | select(.name == $name) | .digest | select(type == "string" and test("^sha256:[a-fA-F0-9]{64}$")) | ltrimstr("sha256:") | ascii_downcase' "$1"
}

verify_asset() {
    local expected="$1" file="$2" actual
    # Хэшируем stdin, чтобы маркер экранированного имени файла GNU не стал частью дайджеста.
    if command -v sha256sum >/dev/null; then actual=$(sha256sum < "$file") || return 1; actual="${actual%% *}"
    elif command -v shasum >/dev/null; then actual=$(shasum -a 256 < "$file") || return 1; actual="${actual%% *}"
    else return 1
    fi
    [ "$actual" = "$expected" ]
}