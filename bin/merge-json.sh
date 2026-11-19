#!/usr/bin/env bash
# Склеивает свои прокси (local.json) с JSON-подпиской 3x-ui для каждого клиента из clients.txt
# и генерирует для nginx заголовки подписки (название, описание, трафик/срок).
# Запускается по cron и автоматически из clients.sh / add-proxy.sh.
set -uo pipefail

DIR=/etc/merge-sub
LOCAL=$DIR/local.json
CLIENTS=$DIR/clients.txt          # строки: subId|приписка|название|описание|группы
GRPFILE=$DIR/groups.json           # группы серверов (groups.sh)
SETTINGS=$DIR/settings.conf
CACHE=$DIR/userinfo               # последний известный трафик/срок клиента
OUTDIR=/var/www/subjson
NGX=/etc/nginx/merge-sub/clients.conf

# Значения по умолчанию (переопределяются в settings.conf)
XUI="http://127.0.0.1:PORT_3XUI/jsonjsonjson"
CURL_INSECURE=0
TITLE=""; ANNOUNCE=""; INTERVAL=1; SUPPORT_URL=""; WEB_URL=""
[ -f "$SETTINGS" ] && . "$SETTINGS"

mkdir -p "$OUTDIR" "$CACHE" "$(dirname "$NGX")"
[ -f "$CLIENTS" ] || touch "$CLIENTS"
[ -f "$LOCAL" ]   || echo '[]' > "$LOCAL"
[ -f "$GRPFILE" ]  || echo '{}' > "$GRPFILE"

if ! jq -e 'type=="array"' "$LOCAL" >/dev/null 2>&1; then
  echo "Ошибка: $LOCAL — не JSON-массив, ничего не обновляю" >&2
  exit 1
fi

# 3x-ui подставляет адрес сервера в конфиги из адреса запроса — говорим ему публичный домен,
# иначе в VLESS окажется 127.0.0.1
PUBLIC_HOST=${PUBLIC_HOST:-example.com}
CURL=(curl -fsS --connect-timeout 5 --max-time 15 -H "Host: $PUBLIC_HOST" -H "X-Forwarded-Host: $PUBLIC_HOST")
[ "$CURL_INSECURE" = 1 ] && CURL+=(-k)
b64()   { printf '%s' "$1" | base64 -w0; }
clean() { printf '%s' "$1" | tr -d '"$\\\r\n'; }   # чтобы не сломать конфиг nginx

# Один запуск за раз: cron + ручной запуск/меню не должны накладываться и ждать таймауты друг за другом
exec 9>/run/merge-json.lock
if ! flock -w 90 9; then
  echo "merge-json.sh уже выполняется больше 90 с — пропускаю этот запуск" >&2
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ok=0; fail=0
: > "$TMP/ngx"

