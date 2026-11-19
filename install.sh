#!/usr/bin/env bash
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Запустите скрипт от root (sudo bash install.sh)"; exit 1; }

read -rp "Ваш домен (например, sub.example.com): " DOMAIN
read -rp "Локальный порт JSON-подписки 3x-ui (Enter — если 3x-ui не используется): " XUI_PORT

apt-get update && apt-get install -y jq python3 curl

install -m 755 bin/*.sh /usr/local/bin/
install -m 755 bin/sublinks.py /usr/local/bin/

mkdir -p /etc/merge-sub /var/www/subjson /var/www/frozen /etc/nginx/merge-sub

XUI_URL=""
[ -n "$XUI_PORT" ] && XUI_URL="http://127.0.0.1:$XUI_PORT/jsonjsonjson"

cat > /etc/merge-sub/settings.conf <<EOF
PUBLIC_HOST="$DOMAIN"
XUI="$XUI_URL"
CURL_INSECURE=0
TITLE=""
ANNOUNCE=""
INTERVAL=1
SUPPORT_URL=""
WEB_URL=""
EOF

(crontab -l 2>/dev/null | grep -vE 'merge-json\.sh|freeze-sub\.sh'; \
 echo "*/10 * * * * /usr/local/bin/freeze-sub.sh --refresh >/dev/null 2>&1"; \
 echo "*/10 * * * * /usr/local/bin/merge-json.sh >/dev/null 2>&1") | crontab -

echo "Установка завершена! Добавьте 'include /etc/nginx/merge-sub/*.conf;' в конфиг Nginx и запустите 'sub.sh'."