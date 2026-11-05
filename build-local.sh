#!/bin/bash
# build-local.sh — полностью автоматическая локальная сборка + запуск Mihomo
# Версия 3.0.0  2026-10-07
# Автор: @smg38
#
# Команды:
#   ./build-local.sh           — собрать всё (по умолчанию)
#   ./build-local.sh build     — только собрать
#   ./build-local.sh start     — запустить ядро + менеджер в фоне
#   ./build-local.sh stop      — остановить
#   ./build-local.sh restart   — перезапустить
#   ./build-local.sh status    — статус + хвост логов
#   ./build-local.sh logs      — следить за логами
#   ./build-local.sh test-sub  — проверить подписку (URL из .env)
#   ./build-local.sh clean     — удалить .tmp полностью
set -euo pipefail

# ==============================================================================
# Цвета через $'...' — иначе bash выведет литерал \033
# ==============================================================================
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'
C_MAGENTA=$'\033[0;35m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RUNTIME_DIR="$SCRIPT_DIR/.tmp"
STAGE_DIR="$RUNTIME_DIR/stage"
LOCAL_BIN="$HOME/.local/bin"
YQ_VERSION="v4.44.3"

STEP=0
T_START=$(date +%s)

step() {
    STEP=$((STEP + 1))
    printf '\n%s%s[Шаг %d]%s %s\n' "$C_BOLD" "$C_CYAN" "$STEP" "$C_RESET" "$1"
    printf '%s────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"
}
info()  { printf '%s  ·%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
ok()    { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn()  { printf '%s  ⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
fail()  { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }
kv()    { printf '%s      %-20s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"; }

trap 'printf "\n%sПрервано пользователем%s\n" "$C_RED" "$C_RESET" >&2; exit 130' INT TERM

# ==============================================================================
# Утилиты
# ==============================================================================
have() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
    case "$(uname -s)" in
        Linux)  echo "linux"  ;;
        Darwin) echo "darwin" ;;
        *)      fail "Неподдерживаемая ОС: $(uname -s)" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l)        echo "armv7" ;;
        armv6l)        echo "armv6" ;;
        i686|i386)     echo "386"   ;;
        *)             fail "Неподдерживаемая архитектура: $(uname -m)" ;;
    esac
}

has_sudo() {
    have sudo && sudo -n true 2>/dev/null
}

# Автоустановка yq (Go-версия, mikefarah) — без sudo, в ~/.local/bin
install_yq() {
    mkdir -p "$LOCAL_BIN"
    case ":$PATH:" in
        *":$LOCAL_BIN:"*) ;;
        *) export PATH="$LOCAL_BIN:$PATH" ;;
    esac

    local os arch asset
    os=$(detect_os)
    case "$(detect_arch)" in
        amd64) arch="amd64" ;;
        arm64) arch="arm64" ;;
        armv7) arch="arm"   ;;
        armv6) arch="arm"   ;;
        386)   arch="386"   ;;
    esac
    asset="yq_${os}_${arch}"

    local url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${asset}"
    info "Скачивание yq $YQ_VERSION для ${os}/${arch}..."
    kv "URL" "$url"

    if ! curl -fL --progress-bar -o "$LOCAL_BIN/yq" "$url"; then
        fail "Не удалось скачать yq. Проверьте сеть/URL."
    fi
    chmod +x "$LOCAL_BIN/yq"
    ok "yq установлен: $LOCAL_BIN/yq"
    kv "Версия" "$("$LOCAL_BIN/yq" --version 2>&1 | head -1)"
}

# Автоустановка nftables (нужно sudo)
install_nft() {
    if [ "$(detect_os)" != "linux" ]; then
        warn "nftables только для Linux — пропуск"
        return 0
    fi
    if ! has_sudo; then
        warn "nftables не установлен, sudo недоступен — прозрачный прокси не будет работать"
        warn "Установите вручную: sudo apt install -y nftables"
        return 0
    fi
    info "Устанавливаю nftables через пакетный менеджер..."
    if   have apt;    then sudo apt-get update -qq && sudo apt-get install -y nftables
    elif have dnf;    then sudo dnf install -y nftables
    elif have yum;    then sudo yum install -y nftables
    elif have pacman; then sudo pacman -S --noconfirm nftables
    else
        warn "Пакетный менеджер не распознан — установите nftables вручную"
        return 0
    fi
    have nft && ok "nftables установлен: $(nft --version)"
}

