#!/usr/bin/env bash
# Управление клиентами склеенной JSON-подписки, их приписками, названием и описанием подписки.
# Запуск: clients.sh                    — меню
#         clients.sh list
#         clients.sh add ID [приписка]
#         clients.sh del ID
#         clients.sh rename OLD NEW
#         clients.sh note ID текст
#         clients.sh update
set -euo pipefail

DIR=/etc/merge-sub
CLIENTS=$DIR/clients.txt          # subId|приписка|название|описание|группы
GRPFILE=$DIR/groups.json
SETTINGS=$DIR/settings.conf
MERGE=/usr/local/bin/merge-json.sh

XUI="http://127.0.0.1:PORT_3XUI/jsonjsonjson"
CURL_INSECURE=0
TITLE=""; ANNOUNCE=""; INTERVAL=1; SUPPORT_URL=""; WEB_URL=""
mkdir -p "$DIR"; touch "$CLIENTS"
[ -f "$SETTINGS" ] && . "$SETTINGS"

save_settings() {
  { for k in XUI CURL_INSECURE TITLE ANNOUNCE INTERVAL SUPPORT_URL WEB_URL; do
      printf '%s=%q\n' "$k" "${!k}"; done; } > "$SETTINGS"
}
[ -f "$SETTINGS" ] || save_settings

# ---------- работа со списком ----------
sanitize() { printf '%s' "$1" | tr -d '|\r\n'; }
valid()  { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Недопустимый subId: '$1' (только буквы, цифры, - и _)"; return 1; }; }
ids()    { cut -d'|' -f1 "$CLIENTS" | grep -v '^\s*$' || true; }
exists() { ids | grep -qxF "$1"; }
field()  { ID="$1" N="$2" awk -F'|' '$1==ENVIRON["ID"]{print $ENVIRON["N"]}' "$CLIENTS"; }
setfield() {   # setfield ID N значение
  ID="$1" N="$2" VAL="$(sanitize "$3")" awk -F'|' -v OFS='|' '
    $1==ENVIRON["ID"] { n=ENVIRON["N"]+0; while (NF<5) $(NF+1)=""; $n=ENVIRON["VAL"] } { print }
  ' "$CLIENTS" > "$CLIENTS.tmp" && mv "$CLIENTS.tmp" "$CLIENTS"
}
pick() {       # номер или subId -> subId
  local x=$1
  [[ "$x" =~ ^[0-9]+$ ]] && x=$(ids | sed -n "${x}p")
  [ -n "$x" ] && exists "$x" && echo "$x" || { echo "Нет такого клиента" >&2; return 1; }
}
check_xui() {
  local k=(); [ "$CURL_INSECURE" = 1 ] && k=(-k)
  curl -fsS "${k[@]}" --max-time 10 "$XUI/$1" -o /dev/null 2>/dev/null \
    || echo "  Внимание: 3x-ui не отдаёт подписку для '$1' — проверь subId в панели."
}
warn_title() { [ "${#1}" -le 25 ] || echo "  Внимание: Happ показывает до 25 символов названия, у тебя ${#1}."; }

# ---------- действия ----------
do_list() {
  if [ -z "$(ids)" ]; then echo "(клиентов нет)"; return; fi
  local i=0
  while IFS='|' read -r id note t a g _; do
    [ -z "${id// }" ] && continue
    i=$((i+1))
    printf '%2d. %s' "$i" "$id"
    [ -n "$note" ] && printf '  — %s' "$note"
    echo
    [ -n "$t" ] && echo "      название: $t"
    [ -n "$a" ] && echo "      описание: $a"
    [ -n "$g" ] && echo "      группы: ${g//,/, }" || echo "      группы: все сервера"
  done < "$CLIENTS"
  return 0
}

show_settings() {
  echo "Общие: название «${TITLE:-—}», описание «${ANNOUNCE:-—}», обновление каждые ${INTERVAL} ч"
  [ -n "$SUPPORT_URL" ] && echo "       поддержка: $SUPPORT_URL"
  [ -n "$WEB_URL" ]     && echo "       сайт: $WEB_URL"
  return 0
}

do_add() {
  local id=$1 note=${2:-}; valid "$id" || return 1
  if exists "$id"; then echo "'$id' уже есть"; return 0; fi
  printf '%s|%s|||\n' "$id" "$(sanitize "$note")" >> "$CLIENTS"
  echo "Добавлен: $id"; check_xui "$id"
}

do_del() {
  local id=$1
  exists "$id" || { echo "'$id' нет в списке"; return 1; }
  ID="$id" awk -F'|' '$1!=ENVIRON["ID"]' "$CLIENTS" > "$CLIENTS.tmp" && mv "$CLIENTS.tmp" "$CLIENTS"
  echo "Удалён: $id (вернётся на обычную подписку 3x-ui)"
}

do_rename() {
  local old=$1 new=$2; valid "$new" || return 1
  exists "$old" || { echo "'$old' нет в списке"; return 1; }
  exists "$new" && { echo "'$new' уже есть"; return 1; }
  setfield "$old" 1 "$new"; echo "Изменён: $old → $new"; check_xui "$new"
}

apply() { echo "Обновляю подписки..."; "$MERGE" || true; }

edit_client_sub() {
  local id=$1 t a
  echo "Пустой ввод — оставить как есть, «-» — сбросить на общее."
  read -rep "Название [$(field "$id" 3)]: " t
  read -rep "Описание [$(field "$id" 4)]: " a
  [ "$t" = "-" ] && setfield "$id" 3 "" || { [ -n "$t" ] && warn_title "$t" && setfield "$id" 3 "$t"; }
  [ "$a" = "-" ] && setfield "$id" 4 "" || { [ -n "$a" ] && setfield "$id" 4 "$a"; }
  return 0
}

set_groups() {
  local id=$1 list ans out=()
  [ -f "$GRPFILE" ] || echo '{}' > "$GRPFILE"
  list=$(jq -r 'keys_unsorted[]' "$GRPFILE")
  if [ -z "$list" ]; then echo "Групп нет — создай их в groups.sh"; return 0; fi
  echo "Сейчас: $(field "$id" 5 | sed 's/^$/все сервера/; s/,/, /g')"
  nl -w2 -s'. ' <<< "$list"
  read -rp "Номера групп через пробел («-» — все сервера, Enter — не менять): " ans
  [ -z "$ans" ] && return 0
  if [ "$ans" = "-" ]; then setfield "$id" 5 ""; echo "Теперь: все сервера"; return 0; fi
  for n in $ans; do
    g=$(sed -n "${n}p" <<< "$list" 2>/dev/null || true)
    [ -n "$g" ] && out+=("$g") || echo "  нет номера $n"
  done
  [ ${#out[@]} -gt 0 ] || return 0
  setfield "$id" 5 "$(IFS=,; echo "${out[*]}")"; echo "Теперь: $(IFS=,; echo "${out[*]}" | sed 's/,/, /g')"
}

edit_settings() {
  local v
  echo "Пустой ввод — оставить как есть, «-» — очистить."
  read -rep "Название подписки [$TITLE]: " v;              [ "$v" = "-" ] && TITLE="" || { [ -n "$v" ] && warn_title "$v"; TITLE=${v:-$TITLE}; }
  read -rep "Описание (до 200 символов) [$ANNOUNCE]: " v;  [ "$v" = "-" ] && ANNOUNCE="" || ANNOUNCE=${v:-$ANNOUNCE}
  read -rep "Обновление, часов [$INTERVAL]: " v
  if [ -n "$v" ]; then [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && INTERVAL=$v || echo "  Нужно целое число ≥ 1, оставляю $INTERVAL"; fi
  read -rep "Ссылка поддержки (например https://t.me/...) [$SUPPORT_URL]: " v; [ "$v" = "-" ] && SUPPORT_URL="" || SUPPORT_URL=${v:-$SUPPORT_URL}
  read -rep "Ссылка на сайт [$WEB_URL]: " v;              [ "$v" = "-" ] && WEB_URL="" || WEB_URL=${v:-$WEB_URL}
  save_settings; echo "Сохранено."
}

# ---------- запуск с аргументами ----------
case "${1:-}" in
  list)   do_list; echo; show_settings; exit ;;
  add)    do_add "${2:?укажи subId}" "${*:3}"; apply; exit ;;
  del)    do_del "${2:?укажи subId}"; apply; exit ;;
  rename) do_rename "${2:?старый subId}" "${3:?новый subId}"; apply; exit ;;
  note)   id=$(pick "${2:?укажи subId}"); setfield "$id" 2 "${*:3}"; echo "Приписка сохранена"; exit ;;
  update) apply; exit ;;
