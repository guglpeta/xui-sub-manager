#!/usr/bin/env bash
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Р—Р°РїСѓСЃС‚РёС‚Рµ СЃРєСЂРёРїС‚ РѕС‚ root (sudo bash install.sh)"; exit 1; }

read -rp "Р’Р°С€ РґРѕРјРµРЅ (РЅР°РїСЂРёРјРµСЂ, sub.example.com): " DOMAIN
DOMAIN=$(printf '%s' "$DOMAIN" | tr -d '[:space:]')
[ -n "$DOMAIN" ] || { echo "Р”РѕРјРµРЅ РЅРµ РјРѕР¶РµС‚ Р±С‹С‚СЊ РїСѓСЃС‚С‹Рј."; exit 1; }

read -rp "Р›РѕРєР°Р»СЊРЅС‹Р№ РїРѕСЂС‚ JSON-РїРѕРґРїРёСЃРєРё 3x-ui (Enter вЂ” РµСЃР»Рё 3x-ui РЅРµ РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ): " XUI_PORT
XUI_PORT=$(printf '%s' "$XUI_PORT" | tr -d '[:space:]')

read -rp "РџРѕСЂС‚ РґР»СЏ СЂР°Р·РґР°С‡Рё РїРѕРґРїРёСЃРѕРє [443]: " SUB_PORT
SUB_PORT=${SUB_PORT:-443}

export DEBIAN_FRONTEND=noninteractive
NEED_PKGS=()
for pkg in jq python3 curl cron util-linux nginx certbot python3-certbot-nginx; do
  dpkg -s "$pkg" >/dev/null 2>&1 || NEED_PKGS+=("$pkg")
done
if [ ${#NEED_PKGS[@]} -gt 0 ]; then
  apt-get -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 update || true
  apt-get -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 install -y "${NEED_PKGS[@]}"
fi

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

# --- РђРІС‚РѕРјР°С‚РёС‡РµСЃРєР°СЏ РЅР°СЃС‚СЂРѕР№РєР° Nginx ---
EXISTING_CONF=$(grep -rlE "server_name[[:space:]]+([^;]*[[:space:]])?${DOMAIN}([[:space:]]|;)" /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "merge-sub-${DOMAIN}\.conf" | head -n1 || true)

if [ -n "$EXISTING_CONF" ]; then
  echo "РќР°Р№РґРµРЅ СЃСѓС‰РµСЃС‚РІСѓСЋС‰РёР№ РєРѕРЅС„РёРі Nginx РґР»СЏ $DOMAIN: $EXISTING_CONF"
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
    echo "Р”РёСЂРµРєС‚РёРІС‹ РґРѕР±Р°РІР»РµРЅС‹ РІ $EXISTING_CONF (СЂРµР·РµСЂРІРЅР°СЏ РєРѕРїРёСЏ: ${EXISTING_CONF}.bak-merge-sub)."
  else
    echo "РџРѕРґРєР»СЋС‡РµРЅРёРµ merge-sub СѓР¶Рµ РїСЂРёСЃСѓС‚СЃС‚РІСѓРµС‚ РІ $EXISTING_CONF."
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
  read -rp "Р’С‹РїСѓСЃС‚РёС‚СЊ Р±РµСЃРїР»Р°С‚РЅС‹Р№ SSL-СЃРµСЂС‚РёС„РёРєР°С‚ Let's Encrypt С‡РµСЂРµР· Certbot РґР»СЏ $DOMAIN? [Y/n]: " DO_SSL
  if [[ ! "${DO_SSL,,}" =~ ^(n|РЅ)$ ]]; then
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect || {
      echo "вљ  Certbot РЅРµ СЃРјРѕРі Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё РІС‹РїСѓСЃС‚РёС‚СЊ СЃРµСЂС‚РёС„РёРєР°С‚ (РїСЂРѕРІРµСЂСЊ DNS A-Р·Р°РїРёСЃСЊ РґРѕРјРµРЅР° Рё РґРѕСЃС‚СѓРїРЅРѕСЃС‚СЊ 80 РїРѕСЂС‚Р°)."
    }
    if [ "$SUB_PORT" != "443" ] && grep -q "listen 443 ssl" "$NGX_AVAIL"; then
      sed -i "s/listen 443 ssl/listen ${SUB_PORT} ssl/" "$NGX_AVAIL"
    fi
  fi
fi

if nginx -t; then
  systemctl reload nginx
  echo "Nginx СѓСЃРїРµС€РЅРѕ РЅР°СЃС‚СЂРѕРµРЅ Рё РїРµСЂРµР·Р°РіСЂСѓР¶РµРЅ."
else
  echo "вљ  РћС€РёР±РєР° РїСЂРѕРІРµСЂРєРё РєРѕРЅС„РёРіСѓСЂР°С†РёРё Nginx (nginx -t). РџСЂРѕРІРµСЂСЊС‚Рµ РєРѕРЅС„РёРі РІСЂСѓС‡РЅСѓСЋ."
fi

# --- РќР°СЃС‚СЂРѕР№РєР° Cron ---
(crontab -l 2>/dev/null | grep -vE 'merge-json\.sh|freeze-sub\.sh' || true; \
 echo "*/10 * * * * /usr/local/bin/freeze-sub.sh --refresh >/dev/null 2>&1"; \
 echo "*/10 * * * * /usr/local/bin/merge-json.sh >/dev/null 2>&1") | crontab -

echo
echo "РЈСЃС‚Р°РЅРѕРІРєР° Р·Р°РІРµСЂС€РµРЅР°! Р—Р°РїСѓСЃС‚РёС‚Рµ 'sub.sh' РґР»СЏ СѓРїСЂР°РІР»РµРЅРёСЏ РїРѕРґРїРёСЃРєР°РјРё."