#!/usr/bin/env bash
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Запустите скрипт от root (sudo bash install.sh)"; exit 1; }

read -rp "Ваш домен (например, sub.example.com): " DOMAIN
DOMAIN=$(printf '%s' "$DOMAIN" | tr -d '[:space:]')
[ -n "$DOMAIN" ] || { echo "Домен не может быть пустым."; exit 1; }

read -rp "Локальный порт JSON-подписки 3x-ui (Enter — если 3x-ui не используется): " XUI_PORT
XUI_PORT=$(printf '%s' "$XUI_PORT" | tr -d '[:space:]')

read -rp "Порт для раздачи подписок [443]: " SUB_PORT
SUB_PORT=${SUB_PORT:-443}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y jq python3 curl cron util-linux nginx certbot python3-certbot-nginx

systemctl enable --now cron
systemctl enable --now nginx

install -m 755 bin/*.sh /usr/local/bin/
install -m 755 bin/sublinks.py /usr/local/bin/

mkdir -p /etc/merge-sub /var/www/subjson /var/www/frozen /etc/nginx/merge-sub

XUI_URL=""
[ -n "$XUI_PORT" ] && XUI_URL="http://127.0.0.1:$XUI_PORT/jsonjsonjson"

if [ "$SUB_PORT" = "443" ]; then
  FROZEN_BASE_URL="https://$DOMAIN/frozen"
else
  FROZEN_BASE_URL="https://$DOMAIN:$SUB_PORT/frozen"
fi

cat > /etc/merge-sub/settings.conf <<EOF
PUBLIC_HOST="$DOMAIN"
FROZEN_BASE="$FROZEN_BASE_URL"
XUI="$XUI_URL"
CURL_INSECURE=0
TITLE=""
ANNOUNCE=""
INTERVAL=1
SUPPORT_URL=""
WEB_URL=""
EOF

# --- Автоматическая настройка Nginx ---
EXISTING_CONF=$(grep -rlE "server_name[[:space:]]+([^;]*[[:space:]])?${DOMAIN}([[:space:]]|;)" /etc/nginx/sites-enabled/ 2>/dev/null | head -n1 || true)

if [ -n "$EXISTING_CONF" ]; then
  echo "Найден существующий конфиг Nginx для $DOMAIN: $EXISTING_CONF"
  if ! grep -q 'merge-sub/\*\.conf' "$EXISTING_CONF"; then
    cp "$EXISTING_CONF" "${EXISTING_CONF}.bak-merge-sub"
    XUI_FALLBACK=""
    if [ -n "$XUI_PORT" ] && ! grep -q 'location /subscription/' "$EXISTING_CONF"; then
      XUI_FALLBACK="\n    location /subscription/ {\n        proxy_pass http://127.0.0.1:${XUI_PORT}/sub/;\n        proxy_set_header Host \$host;\n        proxy_set_header X-Forwarded-Host \$host;\n    }"
    fi
    awk -v dom="$DOMAIN" -v fb="$XUI_FALLBACK" '
      { print }
      $0 ~ "server_name.*" dom && !done {
        print "    include /etc/nginx/merge-sub/*.conf;"
        if (fb != "") { gsub(/\\n/, "\n", fb); print fb }
        done=1
      }
    ' "${EXISTING_CONF}.bak-merge-sub" > "$EXISTING_CONF"
    echo "Директивы добавлены в $EXISTING_CONF (резервная копия: ${EXISTING_CONF}.bak-merge-sub)."
  else
    echo "Подключение merge-sub уже присутствует в $EXISTING_CONF."
  fi
else
  NGX_AVAIL="/etc/nginx/sites-available/merge-sub-${DOMAIN}.conf"
  NGX_ENAB="/etc/nginx/sites-enabled/merge-sub-${DOMAIN}.conf"

  XUI_BLOCK=""
  if [ -n "$XUI_PORT" ]; then
    XUI_BLOCK="
    location /subscription/ {
        proxy_pass http://127.0.0.1:${XUI_PORT}/sub/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
    }"
  fi

  cat > "$NGX_AVAIL" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    include /etc/nginx/merge-sub/*.conf;
$XUI_BLOCK
}
EOF
  ln -sf "$NGX_AVAIL" "$NGX_ENAB"
  nginx -t && systemctl reload nginx

  echo
  read -rp "Выпустить бесплатный SSL-сертификат Let's Encrypt через Certbot для $DOMAIN? [Y/n]: " DO_SSL
  if [[ ! "${DO_SSL,,}" =~ ^(n|н)$ ]]; then
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect || {
      echo "⚠ Certbot не смог автоматически выпустить сертификат (проверь DNS A-запись домена и доступность 80 порта)."
    }
    if [ "$SUB_PORT" != "443" ] && grep -q "listen 443 ssl" "$NGX_AVAIL"; then
      sed -i "s/listen 443 ssl/listen ${SUB_PORT} ssl/" "$NGX_AVAIL"
    fi
  fi
fi

if nginx -t; then
  systemctl reload nginx
  echo "Nginx успешно настроен и перезагружен."
else
  echo "⚠ Ошибка проверки конфигурации Nginx (nginx -t). Проверьте конфиг вручную."
fi

# --- Настройка Cron ---
(crontab -l 2>/dev/null | grep -vE 'merge-json\.sh|freeze-sub\.sh' || true; \
 echo "*/10 * * * * /usr/local/bin/freeze-sub.sh --refresh >/dev/null 2>&1"; \
 echo "*/10 * * * * /usr/local/bin/merge-json.sh >/dev/null 2>&1") | crontab -

echo
echo "Установка завершена! Запустите 'sub.sh' для управления подписками."