# ==============================================================================
# Функция сборки (используется командами build/start/restart)
# ==============================================================================
do_build() {
    STEP=0
    T_START=$(date +%s)

    # ---------- 1. Платформа ----------
    step "Определение платформы"
    OS=$(detect_os)
    ARCH=$(detect_arch)
    kv "ОС"          "$OS"
    kv "Архитектура" "$ARCH"
    kv "Проект"      "$SCRIPT_DIR"
    kv "Runtime"     "$RUNTIME_DIR"

    # ---------- 2. Системные зависимости + автоустановка ----------
    step "Проверка и автоустановка зависимостей"

    # curl/tar/gzip/awk/jq — должны быть в системе
    MISSING=()
    for c in curl tar gzip awk jq; do
        if have "$c"; then
            ok "$c ($("$c" --version 2>&1 | head -1 | cut -c1-60))"
        else
            warn "$c не найден"
            MISSING+=("$c")
        fi
    done

    if [ ${#MISSING[@]} -gt 0 ]; then
        if has_sudo; then
            info "Устанавливаю недостающие базовые пакеты: ${MISSING[*]}"
            if   have apt;    then sudo apt-get update -qq && sudo apt-get install -y "${MISSING[@]}"
            elif have dnf;    then sudo dnf install -y "${MISSING[@]}"
            elif have yum;    then sudo yum install -y "${MISSING[@]}"
            elif have pacman; then sudo pacman -S --noconfirm "${MISSING[@]}"
            else fail "Установите вручную: ${MISSING[*]}"
            fi
        else
            fail "Не хватает: ${MISSING[*]}. sudo недоступен — установите вручную."
        fi
    fi

    # yq — критичен, ставим сами
    export PATH="$LOCAL_BIN:$PATH"
    if have yq && yq --version 2>&1 | grep -q mikefarah; then
        ok "yq ($(yq --version 2>&1 | head -1))"
    else
        if have yq; then
            warn "Найдена неверная версия yq (не mikefarah), устанавливаю правильную в $LOCAL_BIN"
        else
            warn "yq не найден, устанавливаю в $LOCAL_BIN"
        fi
        install_yq
    fi

    # nft — только для Linux
    if have nft; then
        ok "nft ($(nft --version 2>&1))"
    else
        install_nft
    fi

    # ---------- 3. Go ----------
    step "Проверка Go"
    case ":$PATH:" in
        *:/usr/local/go/bin:*) ;;
        *) export PATH="/usr/local/go/bin:$PATH" ;;
    esac
    export GOTOOLCHAIN=local

    have go || fail "Go не найден. Установите Go 1.26+ (https://go.dev/dl/)"
    kv "go version"     "$(go version)"
    kv "go.mod требует" "$(awk '/^go /{print $2; exit}' go.mod)"

    # ---------- 4. Менеджер ----------
    step "Сборка mihomo-manager"
    mkdir -p "$RUNTIME_DIR"
    info "go build..."
    go build -trimpath -ldflags '-w -s' -o "$RUNTIME_DIR/mihomo-manager" ./cmd/mihomo-manager \
        || fail "Сборка не удалась"
    kv "Размер" "$(du -h "$RUNTIME_DIR/mihomo-manager" | cut -f1)"
    kv "Версия" "$("$RUNTIME_DIR/mihomo-manager" --version 2>&1 || echo '?')"
    ok "менеджер готов"

    # ---------- 5. Ядро ----------
    step "Подготовка ядра Mihomo"
    KERNEL_BIN="$RUNTIME_DIR/mihomo"
    if [ -x "$KERNEL_BIN" ]; then
        ok "Ядро уже на месте"
        kv "Версия" "$("$KERNEL_BIN" -v 2>&1 | head -1)"
    else
        case "$ARCH" in
            amd64)  KERNEL_ASSET="mihomo-${OS}-amd64-v1-compatible.gz" ;;
            arm64)  KERNEL_ASSET="mihomo-${OS}-arm64-v8a-compatible.gz" ;;
            armv7)  KERNEL_ASSET="mihomo-${OS}-armv7-compatible.gz" ;;
            armv6)  KERNEL_ASSET="mihomo-${OS}-armv6-compatible.gz" ;;
            386)    KERNEL_ASSET="mihomo-${OS}-386-compatible.gz" ;;
        esac
        KERNEL_URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/$KERNEL_ASSET"
        kv "Актив" "$KERNEL_ASSET"
        info "Загрузка..."
        curl -fL --progress-bar -o "$RUNTIME_DIR/mihomo.gz" "$KERNEL_URL" \
            || fail "Не удалось скачать ядро: $KERNEL_URL"
        gunzip -f "$RUNTIME_DIR/mihomo.gz" || fail "gunzip не удался"
        chmod +x "$KERNEL_BIN"
        ok "Ядро распаковано"
        kv "Версия" "$("$KERNEL_BIN" -v 2>&1 | head -1)"
    fi

    # ---------- 5.5. UI MetaCubeXD ----------
    step "Подготовка панели MetaCubeXD"
    UI_DIR="$RUNTIME_DIR/ui"
    if [ -f "$UI_DIR/index.html" ]; then
        ok "UI уже на месте"
        kv "Путь" "$UI_DIR"
    else
        info "Скачивание MetaCubeXD (gh-pages)..."
        mkdir -p "$UI_DIR"
        UI_TAR="$RUNTIME_DIR/ui.tar.gz"
        UI_URL="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.tar.gz"
        if curl -fL --progress-bar -o "$UI_TAR" "$UI_URL"; then
            tar -xzf "$UI_TAR" --strip-components=1 -C "$UI_DIR" \
                || fail "Распаковка UI не удалась"
            rm -f "$UI_TAR"
            [ -f "$UI_DIR/index.html" ] || fail "UI не содержит index.html"
            ok "UI готов"
            kv "Путь" "$UI_DIR"
        else
            warn "Не удалось скачать UI. Панель :9900 будет недоступна."
            warn "Скачайте вручную в $UI_DIR"
        fi
    fi

    # ---------- 6. Скрипты ----------
    step "Раскладка скриптов"
    mkdir -p "$RUNTIME_DIR/scripts" "$RUNTIME_DIR/lib"
    for f in env.sh http.sh target.sh release.sh; do
        [ -f "deploy/lib/$f" ] || fail "Не найден: deploy/lib/$f"
        cp -f "deploy/lib/$f" "$RUNTIME_DIR/lib/$f"
        ok "lib/$f"
    done
    for f in update.sh entrypoint.sh; do
        [ -f "deploy/scripts/$f" ] || fail "Не найден: deploy/scripts/$f"
        cp -f "deploy/scripts/$f" "$RUNTIME_DIR/scripts/$f"
        ok "scripts/$f"
    done
    chmod +x "$RUNTIME_DIR/scripts/"*.sh
    ok "права выставлены"

    # ---------- 7. .env ----------
    step "Конфигурация .env"
    ENV_FILE="$RUNTIME_DIR/.env"
    if [ -f "$ENV_FILE" ]; then
        warn ".env уже существует — НЕ перезаписываю"
        kv "Путь" "$ENV_FILE"
    else
        cat > "$ENV_FILE" <<'EOF'
