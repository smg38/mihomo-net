#!/bin/bash
#Сценарий выпуска — зондирование цели, локальная кросс-компиляция и развертывание на удаленном компьютере. systemd
#
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
source ./deploy/lib/target.sh
source ./deploy/lib/env.sh

# определение цвета
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # нет цвета

# функция журнала
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    printf 'использование: mise run publish -- [--build-only | --force]\n'
    printf '  --build-only  Обнаруживать цели и выполнять сборку только локально.\n'
    printf '  --force       Сохраните старый пакет восстановления, пропустите автоматическое восстановление невыпущенной версии и выполните переустановку.\n'
}

BUILD_ONLY=false
FORCE_INSTALL=false
case "${1:-}" in
    "") ;;
    --build-only) BUILD_ONLY=true ;;
    --force) FORCE_INSTALL=true ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || { log_error "Слишком много параметров"; exit 1; }

handle_error() {
    log_error "$1"
    exit 1
}

# В удаленных командах используются одинарные кавычки стандарта POSIX, что обеспечивает совместимость с серверами, где в качестве командной оболочки для входа в систему используется `sh`.
quote_shell() {
    # Bash 3.2 interprets literal replacement backslashes differently from 5.x.
    local escaped="'\\''"
    printf "'%s'" "${1//\'/$escaped}"
}

