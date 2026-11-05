#!/bin/bash
# Все загрузки и проверки выполняются в --prepare; --apply только устанавливает уже подготовленный пакет времени выполнения.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
source ./lib/target.sh
source ./lib/env.sh
source ./lib/http.sh
source ./lib/release.sh

info() { printf '[info] %s\n' "$1"; }
warn() { printf '[warn] %s\n' "$1" >&2; }
error() { printf '[error] %s\n' "$1" >&2; exit 1; }
[ "$#" -eq 2 ] && [[ "$2" == /* ]] || error 'Использование: install.sh --prepare|--apply /абсолютный/путь/к/prebuilt-manager'
PREPARED_DIR="${MIHOMO_PREPARED_DIR:-$PWD/.release}"
MODE="$1"
MANAGER_BINARY="$2"
FORCE_CORE_INSTALL="${MIHOMO_FORCE_CORE_INSTALL:-false}"
case "$FORCE_CORE_INSTALL" in true|false) ;; *) error 'Недопустимый параметр принудительной установки ядра' ;; esac
case "$MODE" in --prepare|--apply) ;; *) error 'Недопустимая стадия установки' ;; esac
[ -x "$MANAGER_BINARY" ] && [ -f "$MANAGER_BINARY" ] || error 'Отсутствует исполняемый менеджер, перезапустите mise run publish'
configure_target "$(uname -s)" "$(uname -m)" "$(uname -r)" || error 'Целевая среда не поддерживается'
version=$("$MANAGER_BINARY" --version) || error 'Менеджер не может работать в целевой среде'
[[ "$version" == mihomo-manager\ go*\ "$TARGET_GOOS/$TARGET_GOARCH" ]] || error 'Несовпадение архитектуры или версии менеджера'
info "Менеджер успешно проверен: $version"
for cmd in curl jq sudo tar nft install mktemp systemctl gzip cmp; do
    command -v "$cmd" >/dev/null || error "Отсутствует зависимость времени выполнения: $cmd"
done
command -v sha256sum >/dev/null || command -v shasum >/dev/null || error 'Отсутствует инструмент проверки SHA256'
load_env_file .env || error 'В пакете времени выполнения отсутствует .env'
for file in scripts/update.sh scripts/entrypoint.sh systemd/mihomo.service.in systemd/mihomo-manager.service.in; do
    [ -f "$file" ] || error "В пакете времени выполнения отсутствует $file"
done
chmod +x scripts/update.sh scripts/entrypoint.sh

prepare_core() {
    local current="/usr/local/bin/mihomo" current_version="" current_tag="" metadata="$PREPARED_DIR/latest.json" latest name expected
    # Служба использует именно этот путь; теневой PATH не должен определять её версию.
    if [ ! -x "$current" ]; then current=$(command -v mihomo || true); fi
    if [ -n "$current" ] && current_version=$("$current" -v); then
        info "Текущее ядро на диске: $current_version"
        current_tag=$(core_release_version "$current_version" || true)
    else current=""
    fi
    info 'Получение последней версии Mihomo...'
    if ! github_download "$metadata" 90 4194304 "${GITHUB_API_PROXY:-}" https://api.github.com/repos/MetaCubeX/mihomo/releases/latest ||
       ! latest=$(jq -er '.tag_name | select(type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$metadata"); then
        [ -n "$current" ] || error 'Информация о выпуске недоступна или отсутствует проверяемый базовый пакет, и нет работоспособного ядра'
        warn 'Не удалось получить проверяемый пакет выпуска, сохранено проверенное работоспособное ядро; ядро не обновлялось'
        cp "$current" "$PREPARED_DIR/mihomo"
        chmod 0755 "$PREPARED_DIR/mihomo"
        return
    fi
    if [ "$FORCE_CORE_INSTALL" = false ] && [ -n "$current" ] && [ "$current_tag" = "$latest" ]; then
        info "Mihomo уже последней версии ${latest}, повторное использование существующего ядра, загрузка пропущена"
        cp "$current" "$PREPARED_DIR/mihomo"
        chmod 0755 "$PREPARED_DIR/mihomo"
        return
    fi
    if ! name=$(select_core_asset "$metadata" "$latest" "$TARGET_GOOS" "$TARGET_GOARCH" "$TARGET_GOARM") ||
       ! expected=$(asset_sha256 "$metadata" "$name"); then
        [ -n "$current" ] || error 'Информация о выпуске не содержит проверяемого базового пакета, и нет работоспособного ядра'
        warn 'Не удалось получить проверяемый пакет выпуска, сохранено проверенное работоспособное ядро; ядро не обновлялось'
        cp "$current" "$PREPARED_DIR/mihomo"
        chmod 0755 "$PREPARED_DIR/mihomo"
        return
    fi
    info "Выбран пакет выпуска с базовой линией CPU: ${name}，версия $latest"
    if ! github_download "$PREPARED_DIR/core.gz" 600 268435456 "${GITHUB_PROXY:-}" "https://github.com/MetaCubeX/mihomo/releases/download/$latest/$name"; then
        [ -n "$current" ] || error 'Сбой загрузки ядра, первая установка не может быть продолжена'
        warn 'Все источники загрузки ядра недоступны, сохранено текущее работоспособное ядро; ядро не обновлялось'
        cp "$current" "$PREPARED_DIR/mihomo"
        chmod 0755 "$PREPARED_DIR/mihomo"
        return
    fi
    verify_asset "$expected" "$PREPARED_DIR/core.gz" || error 'Проверка SHA256 пакета выпуска ядра не удалась, установка не выполнена'
    info 'Проверка SHA256 пакета выпуска ядра успешна'
    gzip -dc "$PREPARED_DIR/core.gz" > "$PREPARED_DIR/mihomo" || error 'Распаковка пакета выпуска ядра не удалась'
    chmod 0755 "$PREPARED_DIR/mihomo"
    "$PREPARED_DIR/mihomo" -v || error 'Ядро не может работать в целевой среде'
}

prepare_ui() {
    if [ -f "${MIHOMO_SOURCE_DIR:-$PWD}/ui/index.html" ]; then
        info 'Доступен существующий UI, текущая панель сохранена'
        return
    fi
    info 'Подготовка панели MetaCubeXD...'
    github_download "$PREPARED_DIR/ui.tar.gz" 300 134217728 "${GITHUB_PROXY:-}" https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.tar.gz || error 'Загрузка панели не удалась'
    mkdir "$PREPARED_DIR/ui"
    tar -xzf "$PREPARED_DIR/ui.tar.gz" --strip-components=1 -C "$PREPARED_DIR/ui" || error 'Распаковка панели не удалась'
    [ -f "$PREPARED_DIR/ui"/index.html ] || error 'Пакет выпуска панели недействителен'
}

install_binary() {
    local source="$1" name="$2" pending
    sudo mkdir -p "/usr/local/bin"
    pending=$(sudo mktemp "/usr/local/bin/.$name.XXXXXX")
    if ! sudo install -m 0755 "$source" "$pending" || ! sudo mv -f "$pending" "/usr/local/bin/$name"; then
        sudo rm -f "$pending"
        error "Установка $name не удалась"
    fi
}

render_service() {
    local template="$1" line
    # WorkingDirectory — это значение пути, а не командное слово: экранирование кавычками/обратным слэшем
    # стало бы частью пути. Экранируются только спецификаторы unit.
    local working_dir="${PWD//%/%%}"
    # ExecStart отдельно разбирает кавычки командных слов и раскрывает переменные $.
    local exec_dir="${PWD//\\/\\\\}"
    exec_dir="${exec_dir//\"/\\\"}"
    exec_dir="${exec_dir//%/%%}"
    exec_dir="${exec_dir//\$/\$\$}"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            WorkingDirectory=@DEPLOY_DIR@) printf 'WorkingDirectory=%s\n' "$working_dir" ;;
            # systemd запрещает имена исполняемых файлов с кавычками/обратными слэшами;
            # фиксированный исполняемый файл Bash принимает путь развёртывания как аргумент.
            ExecStart=@ENTRYPOINT@) printf 'ExecStart=/bin/bash "%s/scripts/entrypoint.sh"\n' "$exec_dir" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$template"
}

if [ "$MODE" = --prepare ]; then
    mkdir "$PREPARED_DIR"
    prepare_core
    prepare_ui
    # Локальный манифест целостности охватывает распакованные исполняемые файлы и подготовленный UI.
    (cd "$PREPARED_DIR" && if command -v sha256sum >/dev/null; then sha256sum mihomo; else shasum -a 256 mihomo; fi) > "$PREPARED_DIR/mihomo.sha256"
    info 'Подготовка пакета времени выполнения завершена; системные программы ещё не заменены, службы не переключены'
else
    [ -x "$PREPARED_DIR/mihomo" ] || error 'Отсутствует предварительно проверенное ядро'
    expected=$(awk '{print $1}' "$PREPARED_DIR/mihomo.sha256")
    verify_asset "$expected" "$PREPARED_DIR/mihomo" || error 'Проверка целостности предварительно проверенного ядра не удалась'
    "$PREPARED_DIR/mihomo" -v || error 'Предварительно проверенное ядро не может работать'
    if [ "$FORCE_CORE_INSTALL" = false ] && [ -x "/usr/local/bin/mihomo" ] && cmp -s "$PREPARED_DIR/mihomo" "/usr/local/bin/mihomo"; then
        info 'Содержимое ядра Mihomo не изменилось, повторная установка пропущена'
    else
        install_binary "$PREPARED_DIR/mihomo" mihomo
    fi
    install_binary "$MANAGER_BINARY" mihomo-manager
    if [ -d "$PREPARED_DIR/ui" ]; then
        touch "$PREPARED_DIR/ui-installed"
        [ ! -e ui ] || mv ui "$PREPARED_DIR/previous-ui"
        mv "$PREPARED_DIR/ui" ui
    fi
    sudo mkdir -p /etc/systemd/system
    for unit in mihomo mihomo-manager; do
        rendered=$(mktemp)
        render_service "systemd/$unit.service.in" > "$rendered"
        sudo install -m 0644 "$rendered" "/etc/systemd/system/$unit.service"
        rm -f "$rendered"
    done
    sudo systemctl daemon-reload
    sudo systemctl enable mihomo.service mihomo-manager.service
    info 'Установка файлов времени выполнения завершена; ожидание переключения конфигурации и приёмки времени выполнения'
fi