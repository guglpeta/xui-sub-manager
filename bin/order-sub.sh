#!/usr/bin/env bash
# Порядок серверов в склеенной подписке клиента (свои прокси, 3x-ui, подписки провайдеров).
#   order-sub.sh                      — меню
#   order-sub.sh --apply SUBID FILE   — переставить серверы в FILE по сохранённому порядку (вызывает merge-json.sh)
# Порядок хранится по названиям серверов; новые серверы встают в конец.
set -uo pipefail

ETC=${ORDER_ETC:-/etc/merge-sub}
ODIR=$ETC/order                    # SUBID.json — порядок, SUBID.raw.json — последняя сборка до сортировки
CLIENTS=$ETC/clients.txt
MERGE=${ORDER_MERGE:-/usr/local/bin/merge-json.sh}
mkdir -p "$ODIR"

# ключи серверов: название, для повторов — «название (2)»…
JQ_KEYED='def keyed: reduce .[] as $c ({seen:{}, out:[]};
  (($c.remarks // "") | tostring) as $r | ((.seen[$r] // 0) + 1) as $n
  | .seen[$r] = $n | .out += [{k: (if $n == 1 then $r else "\($r) (\($n))" end), c: $c}]) | .out;'

sorted() { # FILE ORDER -> отсортированный массив
  jq --slurpfile O "$2" "$JQ_KEYED"'
    keyed as $it | ($O[0] // []) as $ord
    | [ $ord[] as $k | $it[] | select(.k == $k) ]
      + [ $it[] | select(.k as $k | $ord | map(. == $k) | any | not) ]
    | map(.c)' "$1"
}

if [ "${1:-}" = --apply ]; then
  sid=$2 f=$3
  jq -e 'type=="array"' "$f" >/dev/null 2>&1 || exit 0
  cp "$f" "$ODIR/$sid.raw.json"
  [ -s "$ODIR/$sid.json" ] || exit 0
  sorted "$f" "$ODIR/$sid.json" > "$f.ord" && jq -e 'type=="array"' "$f.ord" >/dev/null 2>&1 && mv "$f.ord" "$f"
  rm -f "$f.ord"; exit 0
fi

# ===================== меню =====================
[ -s "$CLIENTS" ] || { echo "Нет клиентов (clients.sh)."; exit 0; }

pick_client() {
  local i=0 sid note k ids=()
  echo; echo "=== Порядок серверов: выбери клиента ==="
  while IFS='|' read -r sid note _; do
    sid=$(printf '%s' "$sid" | tr -d '[:space:]')
    [[ -z "$sid" || "$sid" == \#* ]] && continue
    i=$((i+1)); ids+=("$sid")
    echo "$i. ${note:-$sid}  ($sid)$([ -s "$ODIR/$sid.json" ] && echo "  — свой порядок")"
  done < "$CLIENTS"
  read -rp "Номер клиента (Enter — выход): " k
  [ -n "$k" ] || return 1
  [[ "$k" =~ ^[0-9]+$ ]] && [ "$k" -ge 1 ] && [ "$k" -le "${#ids[@]}" ] || { echo "Нет такого."; SID=""; return 0; }
  SID=${ids[$((k-1))]}
}

edit_order() {
  local sid=$1 raw="$ODIR/$1.raw.json" ofile="$ODIR/$1.json" keys=() c nums to i n sel rest changed=0
  if [ ! -s "$raw" ]; then
    [ -x "$MERGE" ] && { echo "Собираю подписку…"; "$MERGE" >/dev/null 2>&1 || true; }
    [ -s "$raw" ] || { echo "Нет сборки подписки этого клиента. Проверь, что patch-merge.sh применён, и обнови подписки."; return; }
  fi
  [ -s "$ofile" ] || echo '[]' > "$ofile"
  mapfile -t keys < <(sorted "$raw" "$ofile" | jq -r "$JQ_KEYED"' keyed[] | .k')
  while true; do
    echo; echo "=== Порядок серверов у $sid (так их увидят в Happ) ==="
    n=${#keys[@]}
    [ "$n" -gt 0 ] || { echo "(серверов нет)"; return; }
    for i in "${!keys[@]}"; do printf '%3d. %s\n' $((i+1)) "${keys[$i]}"; done
    echo
    echo "1) Переместить (можно несколько: «5 6 7» или «5-7»)   2) Сбросить порядок   0) Сохранить и выйти"
    read -rp "> " c || break
    case "$c" in
      1) read -rp "Какие номера: " nums
         local list=() t
         for t in ${nums//,/ }; do
           if [[ "$t" =~ ^([0-9]+)-([0-9]+)$ ]]; then list+=($(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"))
           else list+=("$t"); fi
         done
         sel=()
         for i in "${list[@]}"; do
           [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "$n" ] || { echo "  нет номера $i"; continue; }
           [[ " ${sel[*]-} " == *" $i "* ]] || sel+=("$i")
         done
         [ "${#sel[@]}" -gt 0 ] || continue
         read -rp "На какое место поставить (1 — в начало, $((n-${#sel[@]}+1)) — в конец): " to
         [[ "$to" =~ ^[0-9]+$ ]] && [ "$to" -ge 1 ] || { echo "Не понял место."; continue; }
         local moved=() others=()
         for i in "${!keys[@]}"; do
           if [[ " ${sel[*]} " == *" $((i+1)) "* ]]; then moved+=("${keys[$i]}"); else others+=("${keys[$i]}"); fi
         done
         [ "$to" -gt $(( ${#others[@]} + 1 )) ] && to=$(( ${#others[@]} + 1 ))
         keys=("${others[@]:0:$((to-1))}" "${moved[@]}" "${others[@]:$((to-1))}")
         changed=1 ;;
      2) keys=(); mapfile -t keys < <(jq -r "$JQ_KEYED"' keyed[] | .k' "$raw"); echo '[]' > "$ofile"; changed=1
         echo "Порядок как при сборке: свои прокси, 3x-ui, подписки провайдеров." ;;
      0|q|"") break ;;
      *) echo "?" ;;
    esac
  done
  [ "$changed" = 1 ] || return 0
  printf '%s\n' "${keys[@]}" | jq -R . | jq -s . > "$ofile"
  if [ -x "$MERGE" ]; then echo "Обновляю подписки…"; "$MERGE" || true; fi
  echo "Сохранено. Клиенту достаточно обновить подписку в Happ."
}

while true; do
  SID=""
  pick_client || exit 0
  [ -n "$SID" ] && edit_order "$SID"
done
