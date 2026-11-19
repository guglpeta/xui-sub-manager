#!/usr/bin/env bash
# Включает/выключает TLS (https) у уже добавленных HTTP-прокси в local.json.
# Запуск: tls-switch.sh            — меню
set -euo pipefail
LOCAL=/etc/merge-sub/local.json
MERGE=/usr/local/bin/merge-json.sh

list() { jq -r 'to_entries[] | .value as $c | ($c.outbounds[]? | select(.tag=="proxy")) as $o
  | "\(.key+1). \($c.remarks)  [\($o.protocol)\(if $o.streamSettings.security=="tls" then " + TLS" else "" end)]"' "$LOCAL"; }

list
read -rp "Номер прокси: " n
[[ "$n" =~ ^[0-9]+$ ]] || { echo "Нужен номер"; exit 1; }
i=$((n-1))
jq -e --argjson i "$i" '.[$i] != null' "$LOCAL" >/dev/null || { echo "Нет такого"; exit 1; }
read -rp "TLS: 1 — включить (https), 0 — выключить (http): " on
cp "$LOCAL" "$LOCAL.bak"
if [ "$on" = 1 ]; then
  jq --argjson i "$i" '.[$i].outbounds |= map(if .tag=="proxy" then
      .streamSettings = { network: "tcp", security: "tls",
        tlsSettings: { serverName: .settings.servers[0].address, fingerprint: "chrome" } }
    else . end)' "$LOCAL.bak" > "$LOCAL"
else
  jq --argjson i "$i" '.[$i].outbounds |= map(if .tag=="proxy" then del(.streamSettings) else . end)' "$LOCAL.bak" > "$LOCAL"
fi
list
"$MERGE" || true