esac

# ---------- меню ----------
while true; do
  echo; echo "=== Клиенты с JSON-подпиской ==="; do_list
  echo; show_settings
  echo
  echo "1) Добавить        2) Удалить            3) Изменить subId"
  echo "4) Приписка        5) Название/описание клиента"
  echo "6) Общие название, описание, ссылки      7) Группы клиента"
  echo "8) Обновить подписки   0) Выход"
  read -rp "> " c
  case "$c" in
    1) read -rp "subId (можно несколько через пробел): " list
       n=$(wc -w <<< "$list"); note=""
       [ "$n" -eq 1 ] && read -rep "Приписка (необязательно): " note
       for id in $list; do do_add "$id" "$note" || true; done; apply ;;
    2) read -rp "Номер или subId: " x; id=$(pick "$x") && do_del "$id" && apply || true ;;
    3) read -rp "Номер или старый subId: " x
       if id=$(pick "$x"); then read -rp "Новый subId: " n; [ -n "$n" ] && do_rename "$id" "$n" && apply || true; fi ;;
    4) read -rp "Номер или subId: " x
       if id=$(pick "$x"); then read -rep "Приписка [$(field "$id" 2)] («-» — удалить): " v
         if [ "$v" = "-" ]; then setfield "$id" 2 ""; echo "Удалено"
         elif [ -n "$v" ]; then setfield "$id" 2 "$v"; echo "Сохранено"; fi; fi ;;
    5) read -rp "Номер или subId: " x; if id=$(pick "$x"); then edit_client_sub "$id"; apply; fi ;;
    6) edit_settings; apply ;;
    7) read -rp "Номер или subId: " x; if id=$(pick "$x"); then set_groups "$id"; apply; fi ;;
    8) apply ;;
    0|q|"") exit 0 ;;
    *) echo "?" ;;
  esac
done