# =============================================================================
# Mihomo — локальная конфигурация (build-local.sh v3)
# =============================================================================

MIHOMO_SECRET=example
CONFIG_URL=https://example.com/subscription/config.yaml

SKIP_CNIP=true
SKIP_RUIP=true

QUIC=true
LOCAL_LOOPBACK_PROXY=false
PORT=8000

GITHUB_PROXY=
GITHUB_API_PROXY=
DOWNLOAD_DOH_SERVERS="dns.alidns.com:223.5.5.5 cloudflare-dns.com:1.1.1.1"
DOWNLOAD_PROGRESS=auto
EOF
        chmod 600 "$ENV_FILE"
        ok ".env создан"
        kv "Путь" "$ENV_FILE"
    fi

    # ---------- 8. Подписка ----------
    step "Проверка подписки (CONFIG_URL)"
    # shellcheck disable=SC1090
    source "$RUNTIME_DIR/lib/env.sh" && load_env_file "$ENV_FILE" || true

    if [ -z "${CONFIG_URL:-}" ]; then
        warn "CONFIG_URL пуст — пропускаю загрузку подписки"
    elif [[ "$CONFIG_URL" == *"example.com"* ]]; then
        warn "CONFIG_URL указывает на example.com — это заглушка"
        warn "Отредактируйте $ENV_FILE и укажите реальный URL, затем: ./build-local.sh test-sub"
    else
        info "Проверка доступности подписки..."
        kv "URL" "$CONFIG_URL"
        if curl -fLs --max-time 15 -o /dev/null -w '%{http_code}' "$CONFIG_URL" | grep -q '^2'; then
            ok "Подписка доступна"
        else
            warn "Подписка недоступна или вернула не-2xx код"
            warn "Продолжаем — возможно, нужен прокси/VPN"
        fi
    fi

    # ---------- 9. --prepare ----------
    step "Подготовка конфигурации (update.sh --prepare)"

    # Заглушка, если CONFIG_URL всё ещё example.com — делаем минимальный config.yaml
    if [[ "${CONFIG_URL:-}" == *"example.com"* ]] || [ -z "${CONFIG_URL:-}" ]; then
        warn "Использую минимальный config.yaml (реальная подписка не настроена)"
        cat > "$RUNTIME_DIR/config.yaml" <<'YAML'