load_env_file .env || handle_error "Не найдено .env ，пожалуйста создайте из .env.template"
[[ "${REMOTE_USER:-}" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || handle_error "REMOTE_USER 无效"
[[ "${REMOTE_HOST:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] || handle_error "REMOTE_HOST 无效"
[[ "${REMOTE_DIR:-}" == /* && "$REMOTE_DIR" != / && "$REMOTE_DIR" != *$'\n'* ]] || handle_error "REMOTE_DIR Должен быть абсолютный путь к некорневому каталогу."
for cmd in ssh tar mise; do
    command -v "$cmd" >/dev/null || handle_error "Отсутствует локальная команда: $cmd"
done
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)
remote="${REMOTE_USER}@${REMOTE_HOST}"
remote_dir=$(quote_shell "$REMOTE_DIR")

# Проверка только для чтения выполняется перед созданием удаленного каталога, загрузкой файлов или операцией службы.
log_info "Обнаружение удаленной операционной системы, архитектуры ЦП, ядра и systemd..."
probe=$("${SSH[@]}" "$remote" 'sh -s' <<'REMOTE'
set -eu
for cmd in bash tar sha256sum systemctl flock sudo; do
    command -v "$cmd" >/dev/null || { echo "Отсутствует удаленная команда: $cmd" >&2; exit 1; }
done
[ -d /run/systemd/system ] || { echo "Удаленный конец не работает systemd" >&2; exit 1; }
printf '%s|%s|%s\n' "$(uname -s)" "$(uname -m)" "$(uname -r)"
REMOTE
) || handle_error "Не удалось обнаружить удаленную среду"
IFS='|' read -r target_os target_machine target_kernel <<< "$probe"
configure_target "$target_os" "$target_machine" "$target_kernel" || handle_error "Удаленная среда не поддерживается"
target_description="Цель: ${TARGET_GOOS}/${TARGET_GOARCH}, ядро ${target_kernel}"
if [ "$TARGET_GOARCH" = arm ]; then target_description="${target_description}，GOARM=$TARGET_GOARM"; fi
log_info "$target_description"

mkdir -p .tmp
build_dir=$(mktemp -d "$PWD/.tmp/deploy.XXXXXX")
cleanup() { rm -rf "$build_dir"; }
trap cleanup EXIT
artifact="$PWD/.tmp/mihomo-manager-$TARGET_GOOS-$TARGET_GOARCH"
[ "$TARGET_GOARCH" != arm ] || artifact="$artifact-${TARGET_GOARM%%,*}"
log_info "Использовать mise управление Go в локальной кросс-компиляции..."
# Явно ограничьте набор команд, чтобы избежать наследования параметров оптимизации производительности машины разработки.

# mise exec -- env GOTOOLCHAIN=local CGO_ENABLED=0 GOOS="$TARGET_GOOS" GOARCH="$TARGET_GOARCH" \
#     GOAMD64=v1 GOARM64=v8.0 GOARM="$TARGET_GOARM" GO386=softfloat \
#     go build -trimpath -ldflags "-w -s" -o "$build_dir/mihomo-manager" ./cmd/mihomo-manager || handle_error "Локальная кросс-компиляция не удалась"
env GOTOOLCHAIN=local CGO_ENABLED=0 GOOS="$TARGET_GOOS" GOARCH="$TARGET_GOARCH" \
    GOAMD64=v1 GOARM64=v8.0 GOARM="$TARGET_GOARM" GO386=softfloat \
    go build -trimpath -ldflags "-w -s" -o "$build_dir/mihomo-manager" ./cmd/mihomo-manager \
    || handle_error "локальная кросс-компиляция не удалась"
cp "$build_dir/mihomo-manager" "$artifact"
log_info "Сборка завершена: $artifact"
if [ "$BUILD_ONLY" = true ]; then
    exit 0
fi

# deploy/ Единственный манифест файла времени выполнения; страница управления распространяется вместе с двоичным файлом.
cp -R deploy/. "$build_dir/"
LOCAL_FILES=(install.sh release.sh scripts lib systemd mihomo-manager)
if command -v shasum >/dev/null; then
    (cd "$build_dir" && shasum -a 256 mihomo-manager > mihomo-manager.sha256)
else
    (cd "$build_dir" && sha256sum mihomo-manager > mihomo-manager.sha256)
fi
LOCAL_FILES+=(mihomo-manager.sha256)
# Существующая частная конфигурация удаленного конца будет по-прежнему поддерживаться удаленным концом.
if "${SSH[@]}" "$remote" "test -f $remote_dir/.env"; then
    log_info "Сохраняйте пульт существующим .env"
else
    env_check_rc=$?
    [ "$env_check_rc" -eq 1 ] || handle_error "Проверка удаленного .env не удалась"
    cp .env "$build_dir/.env"
    LOCAL_FILES+=(.env)
fi

log_info "Загрузите файлы времени выполнения и менеджер предварительной компиляции...."
remote_stage=$("${SSH[@]}" "$remote" "mkdir -p $remote_dir && mktemp -d $remote_dir/.deploy.XXXXXX") || handle_error "Невозможно создать удаленный промежуточный каталог"
[[ "$remote_stage" == "$REMOTE_DIR"/.deploy.* && "$remote_stage" != *$'\n'* ]] || handle_error "Удаленный конец возвращает недопустимый временный каталог."
stage_dir=$(quote_shell "$remote_stage")
if ! COPYFILE_DISABLE=1 tar --format=ustar -C "$build_dir" -cf - "${LOCAL_FILES[@]}" | "${SSH[@]}" "$remote" "umask 077; tar -xf - -C $stage_dir"; then
    "${SSH[@]}" "$remote" "rm -rf $stage_dir" || true
    handle_error "Загрузка не удалась, установка не выполнена"
fi

log_info "Проверьте продукт передачи и установите его..."
if [ "$FORCE_INSTALL" = true ]; then
    log_info "Принудительная установка: сохраните старые пакеты восстановления и пропустите автоматическое восстановление незавершенных версий."
fi
download_terminal=0
[ ! -t 2 ] || download_terminal=1
"${SSH[@]}" "$remote" "bash -s -- $remote_dir $stage_dir $download_terminal $FORCE_INSTALL" <<'REMOTE'
set -euo pipefail
umask 077
deploy_dir="$1"
stage_dir="$2"
export MIHOMO_DOWNLOAD_TERMINAL="$3"
force_install="$4"
case "$force_install" in true|false) ;; *) exit 1 ;; esac
trap 'rm -rf "$stage_dir"' EXIT
cd "$stage_dir"
sha256sum -c mihomo-manager.sha256
# Сначала убедитесь, что целевой объект является исполняемым, и сохраните существующие файлы времени выполнения в случае сбоя.
./mihomo-manager --version
if [ -f "$deploy_dir/.env" ]; then cp "$deploy_dir/.env" .env; fi
[ -f .env ] || { echo 'Отсутствует конфигурация среды развертывания.' >&2; exit 1; }
chmod +x install.sh release.sh scripts/update.sh scripts/entrypoint.sh
# release.sh owns cleanup and keeps the recovery package when compensation fails.
trap - EXIT
if [ "$force_install" = true ]; then
    ./release.sh "$deploy_dir" "$stage_dir" --force
else
    ./release.sh "$deploy_dir" "$stage_dir"
fi
REMOTE
log_info "Сборка завершена"
