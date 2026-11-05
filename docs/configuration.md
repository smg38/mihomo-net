# Конфигурация

[← Назад к README](../README.md)

## Файл .env

Расположение: `REMOTE_DIR/.env` (продакшн) или `.tmp/.env` (локальная сборка).

Существующий удалённый `.env` **не перезаписывается**. Локальная конфигурация
загружается только при первом развёртывании.

### Переменные

| Переменная | По умолчанию | Описание |
|---|---|---|
| `MIHOMO_SECRET` | — | Ключ панели управления. Пусто = доступ только с `127.0.0.1` |
| `CONFIG_URL` | — | URL подписки |
| `SKIP_CNIP` | `true` | Обход китайских IP |
| `SKIP_RUIP` | `false` | Обход российских IP |
| `QUIC` | `true` | Разрешить QUIC |
| `LOCAL_LOOPBACK_PROXY` | `false` | Прозрачный прокси для локального трафика |
| `PORT` | `8000` | Порт веб-панели |
| `GITHUB_PROXY` | — | Префикс для загрузки с GitHub |
| `GITHUB_API_PROXY` | — | Префикс для GitHub API |
| `DOWNLOAD_DOH_SERVERS` | `dns.alidns.com:223.5.5.5 cloudflare-dns.com:1.1.1.1` | DoH-серверы |
| `DOWNLOAD_PROGRESS` | `auto` | `auto`, `bar`, `off` |
| `CN_CIDR_URL` | gaoyifan/... | Источник китайских IP |
| `RU_CIDR_URL` | herrbischoff/... | Источник российских IP |

## Переопределения конфигурации

Поверх подписки применяются фиксированные переопределения через `yq`:

```yaml
dns.listen: 0.0.0.0:1053
bind-address: "*"
iptables.enable: false
routing-mark: 255
external-ui: ui
external-controller: 0.0.0.0:9900
secret: ${MIHOMO_SECRET}
tproxy-port: 7893
mixed-port: 7890
port: 7895
socks-port: 7896
allow-lan: true
```

## Провайдеры

Поддерживаются `rule-providers` и `proxy-providers` типов `http`, `file`, `inline`.

- HTTP-провайдеры кэшируются в `.update-state/providers/`
- Семантика `interval`, `header`, автообновления сохраняется
- Предварительная выборка использует независимый DNS и хост-сеть
- Не вызывает именованные прокси из конфигурации-кандидата

### Ограничения

| Ресурс | Лимит |
|---|---|
| Один файл provider | 16 MiB |
| Общий размер снимка | 64 MiB |
| Параллельных загрузок | 4 |

### Безопасность путей

Пути provider должны находиться внутри каталога развёртывания. Запрещено:

- Символические ссылки
- Выход за пределы каталога
- Перезапись программ, конфигурации, метаданных транзакций

## Сохранение через веб-панель

Панель позволяет редактировать через `POST /save_settings`:

- `SKIP_CNIP`, `SKIP_RUIP`, `QUIC`, `LOCAL_LOOPBACK_PROXY`
- `CONFIG_URL`
- `GITHUB_PROXY`, `GITHUB_API_PROXY`
- `MIHOMO_SECRET` (пустое значение не перезаписывает)

После сохранения автоматически запускается обновление подписки.

## Смотрите также

- [http-download.md](http-download.md) — загрузка и DoH
- [deployment.md](deployment.md) — публикация