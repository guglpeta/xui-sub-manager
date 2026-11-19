#!/usr/bin/env bash
# Добавляет прокси в /etc/merge-sub/local.json и сразу обновляет подписки.
# Понимает форматы:
#   http://user:pass@host:port   https://... (HTTP-прокси через TLS)   socks://...   socks5://...
#   host:port:user:pass          user:pass@host:port   host:port (без авторизации)
set -euo pipefail

LOCAL=/etc/merge-sub/local.json
MERGE=/usr/local/bin/merge-json.sh

mkdir -p "$(dirname "$LOCAL")"
[ -f "$LOCAL" ] || echo '[]' > "$LOCAL"

read -rp "Прокси: " P
P=$(echo "$P" | tr -d '[:space:]')
[ -n "$P" ] || { echo "Пусто"; exit 1; }

proto=""; tls=0
case "$P" in
  https://*) proto=http; tls=1; P=${P#*://} ;;
  http://*)  proto=http;  P=${P#*://} ;;
  socks://*|socks5://*|socks5h://*) proto=socks; P=${P#*://} ;;
esac
P=${P%%#*}; P=${P%/}

user=""; pass=""
if [[ "$P" == *@* ]]; then
  auth=${P%@*}; hp=${P##*@}            # пароль может содержать @ — режем по последнему
  user=${auth%%:*}; pass=${auth#*:}
  [[ "$auth" == *:* ]] || pass=""
  host=${hp%:*}; port=${hp##*:}
else
  IFS=: read -r host port user pass <<< "$P"
  user=${user:-}; pass=${pass:-}
fi

[[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
  || { echo "Не разобрал порт в '$P'"; exit 1; }
[ -n "$host" ] || { echo "Не разобрал адрес"; exit 1; }

if [ -z "$proto" ]; then
  read -rp "Тип [http/https/socks] (Enter = https): " t
  case "${t,,}" in
    s|socks|socks5) proto=socks ;;
    http)           proto=http ;;
    *)              proto=http; tls=1 ;;
  esac
fi

read -rp "Название (например 🇩🇪 DE proxy): " NAME
[ -n "$NAME" ] || NAME="$host:$port"

if jq -e --arg n "$NAME" 'any(.[]; .remarks==$n)' "$LOCAL" >/dev/null; then
  read -rp "Прокси с названием '$NAME' уже есть. Заменить? [y/N] " r
  [[ "${r,,}" == y* ]] || { echo "Отменено"; exit 0; }
  jq --arg n "$NAME" 'map(select(.remarks != $n))' "$LOCAL" > "$LOCAL.tmp" && mv "$LOCAL.tmp" "$LOCAL"
fi

OBJ=$(jq -n \
  --arg name "$NAME" --arg proto "$proto" --arg host "$host" --argjson port "$port" \
  --arg user "$user" --arg pass "$pass" --argjson tls "$tls" '
{
  remarks: $name,
  log: { loglevel: "warning" },
  dns: { servers: ["https://1.1.1.1/dns-query"] },
  inbounds: [{
    tag: "socks", listen: "127.0.0.1", port: 10808, protocol: "socks",
    settings: { udp: true },
    sniffing: { enabled: true, destOverride: ["http", "tls"] }
  }],
  outbounds: [
    { tag: "proxy", protocol: $proto,
      settings: { servers: [ ({ address: $host, port: $port }
        + (if $user != "" then { users: [{ user: $user, pass: $pass }] } else {} end)) ] } }
      + (if $tls == 1 then { streamSettings: { network: "tcp", security: "tls",
           tlsSettings: { serverName: $host, fingerprint: "chrome" } } } else {} end),
    { tag: "direct", protocol: "freedom" },
    { tag: "block",  protocol: "blackhole" }
  ],
  routing: { rules: [
    { type: "field", network: "udp", port: "443", outboundTag: "block" },
    { type: "field", network: "udp", outboundTag: "direct" }
  ] }
}')

cp "$LOCAL" "$LOCAL.bak"
jq --argjson o "$OBJ" '. + [$o]' "$LOCAL" > "$LOCAL.tmp" && mv "$LOCAL.tmp" "$LOCAL"

[ "$tls" = 1 ] && shown=https || shown=$proto
echo "Добавлен: $NAME  ($shown $host:$port${user:+, логин $user})"
echo "Сейчас в local.json:"; jq -r '.[].remarks' "$LOCAL" | nl -w2 -s'. '

# Добавить в группы
G=/etc/merge-sub/groups.json
if [ -f "$G" ] && [ "$(jq length "$G")" -gt 0 ]; then
  echo "Группы:"; jq -r 'keys_unsorted[]' "$G" | nl -w2 -s'. '
  read -rp "Добавить в группы (номера через пробел, Enter — ни в какие): " ans
  for n in $ans; do
    g=$(jq -r 'keys_unsorted[]' "$G" | sed -n "${n}p" 2>/dev/null || true)
    [ -n "$g" ] || { echo "  нет номера $n"; continue; }
    jq --arg g "$g" --arg p "$NAME" '.[$g].proxies = ((.[$g].proxies + [$p]) | unique)' "$G" > "$G.tmp" && mv "$G.tmp" "$G"
    echo "  → в группе «$g»"
  done
fi

"$MERGE" || true