while IFS='|' read -r SUBID NOTE CTITLE CANN CGROUPS _; do
  SUBID=$(printf '%s' "$SUBID" | tr -d '[:space:]')
  [[ -z "$SUBID" || "$SUBID" == \#* ]] && continue
  [[ "$SUBID" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "  ! пропускаю некорректный subId '$SUBID'" >&2; continue; }

  if "${CURL[@]}" -D "$TMP/hdr" -o "$TMP/raw" "$XUI/$SUBID" 2>/dev/null \
     && jq 'if type=="array" then . else [.] end' "$TMP/raw" > "$TMP/remote" 2>/dev/null; then
    # Без групп — всё; с группами — только их прокси и (если отмечено) сервера 3x-ui
    jq -n --slurpfile L "$LOCAL" --slurpfile R "$TMP/remote" --slurpfile G "$GRPFILE" \
          --arg cg "${CGROUPS:-}" '
      ($cg | split(",") | map(select(length>0))) as $want
      | if ($want | length) == 0 then $L[0] + $R[0]
        else
          ($want | map($G[0][.]) | map(select(. != null))) as $gs
          | ($gs | map(.proxies) | add // []) as $names
          | [ $L[0][] | select(.remarks as $r | $names | index($r)) ]
            + (if ($gs | any(.xui)) then $R[0] else [] end)
        end' > "$TMP/merged"
    IFS=, read -ra _gl <<< "${CGROUPS:-}"
    for g in "${_gl[@]+"${_gl[@]}"}"; do
      [ -n "$g" ] || continue
      jq -e --arg g "$g" 'has($g)' "$GRPFILE" >/dev/null || echo "  ! $SUBID: группы «$g» нет в groups.json" >&2
    done
    [ "$(jq length "$TMP/merged")" -gt 0 ] || echo "  ! $SUBID: в его группах нет ни одного сервера — подписка пустая" >&2
    # freeze-sub: подписки провайдеров клиента
    if [ -x /usr/local/bin/freeze-sub.sh ] && [ -s /etc/merge-sub/client-subs.txt ]; then
      xsubs=$(awk -F"|" -v s="$SUBID" '$1==s{print $2}' /etc/merge-sub/client-subs.txt)
      if [ -n "$xsubs" ] && /usr/local/bin/freeze-sub.sh --json "$xsubs" > "$TMP/xsubs" \
         && jq -e 'type=="array"' "$TMP/xsubs" >/dev/null 2>&1; then
        jq -s 'add' "$TMP/merged" "$TMP/xsubs" > "$TMP/merged2" && mv "$TMP/merged2" "$TMP/merged"
      fi
    fi
    # order-sub: порядок серверов клиента
    [ -x /usr/local/bin/order-sub.sh ] && /usr/local/bin/order-sub.sh --apply "$SUBID" "$TMP/merged" || true
    install -m 644 "$TMP/merged" "$OUTDIR/$SUBID.json"
    grep -i '^subscription-userinfo:' "$TMP/hdr" | cut -d: -f2- | tr -d '\r' | sed 's/^ *//' > "$CACHE/$SUBID" || true
    ok=$((ok+1))
  else
    echo "  ! $SUBID: 3x-ui не отдал подписку, оставляю как было" >&2
    fail=$((fail+1))
  fi

  # Нет файла — нет и location: клиент получит обычную подписку 3x-ui
  [ -f "$OUTDIR/$SUBID.json" ] || continue

  t=${CTITLE:-$TITLE}; a=${CANN:-$ANNOUNCE}
  info=$(clean "$(cat "$CACHE/$SUBID" 2>/dev/null)")
  {
    echo "location = /subscription/$SUBID {"
    echo "    alias $OUTDIR/$SUBID.json;"
    echo "    default_type application/json;"
    echo "    add_header Cache-Control \"no-store\" always;"
    echo "    add_header profile-update-interval \"$(clean "$INTERVAL")\" always;"
    [ -n "$t" ]           && echo "    add_header profile-title \"base64:$(b64 "$t")\" always;"
    [ -n "$a" ]           && echo "    add_header announce \"base64:$(b64 "$a")\" always;"
    [ -n "$info" ]        && echo "    add_header subscription-userinfo \"$info\" always;"
    [ -n "$SUPPORT_URL" ] && echo "    add_header support-url \"$(clean "$SUPPORT_URL")\" always;"
    [ -n "$WEB_URL" ]     && echo "    add_header profile-web-page-url \"$(clean "$WEB_URL")\" always;"
    echo "}"
  } >> "$TMP/ngx"
done < "$CLIENTS"

# Файлы клиентов, которых убрали из списка, удаляем
ids=$(cut -d'|' -f1 "$CLIENTS" | tr -d ' \t\r' | grep -v '^$' || true)
for f in "$OUTDIR"/*.json; do
  [ -e "$f" ] || continue
  id=$(basename "$f" .json)
  grep -qxF "$id" <<< "$ids" || rm -f "$f" "$CACHE/$id"
done

# Обновляем конфиг nginx только если он изменился
if ! cmp -s "$TMP/ngx" "$NGX" 2>/dev/null; then
  [ -f "$NGX" ] && cp "$NGX" "$TMP/ngx.old"
  install -m 644 "$TMP/ngx" "$NGX"
  if command -v nginx >/dev/null; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || nginx -s reload
    else
      echo "  ! nginx -t не прошёл, возвращаю старый конфиг заголовков" >&2
      if [ -f "$TMP/ngx.old" ]; then cp "$TMP/ngx.old" "$NGX"; else : > "$NGX"; fi
    fi
  fi
fi

[ -t 1 ] && echo "Обновлено: $ok, с ошибкой: $fail"
exit 0
