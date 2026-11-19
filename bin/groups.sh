#!/usr/bin/env bash
# Группы серверов: в группу входят выбранные свои прокси и (по желанию) сервера 3x-ui клиента.
# Клиенту назначаются группы в clients.sh; без групп клиент получает всё, как раньше.
set -euo pipefail

DIR=/etc/merge-sub
LOCAL=$DIR/local.json
GRPFILE=$DIR/groups.json
CLIENTS=$DIR/clients.txt
SETTINGS=$DIR/settings.conf
MERGE=/usr/local/bin/merge-json.sh
PROXIES=/usr/local/bin/proxies.sh

XUI=""
[ -f "$SETTINGS" ] && . "$SETTINGS"

mkdir -p "$DIR"
[ -f "$LOCAL" ]  || echo '[]' > "$LOCAL"
[ -f "$GRPFILE" ] || echo '{}' > "$GRPFILE"

gnames()  { jq -r 'keys_unsorted[]' "$GRPFILE"; }
proxies() { jq -r '.[].remarks' "$LOCAL"; }
save()    { jq "$@" "$GRPFILE" > "$GRPFILE.tmp" && mv "$GRPFILE.tmp" "$GRPFILE"; }

show() {
  if [ "$(jq 'length' "$GRPFILE")" = 0 ]; then echo "(групп нет)"; return 0; fi
  jq -r --slurpfile L "$LOCAL" '
    ($L[0] | map(.remarks)) as $have
    | to_entries | to_entries[]
    | "\(.key+1). \(.value.key)\(if .value.value.xui then "  [+ сервера 3x-ui]" else "" end)",
      (.value.value.proxies[] | "      • \(.)\(if ($have | index(.)) then "" else "  (нет в local.json!)" end)"),
      (if (.value.value.proxies | length) == 0 then "      (своих прокси нет)" else empty end)
  ' "$GRPFILE"
  return 0
}

pick_group() {
  local x=$1
  [[ "$x" =~ ^[0-9]+$ ]] && x=$(gnames | sed -n "${x}p")
  [ -n "$x" ] && jq -e --arg g "$x" 'has($g)' "$GRPFILE" >/dev/null && echo "$x" \
    || { echo "Нет такой группы" >&2; return 1; }
}

choose_proxies() {
  local list ans
  list=$(proxies)
  [ -n "$list" ] || { echo "[]"; return; }
  echo "Свои прокси:" >&2; nl -w2 -s'. ' <<< "$list" >&2
  read -rp "Номера через пробел (Enter — ни одного, * — все): " ans
  if [ "$ans" = "*" ]; then jq -c 'map(.remarks)' "$LOCAL"; return; fi
  local out=()
  for n in $ans; do
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "  пропускаю '$n'" >&2; continue; }
    p=$(sed -n "${n}p" <<< "$list"); [ -n "$p" ] && out+=("$p") || echo "  нет номера $n" >&2
  done
  printf '%s\n' "${out[@]+"${out[@]}"}" | jq -Rsc 'split("\n") | map(select(length>0)) | unique'
}

ask_xui() {
  [ -n "${XUI:-}" ] || { echo false; return; }
  local def=$1 r
  read -rp "Включать сервера 3x-ui клиента? [$( [ "$def" = true ] && echo Y/n || echo y/N )]: " r
  case "${r,,}" in y*) echo true ;; n*) echo false ;; *) echo "$def" ;; esac
}

users_of() { awk -F'|' -v g="$1" '{n=split($5,a,","); for(i=1;i<=n;i++) if(a[i]==g) print $1}' "$CLIENTS" 2>/dev/null; }

apply() { echo "Обновляю подписки..."; "$MERGE" || true; }

while true; do
  echo; echo "=== Группы серверов ==="; show
  echo
  if [ -n "${XUI:-}" ]; then
    echo "1) Создать  2) Изменить состав  3) Сервера 3x-ui вкл/выкл  4) Переименовать  5) Удалить"
  else
    echo "1) Создать  2) Изменить состав  4) Переименовать  5) Удалить"
  fi
  echo "6) Обновить подписки  7) Прокси (добавить/изменить)  0) Выход"
  read -rp "> " c
  case "$c" in
    1) read -rp "Название группы: " g
       g=$(printf '%s' "$g" | tr -d '|,\r\n'); [ -n "$g" ] || { echo "Пусто"; continue; }
       jq -e --arg g "$g" 'has($g)' "$GRPFILE" >/dev/null && { echo "Такая уже есть"; continue; }
       p=$(choose_proxies); x=$(ask_xui true)
       save --arg g "$g" --argjson p "$p" --argjson x "$x" '.[$g] = {proxies: $p, xui: $x}'
       echo "Создана: $g" ;;
    2) read -rp "Номер или название группы: " x; g=$(pick_group "$x") || continue
       p=$(choose_proxies)
       save --arg g "$g" --argjson p "$p" '.[$g].proxies = $p'; apply ;;
    3) read -rp "Номер или название группы: " x; g=$(pick_group "$x") || continue
       cur=$(jq -r --arg g "$g" '.[$g].xui' "$GRPFILE"); v=$(ask_xui "$cur")
       save --arg g "$g" --argjson v "$v" '.[$g].xui = $v'; apply ;;
    4) read -rp "Номер или название группы: " x; g=$(pick_group "$x") || continue
       read -rp "Новое название: " n; n=$(printf '%s' "$n" | tr -d '|,\r\n')
       [ -n "$n" ] || continue
       jq -e --arg g "$n" 'has($g)' "$GRPFILE" >/dev/null && { echo "Такая уже есть"; continue; }
       save --arg o "$g" --arg n "$n" 'with_entries(if .key==$o then .key=$n else . end)'
       [ -f "$CLIENTS" ] && O="$g" N="$n" awk -F'|' -v OFS='|' '
         { if (NF>=5) { m=split($5,a,","); s=""; for(i=1;i<=m;i++){ if(a[i]==ENVIRON["O"]) a[i]=ENVIRON["N"]; s=s (i>1?",":"") a[i] } $5=s } print }
       ' "$CLIENTS" > "$CLIENTS.tmp" && mv "$CLIENTS.tmp" "$CLIENTS"
       echo "Переименована"; apply ;;
    5) read -rp "Номер или название группы: " x; g=$(pick_group "$x") || continue
       u=$(users_of "$g" | tr '\n' ' ')
       [ -n "$u" ] && echo "Её используют: $u— у них группа пропадёт."
       read -rp "Удалить «$g»? [y/N] " r; [[ "${r,,}" == y* ]] || continue
       save --arg g "$g" 'del(.[$g])'
       [ -f "$CLIENTS" ] && G="$g" awk -F'|' -v OFS='|' '
         { if (NF>=5) { m=split($5,a,","); s=""; for(i=1;i<=m;i++) if(a[i]!=ENVIRON["G"]) s=s (s!=""?",":"") a[i]; $5=s } print }
       ' "$CLIENTS" > "$CLIENTS.tmp" && mv "$CLIENTS.tmp" "$CLIENTS"
       echo "Удалена"; apply ;;
    6) apply ;;
    7) "$PROXIES" || true ;;
    0|q|"") exit 0 ;;
    *) echo "?" ;;
  esac
done