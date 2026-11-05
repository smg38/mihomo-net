# HTTP API менеджера

[← Назад к README](../README.md)

## Аутентификация

- Если `MIHOMO_SECRET` не задан — доступ только с `127.0.0.1`/`::1`
- Если задан — заголовок `X-Mihomo-Secret` или ключ при входе

## Эндпоинты

### `GET /`

Встроенная страница управления (`go:embed`), независима от рабочего каталога.

### `GET /logs`

Поток событий NDJSON:

```json
{"type": "log", "time": "2026-10-05T12:00:00Z", "level": "info", "message": "..."}
{"type": "error", "message": "journalctl завершился: ..."}
```

- Последние 1000 записей, затем сопровождение
- Бэкенд разбирает формат Logrus Mihomo
- Нераспознанные записи сохраняют исходный текст и время journal

### `POST /reload`

Запуск обновления конфигурации. Возвращает `HTTP 202` и ID задачи:

```json
{"id": "a1b2c3..."}
```

### `GET /update_status`

Текущая или последняя задача:

```json
{
  "id": "...",
  "stage": "probing",
  "running": true,
  "result": "",
  "message": "...",
  "baseline": true,
  "candidate_hash": "...",
  "updated_at": "..."
}
```

### `GET /get_settings`

Текущие настройки из `.env` (без `MIHOMO_SECRET`):

```json
{"success": true, "data": {"CONFIG_URL": "...", "QUIC": "true"}}
```

### `POST /save_settings`

Сохранение настроек. Допустимые ключи:

```
SKIP_CNIP, SKIP_RUIP, QUIC, LOCAL_LOOPBACK_PROXY,
CONFIG_URL, GITHUB_PROXY, GITHUB_API_PROXY, MIHOMO_SECRET
```

### `POST /check_secret`

Проверка ключа:

```json
{"secret": "..."}
→ {"success": true}
```

## Смотрите также

- [configuration.md](configuration.md) — переменные `.env`
- [cli-cron.md](cli-cron.md) — CLI-эквиваленты