mode: rule
log-level: info
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
YAML
        ok "Минимальный config.yaml создан"
    else
        export MIHOMO_UPDATE_INTERNAL=1
        export MIHOMO_SOURCE_DIR="$RUNTIME_DIR"
        export MIHOMO_ENV_FILE="$ENV_FILE"
        export MIHOMO_TEST_KERNEL="$KERNEL_BIN"
        export MIHOMO_RUNTIME_DIR="$RUNTIME_DIR"
        export DOWNLOAD_PROGRESS=off

        mkdir -p "$STAGE_DIR"
        kv "SOURCE_DIR" "$MIHOMO_SOURCE_DIR"
        kv "KERNEL"     "$MIHOMO_TEST_KERNEL"
        kv "STAGE"      "$STAGE_DIR"

        if "$RUNTIME_DIR/scripts/update.sh" --prepare "$STAGE_DIR"; then
            ok "update.sh --prepare завершён"
            for f in config.yaml subscription.yaml cn_cidr.txt ru_cidr.txt .cidr_timestamp; do
                [ -f "$STAGE_DIR/$f" ] && cp -f "$STAGE_DIR/$f" "$RUNTIME_DIR/$f" && kv "$f" "$(du -h "$STAGE_DIR/$f" | cut -f1)"
            done
        else
            fail "update.sh --prepare провалился"
        fi
    fi

    # ---------- 10. Валидация ----------
    step "Валидация конфигурации ядром"
    if "$KERNEL_BIN" -t -d "$RUNTIME_DIR" -f "$RUNTIME_DIR/config.yaml" >/dev/null 2>&1; then
        ok "config.yaml валиден"
    else
        warn "Ядро нашло проблемы:"
        "$KERNEL_BIN" -t -d "$RUNTIME_DIR" -f "$RUNTIME_DIR/config.yaml" 2>&1 | head -20 | sed 's/^/      /'
        warn "Продолжаем — базовый запуск может работать"
    fi

    # ---------- Финал ----------
    local t_end t_elapsed
    t_end=$(date +%s)
    t_elapsed=$((t_end - T_START))
    printf '\n%s╔══════════════════════════════════════════════════════════════╗%s\n' "$C_BOLD$C_GREEN" "$C_RESET"
    printf '%s║  ✓ Сборка завершена за %-3d сек                              ║%s\n' "$C_BOLD$C_GREEN" "$t_elapsed" "$C_RESET"
    printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "$C_BOLD$C_GREEN" "$C_RESET"
}

