#!/bin/bash
# =============================================================================
# scripts/make-certificate.sh — генерация самоподписанного сертификата для hysteria-сервера на B
# Версия: 3.2.0   2026-11-5
# Автор: @smg38
#
# Использование (запускать на A):
#   scripts/make-certificate.sh
# Предусловия:
#   - build/keys/params.env содержит IP_B
#   - openssl установлен на A 
set -e
[ -f deploy/lib/env.sh ] && source deploy/lib/env.sh || { echo "Не найден deploy/lib/env.sh"; exit 1; }
env_get "build/keys/params.env" "IP_B"
# 1. Создание самоподписанного сертификата (действителен 10 лет, включает IP-адрес)
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout build/B/hysteria-server.key \
  -out build/B/hysteria-server.crt \
  -days 3650 \
  -subj "/CN=${IP_B}" \
  -addext "subjectAltName=IP:${IP_B}"
# 2. Предоставление прав доступа (если служба запускается от имени пользователя hysteria)
# sudo chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt
echo -e "HY2_PASSWORD=$(openssl rand -hex 16)\nHY2_OBFS_PASSWORD=$(openssl rand -hex 16)"