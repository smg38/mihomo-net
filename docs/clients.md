# Импорт подписки на клиентах

[← Назад к README](../README.md)

## Android

**Clash Meta for Android** или **FlClash**:

1. Установить приложение
2. Профили → Добавить
3. Вставить URL: `https://sub.example.com/user1.yaml`
4. Импорт → активировать профиль
5. Разрешить VPN-подключение в системном диалоге

## iOS

**Stash** (App Store) или **Shadowrocket**:

1. Установить Stash
2. Профили → `+` → Подписка
3. Вставить URL → Импорт
4. Выбрать профиль → Подключить

## Windows

**Clash Verge Rev**, **Mihomo Party** или **Hiddify**:

1. Скачать и установить
2. Профили → Импорт
3. Вставить URL → выбрать профиль → Активировать

## macOS

- Clash Verge Rev или Mihomo Party — как на Windows
- Либо Stash через App Store

## Linux

- Clash Verge Rev (AppImage / deb / rpm)
- Mihomo Party
- Вручную:
  ```bash
  cp config.yaml ~/.config/mihomo/config.yaml
  mihomo -d ~/.config/mihomo
  ```

## Роутеры (OpenWrt)

```bash
opkg install mihomo
cp config.yaml /etc/mihomo/config.yaml
uci set mihomo.config=...
service mihomo start
```

Либо **OpenClash**, **PassWall**, **ShellClash** — умеют импортировать по URL.

## TV, консоли, устройства без VPN-клиента

Через режим шлюза:

1. Включите прозрачный прокси на сервере:
   ```
   SKIP_CNIP=true
   LOCAL_LOOPBACK_PROXY=false
   ```
2. Раздайте IP сервера как шлюз и DNS
3. Все устройства в сети автоматически идут через прокси

## Смотрите также

- [configuration.md](configuration.md) — переменные `.env`
- [architecture.md](architecture.md) — режимы прокси# Импорт подписки на клиентах

[← Назад к README](../README.md)

## Android

**Clash Meta for Android** или **FlClash**:

1. Установить приложение
2. Профили → Добавить
3. Вставить URL: `https://sub.example.com/user1.yaml`
4. Импорт → активировать профиль
5. Разрешить VPN-подключение в системном диалоге

## iOS

**Stash** (App Store) или **Shadowrocket**:

1. Установить Stash
2. Профили → `+` → Подписка
3. Вставить URL → Импорт
4. Выбрать профиль → Подключить

## Windows

**Clash Verge Rev**, **Mihomo Party** или **Hiddify**:

1. Скачать и установить
2. Профили → Импорт
3. Вставить URL → выбрать профиль → Активировать

## macOS

- Clash Verge Rev или Mihomo Party — как на Windows
- Либо Stash через App Store

## Linux

- Clash Verge Rev (AppImage / deb / rpm)
- Mihomo Party
- Вручную:
  ```bash
  cp config.yaml ~/.config/mihomo/config.yaml
  mihomo -d ~/.config/mihomo
  ```

## Роутеры (OpenWrt)

```bash
opkg install mihomo
cp config.yaml /etc/mihomo/config.yaml
uci set mihomo.config=...
service mihomo start
```

Либо **OpenClash**, **PassWall**, **ShellClash** — умеют импортировать по URL.

## TV, консоли, устройства без VPN-клиента

Через режим шлюза:

1. Включите прозрачный прокси на сервере:
   ```
   SKIP_CNIP=true
   LOCAL_LOOPBACK_PROXY=false
   ```
2. Раздайте IP сервера как шлюз и DNS
3. Все устройства в сети автоматически идут через прокси

## Смотрите также

- [configuration.md](configuration.md) — переменные `.env`
- [architecture.md](architecture.md) — режимы прокси