# ==============================================================================
# Команды управления запуском
# ==============================================================================
PID_KERNEL="$RUNTIME_DIR/.kernel.pid"
PID_MANAGER="$RUNTIME_DIR/.manager.pid"
LOG_KERNEL="$RUNTIME_DIR/kernel.log"
LOG_MANAGER="$RUNTIME_DIR/manager.log"

is_running() {
    local pidfile="$1"
    [ -f "$pidfile" ] || return 1
    local pid
    pid=$(cat "$pidfile")
    kill -0 "$pid" 2>/dev/null
}

do_start() {
    [ -x "$RUNTIME_DIR/mihomo" ] || fail "Ядро не найдено. Сначала: ./build-local.sh build"
    [ -x "$RUNTIME_DIR/mihomo-manager" ] || fail "Менеджер не найден. Сначала: ./build-local.sh build"

    if is_running "$PID_KERNEL"; then
        warn "Ядро уже запущено (PID $(cat "$PID_KERNEL"))"
    else
        info "Запуск ядра Mihomo..."
        cd "$RUNTIME_DIR"
        MIHOMO_RUNTIME_DIR="$RUNTIME_DIR" \
        MIHOMO_KERNEL="$RUNTIME_DIR/mihomo" \
        nohup ./scripts/entrypoint.sh > "$LOG_KERNEL" 2>&1 &
        echo $! > "$PID_KERNEL"
        sleep 1
        if is_running "$PID_KERNEL"; then
            ok "Ядро запущено (PID $(cat "$PID_KERNEL"))"
            kv "Лог" "$LOG_KERNEL"
        else
            fail "Ядро упало. Смотрите: $LOG_KERNEL"
        fi
    fi

    if is_running "$PID_MANAGER"; then
        warn "Менеджер уже запущен (PID $(cat "$PID_MANAGER"))"
    else
        info "Запуск менеджера..."
        cd "$RUNTIME_DIR"
        MIHOMO_RUNTIME_DIR="$RUNTIME_DIR" \
        MIHOMO_KERNEL="$RUNTIME_DIR/mihomo" \
        nohup ./mihomo-manager > "$LOG_MANAGER" 2>&1 &
        echo $! > "$PID_MANAGER"
        sleep 1
        if is_running "$PID_MANAGER"; then
            ok "Менеджер запущен (PID $(cat "$PID_MANAGER"))"
            kv "Лог" "$LOG_MANAGER"
        else
            fail "Менеджер упал. Смотрите: $LOG_MANAGER"
        fi
    fi

    # Проверка портов
    sleep 1
    printf '\n%sПроверка портов:%s\n' "$C_BOLD" "$C_RESET"
    for port in 8000 9900 7890; do
        if command -v ss >/dev/null && ss -tln 2>/dev/null | grep -q ":$port "; then
            ok "порт $port слушается"
        elif command -v lsof >/dev/null && lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
            ok "порт $port слушается"
        else
            warn "порт $port не слушается"
        fi
    done

    cat <<EOF

${C_BOLD}Открывайте:${C_RESET}
  ${C_CYAN}http://localhost:8000${C_RESET}     — панель управления (ключ: example)
  ${C_CYAN}http://localhost:9900/ui${C_RESET}  — MetaCubeXD напрямую

${C_BOLD}Управление:${C_RESET}
  ./build-local.sh logs     — смотреть логи
  ./build-local.sh status   — статус
  ./build-local.sh stop     — остановить
EOF
}

do_stop() {
    for name in manager kernel; do
        local pidfile pid
        pidfile="$RUNTIME_DIR/.${name}.pid"
        if [ -f "$pidfile" ]; then
            pid=$(cat "$pidfile")
            if kill -0 "$pid" 2>/dev/null; then
                info "Остановка $name (PID $pid)..."
                kill "$pid" 2>/dev/null || true
                for _ in $(seq 1 10); do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 0.3
                done
                kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
                ok "$name остановлен"
            fi
            rm -f "$pidfile"
        fi
    done
    ok "Всё остановлено"
}

