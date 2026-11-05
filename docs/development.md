# Разработка

[← Назад к README](../README.md)

## Требования

- [mise](https://mise.jdx.dev/getting-started.html)
- Go 1.26.8 (управляется mise)

## Установка

```bash
mise trust
mise install
```

`mise.toml` и `go.mod` объявляют одну и ту же версию Go.
`GOTOOLCHAIN=local` фиксирует использование компилятора, предоставляемого mise.

## Команды

```bash
mise run build       # Сборка локального артефакта
mise run dev         # Запуск сервиса разработки
mise run test        # go test -race ./...
mise run vet         # go vet ./...
mise run build-all   # Артефакты amd64, arm64 для Linux/macOS
```

## Локальная сборка и запуск

```bash
./build-local.sh           # собрать всё
./build-local.sh start     # запустить ядро + менеджер
./build-local.sh stop
./build-local.sh restart
./build-local.sh status
./build-local.sh logs
./build-local.sh test-sub
./build-local.sh clean
```

## Ручная кросс-компиляция

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  mise exec -- go build -o .tmp/mihomo-manager-linux-amd64 ./cmd/mihomo-manager
```

## Приёмка

### С реальным ядром

```bash
export MIHOMO_TEST_BINARY=/абсолютный/путь/к/mihomo
export YQ_TEST_BINARY=/абсолютный/путь/к/yq
mise run test
```

Обращается к локальной тестовой HTTPS-точке через реальный Mihomo,
**не изменяет** брандмауэр и **не обращается** к публичной сети.

### Браузерная приёмка

```bash
export MIHOMO_UI_ACCEPTANCE=1
export MIHOMO_UI_ACCEPTANCE_STOP=/абсолютный/путь/к/маркеру
mise exec -- go test ./internal/manager -run '^TestUIAcceptanceServer$' -v -timeout 4m
```

Откройте напечатанный локальный URL, используйте тестовый ключ `example`,
нажмите обновление. Ожидается отображение успешного отката после сбоя
5-секундной проверки. После подтверждения создайте файл-маркер остановки.

Для проверки сбоя скрипта подготовки:

```bash
export MIHOMO_UI_ACCEPTANCE_FAILURE=1
```

Ожидается закрытие прогресса после завершения обновления и отчёт об
отклонении обновления через всплывающее уведомление.

## Требования к тестам

Реальная приёмка systemd, nftables и сети Google требует тестового
сервера Linux.

## Смотрите также

- [architecture.md](architecture.md) — структура проекта
- [deployment.md](deployment.md) — публикация