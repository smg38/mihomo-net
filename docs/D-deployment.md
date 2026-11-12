
-
# Развёртывание сервера D

[← Назад к README](../README.md)

Сервер **D** — локальный шлюз в зоне RU, прозрачный прокси для локальной сети.
Пользователи D ничего не настраивают: трафик LAN идёт через D как через
шлюз по умолчанию (TPROXY + NFTables). Не-RU/CN трафик D отправляет в
**C** (primary), при недоступности C — в **B** (fallback). RU/CN/private —
напрямую (режим `local`) или всё в C/B (режим `remote`).

D за NAT, публичного IP нет. Управление — через **C** (reverse SSH туннель
D → C, порт `2222` слушает только `127.0.0.1` на C). Это описание относится
к экземпляру `D`; несколько шлюзов типа D настраиваются отдельными файлами
экземпляров (см. §11).

---

## 1. Топология

| Сервер | Роль | Геозона | Runtime | Доступ |
|---|---|---|---|---|
| A | Сборочная машина | RU/CN | — | — |
| B | Релей | FN | `/opt/mihomo/` | Публичный IP |
| C | Внешний шлюз + jump-host | RU | `/opt/mihomo/` | Публичный IP |
| **D** | **Локальный шлюз (TPROXY)** | **RU** | **`/opt/mihomo/`** | **За NAT, через C** |

Связи:

```
LAN ──► D (шлюз по умолчанию, tproxy)
         │
         ├── RU/CN/private ──► DIRECT
         └── остальное ──► C (primary) ──► B / DIRECT
                       └─► B (fallback)

D ──reverse SSH──► C:127.0.0.1:2222   (управление)
A ──SSH──► C ──ProxyCommand──► D:22   (деплой, диагностика)
```

---

## 2. Предусловия

### На A

- `build/keys/params.env` с блоком D (см. §3).
- `build/C/GeoSite.dat` (RoscomVPN, с `category-ru`) — **обязательно**.
  Если нет — `scripts/build-servers.sh D --build` скачает с
  `https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat`.
- `build/C/geoip.metadb` — опционально (если нет, D качает сам).
- SSH A → C работает (`root@IP_C`).

### На C

- Публичный IP, SSH.
- `/var/www/html/mihomo/once/` (создаётся `grant.sh` / `deploy_C`).
- `GatewayPorts no` в `/etc/ssh/sshd_config` (по умолчанию `no`).
  Проверка: `sshd -T | grep -i gatewayports`.

### На D

- Linux + systemd.
- Пакеты: `openssh-client`, `nftables`, `curl`, `ca-certificates`, `tar`, `gzip`.
  (Установщик поставит сам, если нет.)
- Исходящий SSH D → C:22 разрешён.
- Исходящий HTTPS D → `IP_C:80` разрешён (для скачивания `D-install.run`, если bootstrap без прямого доступа).

---

## 3. Параметры (`build/keys/params.env`)

Для текущего одиночного D эти буквальные значения задаются в общем `params.env`.
Подстановки вида `${IP_C}` запрещены: указывайте фактические адреса и значения.

Добавить блок D:

```bash
# =============================================================================
# Server D (локальный шлюз в RU, прозрачный прокси для LAN)
# =============================================================================
IP_D=192.168.10.89
PORT_D=7893                     # tproxy-port; mixed-port = 7890
DIR_D=/opt/mihomo
ARCH_D=amd64
SECRET_KEY_D=manager

# Режим геозон:
#   local  — D сам определяет зону (RU/CN/private → DIRECT, остальное → C/B)
#   remote — D весь трафик (кроме private и SERVERNAME) → C/B
GEO_MODE=local

# Reverse SSH tunnel D -> C (управление D через C)
TUNNEL_C_HOST=94.232.248.179
TUNNEL_C_USER=root
TUNNEL_C_PORT=22
TUNNEL_REMOTE_PORT=2222         # слушает 127.0.0.1 на C
TUNNEL_KEY=/root/.ssh/id_ed25519_tunnel

# Web на C (публикация D-install.run)
WEB_IP=94.232.248.179
WEB_DIR_REMOTE=/var/www/html/mihomo
KEYS_DIR_REMOTE=/opt/mihomo/keys
D_INSTALL_TTL=28800             # 8 часов
```

