#!/usr/bin/env bash
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Запустите скрипт от root (sudo bash install.sh)"; exit 1; }

read -rp "Ваш домен (например, sub.example.com): " DOMAIN
DOMAIN=$(printf '\%s' "$DOMAIN" | tr -d '[:space:]')
[ -n "$DOMAIN" ] || { echo "Домен не может быть пустым."; exit 1; }

read -rp "Локальный порт JSON-подписки 3x-ui (Enter — если 3x-ui не используется): " XUI_PORT
XUI_PORT=$(printf '\%s' "$XUI_PORT" | tr -d '[:space:]')

read -rp "Порт для раздачи подписок [443]: " SUB_PORT
SUB_PORT=${SUB_PORT:-443}

apt-get update && apt-get install -y jq python3 curl nginx certbot python3-certbot-nginx

install -m 755 bin/*.sh /usr/local/bin/
install -m 755 bin/sublinks.py /usr/local/bin/

mkdir -p /etc/merge-sub /var/www/subjson /var/www/frozen /etc/nginx/merge-sub

XUI_URL=""
[ -n "$XUI_PORT" ] && XUI_URL="[http://127.0.0.1](http://127.0.0.1):$XUI_PORT/jsonjsonjson"

if [ "$SUB_PORT" = "443" ]; then
  FROZEN_BASE_URL="https://$DOMAIN/frozen"
else
  FROZEN_BASE_URL="https://$DOMAIN:$SUB_PORT/frozen"
fi

cat > /etc/merge-sub/settings.conf <<EOF "server_name[[:space:]]+([^;]*[[:space:]])?${DOMAIN}([[:space:]]|;)" # --- -rlE /etc/nginx/sites-enabled/ 2 ANNOUNCE CURL_INSECURE="0" EOF EXISTING_CONF="$(grep" FROZEN_BASE="$FROZEN_BASE_URL" INTERVAL="1" Nginx PUBLIC_HOST="$DOMAIN" SUPPORT_URL TITLE WEB_URL XUI="$XUI_URL" Автоматическая настройка>/dev/null | head -n1 || true)

if [ -n "$EXISTING_CONF" ]; then
  echo "Найден существующий конфиг Nginx для $DOMAIN:$EXISTING_CONF"
  if ! grep -q 'merge-sub/\*\.conf' "$EXISTING_CONF"; then
    cp "$EXISTING_CONF" "${EXISTING_CONF}.bak-merge-sub"
    XUI_FALLBACK=""
    if [ -n "$XUI_PORT" ] && ! grep -q 'location /subscription/' "$EXISTING_CONF"; then
      XUI_FALLBACK="\n    location /subscription/ {\n        proxy_pass [http://127.0.0.1](http://127.0.0.1):${XUI_PORT}/sub/;\n        proxy_set_header Host \$host;\n        proxy_set_header X-Forwarded-Host \$host;\n    }"
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
        proxy_pass [http://127.0.0.1](http://127.0.0.1):${XUI_PORT}/sub/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
    }"
  fi

  cat > "$NGX_AVAIL" <<EOF !="443" " "$DOMAIN" "$NGX_AVAIL" "$NGX_AVAIL"; "$NGX_ENAB" "$SUB_PORT" "${DO_SSL,,}"="~" "Nginx "listen "s/listen "Выпустить "⚠ # $DOMAIN; $DOMAIN? $XUI_BLOCK${SUB_PORT} && (crontab (nginx (проверь --- --agree-tos --nginx --non-interactive --redirect --register-unsafely-without-email -d -i -l -q -rp -sf -t -t). -t; /etc/nginx/merge-sub/*.conf; 2 443 80)." 80; A-запись Certbot Cron DNS DO_SSL EOF Encrypt Let's Nginx SSL-сертификат [ [Y/n]: [[ ] ]]; ^(n|н)$ certbot echo else fi grep if include listen ln nginx read reload sed server server_name ssl" ssl/" ssl/listen systemctl then { || } Настройка Ошибка Проверьте автоматически бесплатный вручную." выпустить для домена и конфиг конфигурации настроен не перезагружен." порт проверки сертификат смог успешно через>/dev/null | grep -vE 'merge-json\.sh|freeze-sub\.sh'; \
 echo "*/10 * * * * /usr/local/bin/freeze-sub.sh --refresh >/dev/null 2>&1"; \
 echo "*/10 * * * * /usr/local/bin/merge-json.sh >/dev/null 2>&1") | crontab -

echo
echo "Установка завершена! Запустите 'sub.sh' для управления подписками."