do_status() {
    printf '%sСтатус процессов:%s\n' "$C_BOLD" "$C_RESET"
    for name in kernel manager; do
        local pidfile="$RUNTIME_DIR/.${name}.pid"
        if is_running "$pidfile"; then
            printf '  %s✓%s %-10s PID %s\n' "$C_GREEN" "$C_RESET" "$name" "$(cat "$pidfile")"
        else
            printf '  %s✗%s %-10s не запущен\n' "$C_RED" "$C_RESET" "$name"
        fi
    done
    printf '\n%sПоследние 15 строк ядра:%s\n' "$C_BOLD" "$C_RESET"
    tail -15 "$LOG_KERNEL" 2>/dev/null | sed 's/^/  /' || echo "  (лог пуст)"
    printf '\n%sПоследние 15 строк менеджера:%s\n' "$C_BOLD" "$C_RESET"
    tail -15 "$LOG_MANAGER" 2>/dev/null | sed 's/^/  /' || echo "  (лог пуст)"
}

do_logs() {
    info "Слежение за логами (Ctrl+C для выхода)..."
    tail -f "$LOG_KERNEL" "$LOG_MANAGER" 2>/dev/null
}

do_test_sub() {
    [ -f "$RUNTIME_DIR/.env" ] || fail ".env не найден. Сначала: ./build-local.sh build"
    # shellcheck disable=SC1090
    source "$RUNTIME_DIR/lib/env.sh" && load_env_file "$RUNTIME_DIR/.env" || true
    [ -n "${CONFIG_URL:-}" ] || fail "CONFIG_URL не задан в .env"
    info "Проверка: $CONFIG_URL"
    local code
    code=$(curl -fLs --max-time 20 -o /tmp/mihomo-sub-test.yaml -w '%{http_code}' "$CONFIG_URL" || echo "000")
    kv "HTTP" "$code"
    kv "Размер" "$(wc -c < /tmp/mihomo-sub-test.yaml 2>/dev/null || echo 0) байт"
    if [ "$code" = "200" ] && [ -s /tmp/mihomo-sub-test.yaml ]; then
        ok "Подписка валидна"
        head -5 /tmp/mihomo-sub-test.yaml | sed 's/^/      /'
    else
        fail "Подписка недоступна или пуста"
    fi
}

do_clean() {
    warn "Удаляю $RUNTIME_DIR ..."
    read -r -p "Продолжить? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "отменено"; exit 0; }
    rm -rf "$RUNTIME_DIR"
    ok "Удалено"
}

# ==============================================================================
# Диспетчер команд
# ==============================================================================
CMD="${1:-all}"
case "$CMD" in
    ""|all)
        do_build
        printf '\n%sЗапустить сейчас? [y/N]%s ' "$C_BOLD" "$C_RESET"
        read -r ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            do_start
        else
            info "Запустить позже: ./build-local.sh start"
        fi
        ;;
    build)     do_build ;;
    start)     do_start ;;
    stop)      do_stop ;;
    restart)   do_stop; do_start ;;
    status)    do_status ;;
    logs)      do_logs ;;
    test-sub)  do_test_sub ;;
    clean)     do_clean ;;
    -h|--help|help)
        cat <<EOF
Использование: $0 [команда]

Команды:
  all (по умолчанию)  Собрать + предложить запуск
  build               Только собрать (ядро, менеджер, скрипты, .env, config)
  start               Запустить ядро + менеджер в фоне
  stop                Остановить
  restart             Перезапустить
  status              Показать статус + хвост логов
  logs                Следить за логами
  test-sub            Проверить подписку (CONFIG_URL из .env)
  clean               Удалить .tmp полностью
  help                Эта справка
EOF
        ;;
    *)
        fail "Неизвестная команда: $CMD. Смотрите: $0 help"
        ;;
esac