`USERS_D` **не нужен** — прозрачный режим, пользователи ничего не настраивают.

Ключи (`UUID_D`, `UUID_DC`, `UUID_DB`, `PRIVATE_KEY_D`, `PUBLIC_KEY_D`,
`SHORT_ID_D`) генерируются `ensure_key D / DC / DB` в `build_D`.

## 4. Сборка (`scripts/build-servers.sh D --build`)

### 4.1 Что делает

1. `ensure_key D`, `ensure_key DC`, `ensure_key DB` — идемпотентно.
2. `fetch_kernel $ARCH_D` — использует `build/kernel/mihomo-linux-$ARCH_D-${MIHOMO_VERSION:-v1.19.14}`; ОС, архитектура и версия входят в ключ кэша, поэтому при смене версии скачивается новое ядро.
3. `GeoSite.dat`:
   - приоритет: `build/C/GeoSite.dat`;
   - fallback: `build/D/GeoSite.dat` (кэш);
   - fallback: скачать с RoscomVPN в `build/D/GeoSite.dat`;
   - если ничего — `fail`.
4. `geoip.metadb`:
   - приоритет: `build/C/geoip.metadb`;
   - fallback: `build/D/geoip.metadb`;
   - fallback: скачать с jsDelivr в `build/D/geoip.metadb`;
   - если ничего — предупреждение (mihomo скачает сам, если `geo-auto-update: true`).
5. `cn_cidr.txt` / `ru_cidr.txt`:
   - приоритет: `build/C/cn_cidr.txt` / `build/C/ru_cidr.txt`;
   - fallback: `build/D/…`;
   - fallback: скачать с `CN_CIDR_URL` / `RU_CIDR_URL` в `build/D/…`.
6. Рендер (с `GEO_MODE` в окружении):
   - `build/D/config.yaml` ← `template/config_D.yaml.j3` (с `{% if GEO_MODE == "local" %}`)
   - `build/D/mihomo.service` ← `template/mihomo-tproxy.service.j3`
   - `build/D/tunnel.service` ← `template/tunnel.service.j3`
   - `build/D/D-config` ← `template/D-config.j3`
   - `build/D/.env` ← `template/D-env.j3`
7. Валидация `mihomo -t -f build/D/config.yaml`.
8. Сборка `build/D/D-install.run` (shar-архив):
   ```
   D-install/
   ├── install.sh
   ├── D-config
   ├── env.sh          (из build/D/.env)
   ├── config.yaml
   ├── mihomo.service
   ├── tunnel.service
   ├── mihomo
   ├── entrypoint.sh
   ├── lib/env.sh
   ├── lib/http.sh
   ├── cn_cidr.txt
   ├── ru_cidr.txt
   ├── geosite.dat
   └── geoip.metadb
   ```
9. `build/D/D-install.run.sha256`.

### 4.2 Команда

```bash
scripts/build-servers.sh D --build
```

Выход:

```
build/D/config.yaml
build/D/mihomo.service
build/D/tunnel.service
build/D/D-config
build/D/.env
build/D/D-install.run
build/D/D-install.run.sha256
```

---

## 5. Публикация на C (`scripts/build-servers.sh D --publish`)

### 5.1 Что делает

1. Считает `sha256` от `build/D/D-install.run`.
2. `deploy_file` кладёт `D-install.run` в `$WEB_DIR_REMOTE/once/<hash>.run` на C.
3. `chmod 644`, `chown root:root`.
4. Запускает на C фоновый `sleep $D_INSTALL_TTL; rm -f …` (через `nohup` + `disown`).
5. Печатает URL и TTL.

### 5.2 Команда

```bash
scripts/build-servers.sh D --publish
```

Выход:

```
Публикация D-install.run на C:
  URL:  http://94.X.X.179/mihomo/once/a1b2c3…f9.run
  SHA256: a1b2c3…f9
  TTL:  28800 сек (8 ч)
  Удаление: автоматически через TTL

На D (без прямого доступа с A):
  curl -fsSL http://94.X.X.179/mihomo/once/a1b2c3…f9.run -o /tmp/D-install.run
  echo "a1b2c3…f9  /tmp/D-install.run" | sha256sum -c -
  sh /tmp/D-install.run
```

### 5.3 Проверка

```bash
curl -fsSL http://IP_C/mihomo/once/<hash>.run.sha256   # 404 (нет такого)
curl -fsSL http://IP_C/mihomo/once/<hash>.run | sha256sum   # совпадает с <hash>
```

---

## 6. Bootstrap D

Два канала доставки. Выбор — по наличию прямого SSH A → D.

### 6.1 Канал 1: прямой SSH A → D (если A видит D по LAN)

```bash
scripts/build-servers.sh D --build
scripts/D-setup.sh          # scp + ssh 'sh /tmp/D-install.run'
```

`D-setup.sh`:

```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/deploy/lib/env.sh"
load_env_file_literal "$PROJECT_ROOT/build/keys/params.env" || exit 1
: "${IP_D:?IP_D не задан}"

installer="$PROJECT_ROOT/build/D/D-install.run"
[[ -f "$installer" ]] || { echo "Нет $installer (сначала: scripts/build-servers.sh D --build)" >&2; exit 1; }

echo "==> Копирование $installer на D ($IP_D)"
scp -q "$installer" "root@$IP_D:/tmp/D-install.run"
echo "==> Запуск установщика на D"
ssh "root@$IP_D" 'sh /tmp/D-install.run'
```

### 6.2 Канал 2: через C (если A не видит D)

1. На A:
   ```bash
   scripts/build-servers.sh D --build
   scripts/build-servers.sh D --publish
   ```
   Получить `URL` и `SHA256`.

2. На D (оператор вручную или через любой доступ к D):
```bash
curl -fsSL "$URL" -o /tmp/D-install.run
echo "$SHA256  /tmp/D-install.run" | sha256sum -c -
curl -fsSL "$KEY_URL" -o /tmp/D-tunnel.key
chmod 600 /tmp/D-tunnel.key
sh /tmp/D-install.run --tunnel-key /tmp/D-tunnel.key
```
`KEY_URL` — из вывода `build-servers.sh D --publish` (`.../<hash>.key`).

### 6.3 Что делает `install.sh` (внутри `D-install.run`, на D)

1. Проверяет root, Linux, systemd.
2. Ставит пакеты: `openssh-client`, `nftables`, `curl`, `ca-certificates`, `tar`, `gzip`.
3. Раскладывает:
   - `/usr/local/bin/mihomo` (0755)
   - `$DIR_D/scripts/entrypoint.sh` (0755)
   - `$DIR_D/lib/env.sh`, `$DIR_D/lib/http.sh` (0644)
   - `$DIR_D/config.yaml` (0644)
   - `$DIR_D/.env` (0600)
   - `$DIR_D/GeoSite.dat` (0644) — **обязательно**
   - `$DIR_D/geoip.metadb` (0644) — если есть
   - `$DIR_D/cn_cidr.txt`, `$DIR_D/ru_cidr.txt` (0644) — если есть; иначе качает через `lib/http.sh`
   - `/etc/systemd/system/mihomo.service` (0644)
   - `/etc/systemd/system/tunnel.service` (0644)
   - `$DIR_D/D-config` (0644)
4. Генерирует ключ `D:/root/.ssh/id_ed25519_tunnel` (если нет).
5. Авторизует ключ на C:
   ```
   restrict,port-forwarding,permitlisten="127.0.0.1:2222" ssh-ed25519 AAAA…
   ```
