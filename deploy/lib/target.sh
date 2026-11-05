#!/bin/bash
# Общий контракт целевой Linux-среды для публикации и установки; source этого файла не выполняет обнаружение и не изменяет систему.
# Возвращаемое значение читается вызывающим скриптом.
# shellcheck disable=SC2034
configure_target() {
    local os="$1" machine="$2" kernel="$3"
    TARGET_GOOS=linux
    TARGET_GOARCH=""
    TARGET_GOARM=5,softfloat
    [ "$os" = Linux ] || { echo "Поддерживается только Linux/systemd, фактическая система: $os" >&2; return 1; }
    if [[ ! "$kernel" =~ ^([0-9]+)\.([0-9]+) ]]; then
        echo "Не удалось разобрать версию ядра Linux: $kernel" >&2
        return 1
    fi
    if (( BASH_REMATCH[1] < 3 || (BASH_REMATCH[1] == 3 && BASH_REMATCH[2] < 2) )); then
        echo "Менеджеру Go требуется ядро Linux 3.2 или новее: $kernel" >&2
        return 1
    fi
    case "$machine" in
        x86_64|amd64) TARGET_GOARCH=amd64 ;;
        aarch64|arm64) TARGET_GOARCH=arm64 ;;
        armv7l) TARGET_GOARCH=arm; TARGET_GOARM=7,softfloat ;;
        armv6l) TARGET_GOARCH=arm; TARGET_GOARM=6,softfloat ;;
        i386|i486|i586|i686) TARGET_GOARCH=386 ;;
        *) echo "Неподдерживаемая целевая архитектура: $machine" >&2; return 1 ;;
    esac
}