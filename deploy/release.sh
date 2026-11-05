#!/bin/bash
# Одна блокировка охватывает подготовку, установку, активацию конфигурации и компенсацию.
set -euo pipefail
umask 077
[ "$#" -eq 2 ] || { [ "$#" -eq 3 ] && [ "$3" = --force ]; } || exit 1
deploy_dir="$1"
stage_dir="$2"
force_install=false
[ "${3:-}" != --force ] || force_install=true
[[ "$deploy_dir" == /* && "$stage_dir" == "$deploy_dir"/.deploy.* ]] || exit 1
source "$stage_dir/lib/env.sh"
mkdir -p "$deploy_dir/.update-state"
chmod 0700 "$deploy_dir/.update-state"
exec 9> "$deploy_dir/.update-state/update.lock"
flock -n 9 || { echo 'Обновление или публикация и Выполнение' >&2; rm -rf "$stage_dir"; exit 3; }
pending="$deploy_dir/.update-state/deployment.pending"
phase=preparing
mutating=false
recovery_failed=false
previous_stage=""
runtime_files=(install.sh release.sh scripts/update.sh scripts/entrypoint.sh lib/target.sh lib/env.sh lib/http.sh lib/release.sh systemd/mihomo.service.in systemd/mihomo-manager.service.in)
state_files=(.env .config_hash .env_hash .cidr_hash .update-state/confirmed.json .update-state/transaction.json .update-state/status.json .update-state/failed.json)

# Никогда не усекать предыдущую запись восстановления: новый пакет и его резервная копия
# должны быть готовы, прежде чем он атомарно станет владельцем восстановления.
write_pending() (
    local recovery="$1" temporary
    temporary=$(mktemp "${pending}.XXXXXX") || return 1
    trap 'rm -f "$temporary"' EXIT
    printf '%s\n' "$recovery" > "$temporary" || return 1
    sync -f "$temporary" || return 1
    mv -f "$temporary" "$pending" || return 1
    sync -f "$(dirname "$pending")"
)

save_file() {
    local source="$1" key="$2"
    mkdir -p "$stage_dir/backup/$(dirname "$key")"
    if [ -e "$source" ] || [ -L "$source" ]; then
        sudo cp -a "$source" "$stage_dir/backup/$key"
        touch "$stage_dir/backup/$key.present"
    fi
}
restore_file() {
    local target="$1" key="$2" temporary
    if [ -f "$stage_dir/backup/$key.present" ]; then
        sudo mkdir -p "$(dirname "$target")"
        temporary=$(sudo mktemp "$(dirname "$target")/.restore.XXXXXX") || return 1
        sudo cp -a "$stage_dir/backup/$key" "$temporary" && sudo mv -f "$temporary" "$target"
    else
        sudo rm -f "$target"
    fi
}

capture_running() {
    local service="$1" key="$2" pid executable
    if [ "$(cat "$stage_dir/backup/$service.active")" = active ]; then
        pid=$(systemctl show "$service.service" --property=MainPID --value)
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
        executable=$(readlink "/proc/$pid/exe")
        [[ "$executable" == */"$service" || "$executable" == */"$service (deleted)" ]] || return 1
        # Сохранить исполняемый файл, который действительно запускает работоспособная базовая линия, даже если
        # предыдущая неудачная публикация уже заменила его inode на диске.
        sudo cp -pL "/proc/$pid/exe" "$stage_dir/backup/$key"
        touch "$stage_dir/backup/$key.present"
    fi
}