6. Проверяет `GatewayPorts no` на C.
7. `systemctl daemon-reload && systemctl enable --now tunnel.service`.
8. `systemctl enable --now mihomo.service`.
9. **Тесты работоспособности:**
   - `systemctl is-active tunnel.service` — OK?
   - `systemctl is-active mihomo.service` — OK?
   - `ssh C "ss -tln | grep 127.0.0.1:2222"` — OK?
   - `ssh C "ss -tln | grep 0.0.0.0:2222"` — **не** OK (не должно быть).
   - `curl -x socks5://127.0.0.1:7890 -fsS https://www.google.com/generate_204` — OK?
   - `nft list table clash` — таблица есть?
   - `ip rule show | grep 'fwmark 0x1 lookup 100'` — правило есть?
   - `ss -tln | grep ':7893 '` — tproxy слушает?
   - `ss -tln | grep ':1053 '` — DNS слушает?
10. Печатает итог: `D установлен. Дальше с A: scripts/build-servers.sh D --deploy`.

### 6.4 Настройка клиентов LAN

После bootstrap:
1. На роутере LAN (или в DHCP) выставить **шлюз по умолчанию = `IP_D`** и **DNS = `IP_D`**.
2. Устройства LAN автоматически идут через D.
3. Проверка с устройства LAN:
   ```bash
   curl -fsS https://www.google.com/generate_204
   curl -fsS https://yandex.ru
   ```

---

## 7. Обновления (`scripts/build-servers.sh D --deploy`)

После bootstrap туннель работает, D доступен через `A → C → D`.

```bash
scripts/build-servers.sh D --build    # пересобрать артефакты
scripts/build-servers.sh D --deploy   # залить на D через ProxyCommand C
```

`deploy_D`:

```bash
SSH_D=(
  ssh
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
  -o "ProxyCommand=ssh -p $TUNNEL_C_PORT -o BatchMode=yes $TUNNEL_C_USER@$TUNNEL_C_HOST -W %h:%p"
  -p "$REMOTE_PORT_D"
)
target_D="root@localhost"

# 1. Ядро
deploy_file_d "build/kernel/mihomo-linux-$ARCH_D-${MIHOMO_VERSION:-v1.19.14}" /usr/local/bin/mihomo 0755
# 2. Config
deploy_file_d build/D/config.yaml $DIR_D/config.yaml 0644
# 3. .env
deploy_file_d build/D/.env $DIR_D/.env 0600
# 4. units
deploy_file_d build/D/mihomo.service /etc/systemd/system/mihomo.service 0644
deploy_file_d build/D/tunnel.service /etc/systemd/system/tunnel.service 0644
# 5. GeoSite
deploy_file_d build/D/GeoSite.dat $DIR_D/GeoSite.dat 0644
# 6. mihomo -t
ssh_d "mihomo -t -d $DIR_D -f $DIR_D/config.yaml"
# 7. restart
ssh_d "systemctl daemon-reload && systemctl restart mihomo.service"
# 8. тесты (как в 6.3 п.9)
```

> `tunnel.service` **не** перезапускается при `deploy_D` — только `mihomo.service`. Туннель стабилен; если нужно, `scripts/D-tunnel.sh restart` (на D) или `ssh_d systemctl restart tunnel.service`.

---

## 8. Диагностика

```bash
scripts/diagnose.sh            # A/B/C/D, локально + удалённо
scripts/diagnose.sh --no-remote  # только локальные артефакты
```

Проверки D:

### Локальные (на A)

- `build/D/config.yaml`, `mihomo.service`, `tunnel.service`, `D-config`, `D-install.run` — есть.
- `config.yaml` без `{{ }}` (отрендерен).
- `to-serverC.uuid == UUID_DC`, `to-serverB.uuid == UUID_DB`.
- `to-serverC.public-key == PUBLIC_KEY_C`, `to-serverB.public-key == PUBLIC_KEY_B`.
- `secret == SECRET_KEY_D`.
- `GEO_MODE` совпадает с `params.env`.
- При `GEO_MODE=local`: `config.yaml` содержит `GEOSITE,category-ru,DIRECT`.
- `tunnel.service` содержит `127.0.0.1:2222:localhost:22`, `-i`, `IdentitiesOnly=yes`; **не** содержит `0.0.0.0:2222`.

