#!/usr/bin/env bash
# Просмотр, редактирование и удаление своих прокси в /etc/merge-sub/local.json.
# Переименование и удаление сразу применяются и в группах (groups.json).
set -euo pipefail

DIR=/etc/merge-sub
LOCAL=$DIR/local.json
GRPFILE=$DIR/groups.json
MERGE=/usr/local/bin/merge-json.sh
ADD=/usr/local/bin/add-proxy.sh

mkdir -p "$DIR"
[ -f "$LOCAL" ]   || echo '[]' > "$LOCAL"
[ -f "$GRPFILE" ] || echo '{}' > "$GRPFILE"

# ---------- помощники ----------
count() { jq length "$LOCAL"; }
edit()  { cp "$LOCAL" "$LOCAL.bak"; jq "$@" "$LOCAL.bak" > "$LOCAL.tmp" && mv "$LOCAL.tmp" "$LOCAL"; }
gedit() { jq "$@" "$GRPFILE" > "$GRPFILE.tmp" && mv "$GRPFILE.tmp" "$GRPFILE"; }
apply() { echo "Обновляю подписки..."; "$MERGE" || true; }

# Путь к outbound прокси внутри конфига
PX='(.outbounds | map(.tag=="proxy") | index(true))'

show_list() {
  if [ "$(count)" = 0 ]; then echo "(прокси нет)"; return 0; fi
  jq -r --slurpfile G "$GRPFILE" '
    to_entries[] | .key as $k | .value as $c
    | ($c.outbounds[] | select(.tag=="proxy")) as $o
    | ($o.settings.servers[0]) as $s
    | ([$G[0] | to_entries[] | select(.value.proxies | index($c.remarks)) | .key]) as $gr
    | "\($k+1). \($c.remarks)",
      "      \(if $o.streamSettings.security=="tls" then "https" else $o.protocol end)://\($s.address):\($s.port)\(if $s.users then "  логин \($s.users[0].user)" else "  без авторизации" end)\(if ($gr|length)>0 then "  | группы: \($gr|join(", "))" else "" end)"
  ' "$LOCAL"
}

pick() {   # номер -> индекс (с нуля)
  local n=$1
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$(count)" ] || { echo "Нет такого номера" >&2; return 1; }
  echo $((n-1))
}
get() { jq -r --argjson i "$1" ".[\$i] | $2 // empty" "$LOCAL"; }

# Разбор строки прокси: заполняет p_proto p_tls p_host p_port p_user p_pass
parse_proxy() {
  local P; P=$(echo "$1" | tr -d '[:space:]')
  p_proto=""; p_tls=""; p_user=""; p_pass=""
  case "$P" in
    https://*) p_proto=http; p_tls=1; P=${P#*://} ;;
    http://*)  p_proto=http; p_tls=0; P=${P#*://} ;;
    socks://*|socks5://*|socks5h://*) p_proto=socks; p_tls=0; P=${P#*://} ;;
  esac
  P=${P%%#*}; P=${P%/}
  if [[ "$P" == *@* ]]; then
    local auth=${P%@*} hp=${P##*@}
    p_user=${auth%%:*}; [[ "$auth" == *:* ]] && p_pass=${auth#*:}
    p_host=${hp%:*}; p_port=${hp##*:}
  else
    IFS=: read -r p_host p_port p_user p_pass <<< "$P"
    p_user=${p_user:-}; p_pass=${p_pass:-}
  fi
  [[ "$p_port" =~ ^[0-9]+$ ]] && [ "$p_port" -ge 1 ] && [ "$p_port" -le 65535 ] && [ -n "$p_host" ] \
    || { echo "Не разобрал прокси '$1'" >&2; return 1; }
}

# Записать сервер (адрес/порт/логин) в прокси с индексом $1
set_server() {
  local i=$1 host=$2 port=$3 user=$4 pass=$5
  edit --argjson i "$i" --arg h "$host" --argjson p "$port" --arg u "$user" --arg w "$pass" '
    .[$i].outbounds |= map(if .tag=="proxy" then
      .settings.servers[0] = ({address: $h, port: $p}
        + (if $u != "" then {users: [{user: $u, pass: $w}]} else {} end))
      # serverName для TLS следует за адресом
      | if .streamSettings.security == "tls" then .streamSettings.tlsSettings.serverName = $h else . end
    else . end)'
}

set_type() {   # set_type индекс http|https|socks
  local i=$1 t=$2 proto=http tls=0
  case "$t" in https) tls=1 ;; socks) proto=socks ;; esac
  edit --argjson i "$i" --arg pr "$proto" --argjson tls "$tls" '
    .[$i].outbounds |= map(if .tag=="proxy" then
      .protocol = $pr
      | if $tls == 1 then .streamSettings = {network: "tcp", security: "tls",
          tlsSettings: {serverName: .settings.servers[0].address, fingerprint: "chrome"}}
        else del(.streamSettings) end
    else . end)'
}

ask_type() {
  local r
  read -rp "Тип [http/https/socks] (Enter — $1): " r
  case "${r,,}" in "") echo "$1" ;; http|https|socks) echo "${r,,}" ;; socks5|s) echo socks ;; *) echo "$1" ;; esac
}

cur_type() { jq -r --argjson i "$1" '.[$i].outbounds[] | select(.tag=="proxy") | if .streamSettings.security=="tls" then "https" else .protocol end' "$LOCAL"; }