backup_release() {
    mkdir "$stage_dir/backup"
    local file service
    for file in "${runtime_files[@]}" "${state_files[@]}"; do save_file "$deploy_dir/$file" "deployment/$file"; done
    save_file /usr/local/bin/mihomo kernel
    save_file /usr/local/bin/mihomo-manager manager
    for service in mihomo mihomo-manager; do
        save_file "/etc/systemd/system/$service.service" "$service.unit"
        if systemctl is-active --quiet "$service.service"; then echo active; else echo inactive; fi > "$stage_dir/backup/$service.active"
        if systemctl is-enabled --quiet "$service.service"; then echo enabled; else echo disabled; fi > "$stage_dir/backup/$service.enabled"
    done
    capture_running mihomo kernel
    capture_running mihomo-manager manager
    if [ -d "$stage_dir/.release/ui" ] && [ -e "$deploy_dir/ui" ]; then cp -a "$deploy_dir/ui" "$stage_dir/backup/ui"; fi
}

verify_running() {
    local service="$1" binary="$2" pid expected actual attempt
    for attempt in {1..30}; do
        if systemctl is-active --quiet "$service.service"; then
            pid=$(systemctl show "$service.service" --property=MainPID --value)
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
                expected=$(stat -Lc '%d:%i' "$binary")
                actual=$(stat -Lc '%d:%i' "/proc/$pid/exe" 2>/dev/null || true)
                [ "$expected" != "$actual" ] || return 0
            fi
        fi
        sleep 0.1
    done
    echo "$service рабочий процесс не загрузил установленный бинарный файл" >&2
    return 1
}

rollback_release() {
    local file service failures=0
    echo "[Публикация] Сбой этапа $phase, восстановление программ, служб и конфигурации..." >&2
    for service in mihomo-manager mihomo; do sudo systemctl stop "$service.service" || failures=1; done
    for file in "${runtime_files[@]}" "${state_files[@]}"; do restore_file "$deploy_dir/$file" "deployment/$file" || failures=1; done
    restore_file /usr/local/bin/mihomo kernel || failures=1
    restore_file /usr/local/bin/mihomo-manager manager || failures=1
    for service in mihomo mihomo-manager; do restore_file "/etc/systemd/system/$service.service" "$service.unit" || failures=1; done
    if [ -f "$stage_dir/.release/ui-installed" ]; then
        if [ -d "$stage_dir/backup/ui" ]; then
            rm -rf "$deploy_dir/ui"
            cp -a "$stage_dir/backup/ui" "$deploy_dir/ui" || failures=1
        else rm -rf "$deploy_dir/ui"
        fi
    fi
    "$stage_dir/mihomo-manager" update --source-dir "$deploy_dir" --restore-snapshot "$stage_dir/prepared/before.json" --lock-fd 9 || failures=1
    sudo systemctl daemon-reload || failures=1
    for service in mihomo mihomo-manager; do
        if [ "$(cat "$stage_dir/backup/$service.enabled")" = enabled ]; then
            sudo systemctl enable "$service.service" || failures=1
        else sudo systemctl disable "$service.service" || failures=1
        fi
        if [ "$(cat "$stage_dir/backup/$service.active")" = active ]; then
            sudo systemctl restart "$service.service" || failures=1
            verify_running "$service" "/usr/local/bin/$service" || failures=1
        fi
    done
    if [ "$(cat "$stage_dir/backup/mihomo.active")" = active ]; then
        "$stage_dir/mihomo-manager" update --source-dir "$deploy_dir" --verify-snapshot "$stage_dir/prepared/before.json" --lock-fd 9 || failures=1
    fi
    if [ "$failures" -ne 0 ]; then
        echo "[Публикация] Восстановление не завершено, пакет восстановления сохранён: $stage_dir" >&2
        return 1
    fi
    echo '[Публикация] Программы и конфигурация до публикации восстановлены；эта публикация не удалась' >&2
}