### Удалённые (через C)

- `A → C → D` через `ProxyCommand` работает.
- `systemctl is-active mihomo` OK.
- `systemctl is-active tunnel` OK.
- `nft list table clash` — таблица есть.
- `ip rule show | grep 'fwmark 0x1 lookup 100'`.
- `ss -tln | grep :7893` — tproxy.
- `ss -tln | grep :1053` — DNS.
- `mihomo -v` — версия.
- На C: `ss -tln | grep 127.0.0.1:2222` — OK; `ss -tln | grep 0.0.0.0:2222` — нет.

---

## 9. Troubleshooting

### 9.1 `tunnel.service` падает

```bash
ssh root@IP_D 'journalctl -u tunnel.service --no-pager -n 50'
```

Частые причины:
- `Permission denied (publickey)` — ключ D не авторизован на C. Перезапустить `install.sh --force-key` или вручную добавить `authorized_keys`.
- `remote port forwarding failed for listen port 2222` — порт на C занят. Проверить `ssh C 'ss -tlnp | grep 2222'`. Убить старый процесс или выбрать другой `TUNNEL_REMOTE_PORT`.
- `Connection refused` — C:22 недоступен с D. Проверить firewall на C и сеть D.

### 9.2 `mihomo.service` падает

```bash
ssh root@IP_D 'journalctl -u mihomo.service --no-pager -n 50'
```

Частые причины:
- `nft: command not found` — `nftables` не установлен. `install.sh` должен был поставить; проверить `which nft`.
- `GeoSite.dat not found` — файл не доложен. Проверить `$DIR_D/GeoSite.dat`.
- `config.yaml invalid` — `mihomo -t -d $DIR_D -f $DIR_D/config.yaml` покажет ошибку.

### 9.3 Порт 2222 на C открыт на 0.0.0.0

```bash
ssh C 'sshd -T | grep -i gatewayports'
```

Если `yes` — убрать из `/etc/ssh/sshd_config` (или явно `GatewayPorts no`), `systemctl reload sshd`. Затем `scripts/D-tunnel.sh restart` на D.

### 9.4 `A → C → D` не работает

```bash
# на A
ssh -o "ProxyCommand=ssh root@IP_C -W %h:%p" -p 2222 root@localhost 'hostname'
```

- `Permission denied` — ключ A → C не тот. Проверить `ssh-add -l`, `~/.ssh/config`.
- `Connection refused` — туннель D → C не поднят. `ssh root@IP_D 'systemctl status tunnel'`.
- `Host key verification failed` — `known_hosts` на A. `ssh-keygen -R '[localhost]:2222'`.

### 9.5 `GEO_MODE` не применился

Проверить `build/D/config.yaml`:
- `local` → есть `GEOSITE,category-ru,DIRECT`.
- `remote` → нет `GEOSITE,category-ru`, только `MATCH,PROXY`.

Если не совпадает — `GEO_MODE` не экспортирован перед `templater.sh`. Проверить `export GEO_MODE=…` в `build_D`.

---

## 10. Открытые вопросы

1. **`D_INSTALL_TTL`** — 8 часов (28800). Если нужно больше — изменить в `params.env`.
2. **`GEO_MODE`** — по умолчанию `local`. Если в LAN есть внешние пользователи, которым нужен весь трафик через C — `remote`.
3. **`GeoSite.dat`** — RoscomVPN (с `category-ru`). Обновление — вручную (пересобрать `build/C/GeoSite.dat` из upstream и выполнить `scripts/build-servers.sh D --build`).
4. **`geoip.metadb`** — если `build/C/geoip.metadb` нет, D качает с jsDelivr. Если нужен офлайн — положить в `build/C/geoip.metadb`.
5. **`--with-cidr` / `--with-geosite`** — убраны. Всё включено всегда. Уменьшение размера — потом (через `--minimal`).

---