# ---------- действия ----------
do_edit() {
  local i=$1 old new v
  while true; do
    echo; echo "--- $(get "$i" .remarks) ---"
    jq -r --argjson i "$i" '.[$i].outbounds[] | select(.tag=="proxy") as $o | $o.settings.servers[0] as $s
      | "Тип: \(if $o.streamSettings.security=="tls" then "https" else $o.protocol end)",
        "Адрес: \($s.address):\($s.port)",
        "Логин: \($s.users[0].user // "—")",
        "Пароль: \($s.users[0].pass // "—")"' "$LOCAL"
    echo
    echo "1) Название  2) Адрес и порт  3) Логин/пароль  4) Тип (http/https/socks)"
    echo "5) Заменить прокси целиком (вставить новую ссылку)  0) Назад"
    read -rp "> " c
    case "$c" in
      1) old=$(get "$i" .remarks)
         read -rep "Новое название [$old]: " new
         [ -n "$new" ] && [ "$new" != "$old" ] || continue
         jq -e --arg n "$new" 'any(.[]; .remarks==$n)' "$LOCAL" >/dev/null && { echo "Такое название уже есть"; continue; }
         edit --argjson i "$i" --arg n "$new" '.[$i].remarks = $n'
         gedit --arg o "$old" --arg n "$new" 'map_values(.proxies |= map(if .==$o then $n else . end))'
         echo "Переименован (в группах тоже)" ;;
      2) read -rep "Адрес [$(get "$i" ".outbounds[$PX].settings.servers[0].address")]: " v
         h=${v:-$(get "$i" ".outbounds[$PX].settings.servers[0].address")}
         read -rep "Порт [$(get "$i" ".outbounds[$PX].settings.servers[0].port")]: " v
         p=${v:-$(get "$i" ".outbounds[$PX].settings.servers[0].port")}
         [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { echo "Плохой порт"; continue; }
         set_server "$i" "$h" "$p" "$(get "$i" ".outbounds[$PX].settings.servers[0].users[0].user")" \
                                   "$(get "$i" ".outbounds[$PX].settings.servers[0].users[0].pass")"
         echo "Сохранено" ;;
      3) echo "«-» в логине — убрать авторизацию."
         read -rep "Логин [$(get "$i" ".outbounds[$PX].settings.servers[0].users[0].user")]: " u
         if [ "$u" = "-" ]; then u=""; w=""
         else
           u=${u:-$(get "$i" ".outbounds[$PX].settings.servers[0].users[0].user")}
           read -rep "Пароль [$(get "$i" ".outbounds[$PX].settings.servers[0].users[0].pass")]: " w
           w=${w:-$(get "$i" ".outbounds[$PX].settings.servers[0].users[0].pass")}
         fi
         set_server "$i" "$(get "$i" ".outbounds[$PX].settings.servers[0].address")" \
                         "$(get "$i" ".outbounds[$PX].settings.servers[0].port")" "$u" "$w"
         echo "Сохранено" ;;
      4) t=$(ask_type "$(cur_type "$i")"); set_type "$i" "$t"; echo "Тип: $t" ;;
      5) read -rp "Новая ссылка/строка прокси: " line
         parse_proxy "$line" || continue
         set_server "$i" "$p_host" "$p_port" "$p_user" "$p_pass"
         if [ -n "$p_proto" ]; then
           [ "$p_tls" = 1 ] && t=https || t=$p_proto
         else t=$(ask_type "$(cur_type "$i")"); fi
         set_type "$i" "$t"
         echo "Заменён ($t $p_host:$p_port). Название и группы сохранены." ;;
      0|"") return 0 ;;
      *) echo "?" ;;
    esac
  done
}

do_delete() {
  local i=$1 name r
  name=$(get "$i" .remarks)
  read -rp "Удалить «$name»? [y/N] " r; [[ "${r,,}" == y* ]] || return 0
  edit --argjson i "$i" 'del(.[$i])'
  gedit --arg n "$name" 'map_values(.proxies |= map(select(. != $n)))'
  echo "Удалён (и из групп)"
}

do_copy() {
  local i=$1 name new
  name=$(get "$i" .remarks)
  read -rep "Название копии: " new
  [ -n "$new" ] || return 0
  jq -e --arg n "$new" 'any(.[]; .remarks==$n)' "$LOCAL" >/dev/null && { echo "Такое название уже есть"; return 0; }
  edit --argjson i "$i" --arg n "$new" '. + [.[$i] | .remarks = $n]'
  echo "Скопирован как «$new» — теперь поменяй в нём что нужно."
}

do_move() {
  local i=$1 n j
  read -rp "На какую позицию (1–$(count)): " n
  j=$(pick "$n") || return 0
  edit --argjson i "$i" --argjson j "$j" '.[$i] as $x | del(.[$i]) | .[:$j] + [$x] + .[$j:]'
  echo "Перемещён"
}

while true; do
  echo; echo "=== Свои прокси ==="; show_list
  echo
  echo "1) Добавить   2) Изменить   3) Удалить   4) Копировать   5) Переместить"
  echo "6) Обновить подписки   0) Выход"
  read -rp "> " c
  case "$c" in
    1) "$ADD" || true ;;
    2) read -rp "Номер: " n; i=$(pick "$n") && { do_edit "$i"; apply; } || true ;;
    3) read -rp "Номер: " n; i=$(pick "$n") && { do_delete "$i"; apply; } || true ;;
    4) read -rp "Номер: " n; i=$(pick "$n") && do_copy "$i" || true ;;
    5) read -rp "Номер: " n; i=$(pick "$n") && { do_move "$i"; apply; } || true ;;
    6) apply ;;
    0|q|"") exit 0 ;;
    *) echo "?" ;;
  esac
done