finish() {
    local rc=$?
    trap - EXIT HUP INT TERM
    if [ "$rc" -ne 0 ] && [ "$mutating" = true ]; then
        if rollback_release; then
            if [ -n "$previous_stage" ]; then
                if write_pending "$previous_stage"; then
                    echo "[Публикация] Принудительная установка не удалась, исходная запись незавершённой публикации и пакет восстановления сохранены: $previous_stage" >&2
                else
                    recovery_failed=true
                    echo "[Публикация] Не удалось восстановить исходную запись незавершённой публикации, текущий пакет восстановления сохранён: $stage_dir" >&2
                fi
            else rm -f "$pending"
            fi
        else recovery_failed=true
        fi
    fi
    if [ "$recovery_failed" = false ]; then rm -rf "$stage_dir"; fi
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' HUP INT TERM

# Обычная публикация сначала восстанавливает прерванное развёртывание. Явная принудительная
# публикация сохраняет этот пакет и исправляет текущее состояние путём повторной установки.
if [ -f "$pending" ]; then
    new_stage="$stage_dir"
    old_stage=$(cat "$pending")
    [[ "$old_stage" == "$deploy_dir"/.deploy.* && "$old_stage" != "$new_stage" && "$old_stage" != *$'\n'* && -d "$old_stage/backup" ]] || { echo 'Недопустимая запись восстановления публикации, установка отклонена' >&2; exit 1; }
    if [ "$force_install" = true ]; then
        previous_stage="$old_stage"
        printf '%s\n' "$previous_stage" > "$stage_dir/previous-deployment.pending"
        echo "[Публикация] Принудительная установка：пропуск автоматического восстановления старой публикации, пакет восстановления сохранён: $previous_stage"
    else
        stage_dir="$old_stage"
        phase=interrupted
        if ! rollback_release; then
            echo '[Публикация] Автоматическое восстановление не удалось; используйте mise run publish -- --force для сохранения старого пакета восстановления и переустановки' >&2
            rm -rf "$new_stage"; recovery_failed=true; exit 1
        fi
        rm -f "$pending"
        rm -rf "$stage_dir"
        stage_dir="$new_stage"
    fi
fi

export MIHOMO_SOURCE_DIR="$deploy_dir"
export MIHOMO_PREPARED_DIR="$stage_dir/.release"
export MIHOMO_FORCE_CORE_INSTALL="$force_install"
cd "$stage_dir"
./install.sh --prepare "$stage_dir/mihomo-manager"
mkdir "$stage_dir/prepared"
./mihomo-manager update --prepare-only "$stage_dir/prepared" --source-dir "$deploy_dir" --runtime-dir "$stage_dir" --env-file "$stage_dir/.env" --kernel "$stage_dir/.release/mihomo" --lock-fd 9
backup_release
./mihomo-manager update --check-snapshot "$stage_dir/prepared/before.json" --source-dir "$deploy_dir" --env-file "$stage_dir/.env" --lock-fd 9
mutating=true
phase=installing
write_pending "$stage_dir"
mkdir -p "$deploy_dir/scripts" "$deploy_dir/lib" "$deploy_dir/systemd"
for file in "${runtime_files[@]}"; do cp "$stage_dir/$file" "$deploy_dir/$file"; done
[ -f "$deploy_dir/.env" ] || cp "$stage_dir/.env" "$deploy_dir/.env"
cd "$deploy_dir"
./install.sh --apply "$stage_dir/mihomo-manager"
phase=activating
/usr/local/bin/mihomo-manager update --prepared "$stage_dir/prepared/candidate.json" --force-restart --lock-fd 9
verify_running mihomo /usr/local/bin/mihomo
sudo systemctl restart mihomo-manager.service
verify_running mihomo-manager /usr/local/bin/mihomo-manager
load_env_file "$deploy_dir/.env"
port="${PORT:-8000}"
[[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo 'Недопустимый порт менеджера' >&2; exit 1; }
for attempt in {1..30}; do
    if curl --disable --noproxy '*' --fail --silent --connect-timeout 1 --max-time 2 "http://127.0.0.1:$port/" >/dev/null; then break; fi
    [ "$attempt" -lt 30 ] || { echo 'Проверка готовности HTTP менеджера не удалась' >&2; exit 1; }
    sleep 0.1
done
rm -f "$pending"
phase=complete
mutating=false
echo "[Публикация] Конфигурация, ядро и менеджер переключены и приняты; порт управления $port"