## 11. Несколько экземпляров типа D

Общие значения по умолчанию остаются в `build/keys/params.env`. Для каждого
дополнительного шлюза создайте отдельный файл, например
`build/instances/D2.env`, скопировав
[`template/instances/D2.env.example`](../template/instances/D2.env.example).
Разрешённые подключения задаются независимо в `params.env`:

```dotenv
D_TO_B_INSTANCES="D D2"
D_TO_C_INSTANCES="D"
```

Это означает, что D и D2 имеют учётные записи на B, а на C — только D.
Каждый список может быть пустым, если для всех экземпляров настроено другое
направление. Экземпляр должен быть включён хотя бы в один список. По этим же
спискам конфиг самого D включает соответствующие VLESS-выходы на B и C.
Списки не управляют reverse SSH-туннелем D → C, который нужен для управления.
Если в старом `params.env` не заданы оба списка, сохраняется прежнее поведение:
экземпляр D подключается к B и C. Если задан только один список, второй считается
пустым — указывайте оба значения явно, чтобы конфигурация была однозначной.
ID должен начинаться с буквы или цифры и содержать только буквы, цифры и `_`.
Имена overlay-файлов в `build/instances/` образуют список настроенных
экземпляров; отдельный общий список экземпляров не нужен.
В нём указываются только отличия от общих параметров; при загрузке значения
из файла экземпляра переопределяют одноимённые значения `params.env`.

Файлы `params.env` и `instances/*.env` должны содержать только буквальные
значения. Записи `TUNNEL_C_HOST=${IP_C}` и `$IP_C` не поддерживаются.
Зависимые поля, например адрес jump-host и порт подключения A, вычисляются
сборщиком из настроек туннеля. Файл экземпляра содержит, например:

```dotenv
IP_D=192.168.10.90
PORT_D=7893
DIR_D=/opt/mihomo
ARCH_D=amd64
SECRET_KEY_D=replace-with-a-unique-secret
GEO_MODE=local
TUNNEL_C_HOST=94.232.248.179
TUNNEL_C_USER=root
TUNNEL_C_PORT=22
TUNNEL_REMOTE_PORT=2223
TUNNEL_KEY=/root/.ssh/id_ed25519_tunnel
```

Для всех экземпляров на одном C значение `TUNNEL_REMOTE_PORT` должно быть
уникальным. У каждого D должны быть собственные `IP_D` и `SECRET_KEY_D`.
Ключи Reality/UUID и ключ обратного SSH-туннеля сборщик создаёт отдельно
в `build/instances/`; не редактируйте и не коммитьте файлы ключей.

Проверка обнаруживает совпадающие адреса D, конфликтующие порты туннелей на
одном C, повторные каталоги/порты на одном D и повторное использование ключей
или `SECRET_KEY_D`.

Сборка, публикация и дальнейшее обновление экземпляра:

```bash
scripts/build-servers.sh D --instance D2 --check
# Сначала добавить сгенерированные учётные записи D2 на B и C:
scripts/build-servers.sh B --build --deploy
scripts/build-servers.sh C --build --deploy
# Затем собрать и опубликовать установщик D2:
scripts/build-servers.sh D --instance D2 --build
scripts/build-servers.sh D --instance D2 --publish
# После bootstrap обновлять D2 через его reverse SSH-туннель:
scripts/build-servers.sh D --instance D2 --deploy
```

Артефакты экземпляров разделены: конфиги и ключи лежат в `build/instances/`,
готовый комплект для развертывания — в `build/D2/`. Для D2 ключевые файлы —
`build/instances/D2.keys.env` и `build/instances/D2.tunnel.key`.
Команда без `--instance` сохраняет прежнее поведение для `D`.

---

## Смотрите также

- [deployment.md](deployment.md) — публикация A/B/C
- [configuration.md](configuration.md) — переменные `.env`
- [architecture.md](architecture.md) — структура проекта
- [recovery.md](recovery.md) — точки восстановления
- [troubleshooting.md](troubleshooting.md) — общие проблемы
