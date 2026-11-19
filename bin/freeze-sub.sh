#!/usr/bin/env bash
# Подписки провайдеров: скачивает чужую подписку и отдаёт копию со своего домена.
#   «заморожена» — содержимое не меняется, пока не нажмёшь «Перекачать»;
#   «обновляется» — скрипт сам подтягивает свежую версию (по cron и при сборке подписок клиентов);
#   «обновляется до конца подписки» — то же, но за FREEZE_DAYS дн. до конца срока сама замораживается
#     (срок берётся из заголовка subscription-userinfo провайдера или задаётся датой).
# Серверы можно переименовать и отключить — правила применяются при каждой перекачке.
# Подписки можно добавить клиентам: их серверы попадут в склеенную JSON-подписку клиента.
# Название и описание отдаются заголовками nginx (profile-title / announce).
#
#   freeze-sub.sh              — меню
#   freeze-sub.sh --refresh    — перекачать все «обновляемые» (для cron)
#   freeze-sub.sh --clients    — сразу к подпискам клиентов
# Порядок серверов подписки (пункт 7) хранится по их именам у провайдера; новые серверы встают в конец.
#   freeze-sub.sh --json T1,T2 — JSON-конфиги Xray этих подписок (вызывает merge-json.sh)
# Если провайдер не пускает IP сервера (например, только российские адреса) — у подписки можно
# задать прокси для скачивания (пункт 3 меню) или общий FROZEN_PROXY в settings.conf.
set -uo pipefail

CONF=/etc/merge-sub/settings.conf
[ -f "$CONF" ] && . "$CONF"
PUBLIC_HOST=${PUBLIC_HOST:-example.com}
FROZEN_BASE=${FROZEN_BASE:-https://$PUBLIC_HOST:PORT_SUB/frozen}   # публичный адрес
DIR=${FROZEN_DIR:-/var/www/frozen}                              # что отдаёт nginx
ETC=${FROZEN_ETC:-/etc/merge-sub}
LIST=${FROZEN_LIST:-$ETC/frozen.txt}   # токен|название|источник|дата|серверов|описание|hwid|режим (TAB)
RAWDIR=$ETC/subs-raw                   # исходные копии подписок (до правил)
RULESDIR=$ETC/subs-rules               # переименования и отключённые серверы
CSUBS=$ETC/client-subs.txt             # subId|токен,токен
CLIENTS=$ETC/clients.txt               # из clients.sh: subId|приписка|...
NGX=${FROZEN_NGX:-/etc/nginx/merge-sub/frozen.conf}
PY=${FROZEN_PY:-/usr/local/bin/sublinks.py}
MERGE=${FROZEN_MERGE:-/usr/local/bin/merge-json.sh}
LIVE_TTL=${FROZEN_LIVE_TTL:-600}       # «обновляемые» не чаще раза в 10 минут
FAIL_TTL=${FROZEN_FAIL_TTL:-$LIVE_TTL} # после неудачной закачки не пробовать снова столько секунд
FETCH_TIMEOUT=${FROZEN_TIMEOUT:-15}    # общий таймаут закачки у провайдера, сек
# Длинные списки доменов в правилах маршрутизации провайдера (по 1000+ доменов в каждом сервере)
# убираются — подписка становится в разы меньше. Целые зоны (domain:ru, su, рф) остаются.
# Вместо списка можно подставить geosite (напр. geosite:category-ru), но на iPhone большие
# категории geosite не влезают в лимит памяти туннеля (50 МБ), поэтому по умолчанию — без них.
COMPACT=${FROZEN_COMPACT:-1}                       # 0 — оставлять списки как есть
COMPACT_MIN=${FROZEN_COMPACT_MIN:-50}              # с какого числа доменов в правиле убирать
COMPACT_DIRECT=${FROZEN_COMPACT_DIRECT:-}          # чем заменить список «напрямую» (пусто — ничем)
COMPACT_BLOCK=${FROZEN_COMPACT_BLOCK:-}            # чем заменить список «блокировать» (пусто — ничем)
FREEZE_DAYS=${FROZEN_FREEZE_DAYS:-1}   # «обновляется до конца подписки»: за сколько дней до конца заморозить
UA=${FROZEN_UA:-Happ/3.8.1}
# Заголовки устройства, которые шлёт Happ (для провайдеров с лимитом устройств по HWID)
DEV_OS=${FROZEN_DEV_OS:-Android}
DEV_VER=${FROZEN_DEV_VER:-14}
DEV_MODEL=${FROZEN_DEV_MODEL:-Pixel 8}

mkdir -p "$DIR" "$ETC" "$RAWDIR" "$RULESDIR"
ORDTMP=$(mktemp -d); trap 'rm -rf "$ORDTMP"' EXIT   # исходные копии, переставленные по сохранённому порядку
[ -f "$LIST" ]  || touch "$LIST"
[ -f "$CSUBS" ] || touch "$CSUBS"
command -v python3 >/dev/null || { echo "Нужен python3: apt install -y python3" >&2; exit 1; }
[ -f "$PY" ] || { echo "Нет $PY — положи sublinks.py рядом с freeze-sub.sh" >&2; exit 1; }

b64()   { printf '%s' "$1" | base64 -w0; }
py()    { python3 -I "$PY" "$@"; }
rules() { local f="$RULESDIR/$1.json"; [ -f "$f" ] || echo '{"rename":{},"skip":[]}' > "$f"; echo "$f"; }
raw()   { if [ -f "$RAWDIR/$1.json" ]; then echo "$RAWDIR/$1.json"; else echo "$RAWDIR/$1.txt"; fi; }
# JSON-конфиги Xray: убрать длинные списки доменов (правила с другими outbound не трогаем)
compact() {
  [ "$COMPACT" = 1 ] || return 0
  jq --argjson min "$COMPACT_MIN" --arg direct "$COMPACT_DIRECT" --arg block "$COMPACT_BLOCK" '
    def short: test("^(geosite|ext|regexp):") or test("^(domain:)?[^.:]+$");  # категории и целые зоны (ru, su, рф)
    map(if (.routing.rules? | type) == "array" then
      .routing.rules |= map(
        if ((.domain? // []) | length) >= $min and (.outboundTag == "direct" or .outboundTag == "block") then
          .domain = ([.domain[] | select(short)] + ([if .outboundTag == "block" then $block else $direct end]
                     | map(select(length > 0))) | unique)
          # не осталось доменов — правило убрать целиком (без них оно сработало бы на весь трафик)
          | if (.domain | length) > 0 then . else empty end
        else . end)
    else . end)' "$1" > "$1.c" && mv "$1.c" "$1" || rm -f "$1.c"
  return 0
}
# порядок серверов: KEYS (как в py list, по порядку исходной копии) + ORDER (сохранённый) -> индексы.
# Сначала серверы из ORDER (повторы имён — по очереди), потом новые — как в исходной копии.
JQ_PERM='reduce $ord[] as $k ({out: [], used: {}};
    . as $s | (first(range(0; $keys | length) | select($keys[.] == $k and ($s.used[tostring] | not))) // null) as $i
    | if $i == null then . else .out += [$i] | .used[$i | tostring] = true end)
  | . as $s | .out + [range(0; $keys | length) | select($s.used[tostring] | not)]'
list_keys() { py list "$1" "$2" | awk -F'\037' '{print $2}' | jq -R . | jq -sc .; }
# исходная копия с учётом сохранённого порядка (поле order в файле правил) -> путь к файлу
src() {
  local tok=$1 r rf ord keys perm n out ext
  r=$(raw "$tok"); rf=$(rules "$tok"); ext=${r##*.}
  ord=$(jq -c '.order // []' "$rf" 2>/dev/null)
  if [ ! -f "$r" ] || [ "${ord:-[]}" = "[]" ]; then echo "$r"; return 0; fi
  keys=$(list_keys "$r" "$rf")
  if [ "$ext" = json ]; then n=$(jq length "$r"); else n=$(grep -c . "$r"); fi
  if [ "$(jq length <<< "$keys")" != "$n" ]; then
    echo "  ! порядок серверов не применён: список серверов не совпал с копией подписки" >&2
    echo "$r"; return 0
  fi
  perm=$(jq -nc --argjson keys "$keys" --argjson ord "$ord" "$JQ_PERM")
  out="$ORDTMP/$tok.$ext"
  if [ "$ext" = json ]; then jq --argjson p "$perm" '[ $p[] as $i | .[$i] ]' "$r" > "$out"
  else jq -r '.[]' <<< "$perm" | awk 'NR==FNR{l[FNR]=$0; next} {print l[$1+1]}' "$r" - > "$out"; fi
  echo "$out"
}
rows()  { tr '\t' '\037' < "$LIST"; }    # \037: пустые поля не склеиваются при read
row_of() { awk -F'\t' -v t="$1" '$1==t' "$LIST" | tr '\t' '\037'; }
# доп. данные подписки хранятся в её файле правил: until (auto|ГГГГ-ММ-ДД), expire (unix), frozen_at
meta()     { jq -r --arg k "$2" '.[$k] // empty | tostring' "$(rules "$1")"; }
set_meta() {
  local f; f=$(rules "$1")
  if [ -n "${3:-}" ]; then jq --arg k "$2" --arg v "$3" '.[$k]=$v' "$f"; else jq --arg k "$2" 'del(.[$k])' "$f"; fi > "$f.tmp" \
    && mv "$f.tmp" "$f"
}
# конец подписки (unix) или пусто
end_ts() {
  local u e; u=$(meta "$1" until)
  case "$u" in
    "") ;;
    auto) e=$(meta "$1" expire); [[ "$e" =~ ^[0-9]+$ ]] && [ "$e" -gt 0 ] && echo "$e" ;;
    *) date -d "$u 23:59:59" +%s 2>/dev/null ;;
  esac
  return 0
}
dmy() { date -d "@$1" +%d.%m.%Y; }
mode_text() { # режим until [токен]
  local e=""
  if [ "${1:-}" != live ]; then echo "заморожена"; return; fi
  [ -n "${2:-}" ] || { echo "обновляется"; return; }
  [ -n "${3:-}" ] && e=$(end_ts "$3")
  if [ -n "$e" ]; then echo "обновляется до $(dmy $((e - FREEZE_DAYS*86400))), потом заморозится"
  else echo "обновляется до конца подписки (срок пока не известен)"; fi
}

# пора замораживать? Если да — переводит в «заморожена» и возвращает 0
check_freeze() {
  local tok=$1 r name url date n desc hw mode end
  r=$(row_of "$tok"); [ -n "$r" ] || return 1
  IFS=$'\037' read -r tok name url date n desc hw mode <<< "$r"
  [ "${mode:-}" = live ] || return 1
  end=$(end_ts "$tok"); [ -n "$end" ] || return 1
  [ "$(date +%s)" -ge $(( end - FREEZE_DAYS*86400 )) ] || return 1
  save_row "$tok" "$name" "$url" "$date" "$n" "${desc:-}" "${hw:-}" frozen
  set_meta "$tok" frozen_at "$(date +%F)"
  echo "«$name»: до конца подписки ($(dmy "$end")) меньше $FREEZE_DAYS дн. — подписка заморожена." >&2
  return 0
}

# --- nginx: пересобрать frozen.conf (по location на каждую подписку, с заголовками) ---
gen_nginx() {
  local tmp old tok name url date n desc hw mode root sub
  [ "${FROZEN_NO_NGINX:-0}" != 1 ] && ! grep -rqs 'merge-sub/\*\.conf' /etc/nginx/sites-enabled/ && {
    echo "⚠ В конфиге nginx на PORT_SUB нет строки: include /etc/nginx/merge-sub/*.conf;"
    echo "  Добавь её в блок server после строк с сертификатом и запусти скрипт снова."
    return 1; }
  root=$(dirname "$DIR"); sub=$(basename "$DIR")
  mkdir -p "$(dirname "$NGX")"
  tmp=$(mktemp)
  {
    echo "# Подписки провайдеров — файл создаёт freeze-sub.sh, руками не править"
    while IFS=$'\037' read -r tok name url date n desc hw mode; do
      [ -n "$tok" ] || continue
      echo "location = /frozen/$tok {"
      echo "    root $root;"
      echo "    try_files /$sub/$tok.txt /$sub/$tok.json =404;"
      echo "    access_log off;"
      echo "    add_header Cache-Control \"no-store\" always;"
      [ -n "$name" ] && echo "    add_header profile-title \"base64:$(b64 "$name")\" always;"
      [ -n "${desc:-}" ] && echo "    add_header announce \"base64:$(b64 "$desc")\" always;"
      echo "}"
    done < <(rows)
  } > "$tmp"
  cmp -s "$tmp" "$NGX" 2>/dev/null && { rm -f "$tmp"; return 0; }
  old=$(mktemp); [ -f "$NGX" ] && cp "$NGX" "$old" || : > "$old"
  install -m 644 "$tmp" "$NGX"; rm -f "$tmp"
  [ "${FROZEN_NO_NGINX:-0}" = 1 ] && { rm -f "$old"; return 0; }
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx; rm -f "$old"
  else
    echo "nginx не принял настройку, откатил:"; nginx -t
    if [ -s "$old" ]; then install -m 644 "$old" "$NGX"; else rm -f "$NGX"; fi
    rm -f "$old"; return 1
  fi
}

# --- собрать отдаваемую копию из исходной + правил: $1 токен $2 название -> BUILT (серверов) ---
build() {
  local tok=$1 name=$2 r t ext
  r=$(raw "$tok"); [ -f "$r" ] || { BUILT=0; return 1; }
  ext=${r##*.}; t=$(mktemp)
  BUILT=$(py build "$(src "$tok")" "$(rules "$tok")" "$t") || { rm -f "$t"; return 1; }
  [ "$ext" = json ] && compact "$t"
  if [ "$ext" = txt ]; then
    { echo "#profile-title: base64:$(b64 "$name")"; cat "$t"; } > "$t.2"; mv "$t.2" "$t"
    install -m 644 "$t" "$DIR/$tok.txt"; rm -f "$DIR/$tok.json"
  else
    install -m 644 "$t" "$DIR/$tok.json"; rm -f "$DIR/$tok.txt"
  fi
  rm -f "$t"
}

# --- скачать: $1 источник $2 токен $3 название $4 hwid -> исходная копия + build; FETCHED/BUILT ---
fetch() {
  local url=$1 tok=$2 name=$3 hw=${4:-} t n b code
  local args=(-sSL --connect-timeout 5 --max-time "$FETCH_TIMEOUT" -A "$UA") px
  px=$(meta "$tok" proxy); px=${px:-${FROZEN_PROXY:-}}
  [ -n "$px" ] && args+=(-x "$px")
  [ -n "$hw" ] && args+=(-H "x-hwid: $hw" -H "x-device-os: $DEV_OS" -H "x-ver-os: $DEV_VER" -H "x-device-model: $DEV_MODEL")
  t=$(mktemp -d)
  code=$(curl "${args[@]}" -D "$t/hdr" -o "$t/raw" -w '%{http_code}' "$url") || code=000
  if [ "$code" != 200 ]; then
    echo "Не удалось скачать «$name» (ответ $code)."
    if grep -qi '^x-hwid-not-supported: *true' "$t/hdr"; then
      echo "  Провайдер требует HWID — задай его: «3) Название, описание, HWID, режим»."
    elif grep -qi '^x-hwid-max-devices-reached: *true' "$t/hdr"; then
      echo "  Достигнут лимит устройств. Удали лишнее устройство у провайдера (в его боте/кабинете)"
      echo "  или вставь HWID уже привязанного устройства (например, телефона)."
    elif [ "$code" = 000 ]; then
      echo "  Сайт недоступен, не ответил за $FETCH_TIMEOUT с или ссылка неверная."
    fi
    rm -rf "$t"; return 1
  fi
  # срок подписки у провайдера (subscription-userinfo: ...; expire=UNIX)
  b=$(grep -i '^subscription-userinfo:' "$t/hdr" | grep -oi 'expire=[0-9]*' | tail -1 | cut -d= -f2)
  [ -n "$b" ] && set_meta "$tok" expire "$b"
  sed -i '1s/^\xEF\xBB\xBF//' "$t/raw"   # BOM

  if jq -e 'type=="array" or type=="object"' "$t/raw" >/dev/null 2>&1; then
    jq 'if type=="array" then . else [.] end' "$t/raw" > "$t/out"
    n=$(jq length "$t/out")
    [ "$n" -gt 0 ] || { echo "Подписка «$name» пустая."; rm -rf "$t"; return 1; }
    install -m 600 "$t/out" "$RAWDIR/$tok.json"; rm -f "$RAWDIR/$tok.txt"
  else
    if grep -qE '^[a-z0-9]+://' "$t/raw"; then
      cp "$t/raw" "$t/links"
    else
      b=$(tr -d ' \r\n\t' < "$t/raw" | tr '_-' '/+')
      while [ $(( ${#b} % 4 )) -ne 0 ]; do b+="="; done
      printf '%s' "$b" | base64 -d > "$t/links" 2>/dev/null || true
    fi
    grep -E '^[a-z0-9]+://' "$t/links" | tr -d '\r' > "$t/only" || true
    n=$(wc -l < "$t/only")
    if [ "$n" -eq 0 ]; then
      echo "В ответе «$name» нет ни ссылок, ни JSON. Начало ответа:"; head -c 200 "$t/raw"; echo
      rm -rf "$t"; return 1
    fi
    install -m 600 "$t/only" "$RAWDIR/$tok.txt"; rm -f "$RAWDIR/$tok.json"
  fi
  rm -rf "$t"
  FETCHED=$n
  build "$tok" "$name"
}

# запись в списке: заменить строку с токеном на месте (или добавить в конец)
save_row() { # tok name url date count desc hwid mode
  local tmp row; tmp=$(mktemp)
  row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8")
  awk -F'\t' -v t="$1" -v r="$row" '$1==t{print r; f=1; next} {print} END{if(!f) print r}' "$LIST" > "$tmp"
  cat "$tmp" > "$LIST"; rm -f "$tmp"
}

# у скольких клиентов подписка / есть ли вообще
users_of() { awk -F'|' -v t="$1" '{n=split($2,a,","); for(i=1;i<=n;i++) if(a[i]==t) print $1}' "$CSUBS"; }

# пересобрать подписки клиентов, если подписку кто-то использует
apply_clients() {
  [ -n "$(users_of "$1")" ] || return 0
  [ -x "$MERGE" ] || return 0
  echo "Обновляю подписки клиентов…"; "$MERGE" || true
}

# старые записи без исходной копии: берём её из отдаваемого файла
migrate() {
  local tok
  while IFS=$'\037' read -r tok _; do
    [ -n "$tok" ] || continue
    [ -f "$RAWDIR/$tok.txt" ] || [ -f "$RAWDIR/$tok.json" ] && continue
    if [ -f "$DIR/$tok.json" ]; then install -m 600 "$DIR/$tok.json" "$RAWDIR/$tok.json"
    elif [ -f "$DIR/$tok.txt" ]; then grep -E '^[a-z0-9]+://' "$DIR/$tok.txt" > "$RAWDIR/$tok.txt"; chmod 600 "$RAWDIR/$tok.txt"
    fi
  done < <(rows)
}

# «обновляемая» подписка: перекачать, если устарела ($1 токен, $2 = force)
refresh_live() {
  local tok=$1 force=${2:-} r name url date n desc hw mode age
  r=$(row_of "$tok"); [ -n "$r" ] || return 1
  IFS=$'\037' read -r tok name url date n desc hw mode <<< "$r"
  [ "${mode:-}" = live ] || return 0
  check_freeze "$tok" && return 0
  if [ -z "$force" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$(raw "$tok")" 2>/dev/null || echo 0) ))
    [ "$age" -lt "$LIVE_TTL" ] && return 0
    # провайдер недавно не ответил — отдаём старую копию, не ждём таймаут на каждом клиенте
    age=$(( $(date +%s) - $(stat -c %Y "$RAWDIR/$tok.fail" 2>/dev/null || echo 0) ))
    [ "$age" -lt "$FAIL_TTL" ] && return 0
  fi
  if fetch "$url" "$tok" "$name" "${hw:-}" >&2; then
    rm -f "$RAWDIR/$tok.fail"
    save_row "$tok" "$name" "$url" "$(date +%F)" "$BUILT" "${desc:-}" "${hw:-}" live
    check_freeze "$tok" || true
  else
    touch "$RAWDIR/$tok.fail"
    echo "  «$name»: оставляю прежнюю копию, следующая попытка не раньше чем через $FAIL_TTL с" >&2
  fi
}

# ===================== режимы без меню =====================
if [ "${1:-}" = --json ]; then
  migrate
  out=$(mktemp); echo '[]' > "$out"
  for tok in ${2//,/ }; do
    [ -n "$(row_of "$tok")" ] || { echo "  ! подписки $tok нет" >&2; continue; }
    refresh_live "$tok"
    r=$(raw "$tok"); [ -f "$r" ] || continue
    py json "$(src "$tok")" "$(rules "$tok")" > "$out.p" && compact "$out.p" && jq -s 'add' "$out" "$out.p" > "$out.n" && mv "$out.n" "$out"
  done
  cat "$out"; rm -f "$out" "$out.p"
  exit 0
fi
if [ "${1:-}" = --refresh ]; then
  migrate
  while IFS=$'\037' read -r tok _ _ _ _ _ _ mode; do
    [ "${mode:-}" = live ] && refresh_live "$tok" force
  done < <(rows)
  exit 0
fi

# ===================== меню =====================
show() {
  echo; echo "=== Подписки провайдеров ==="
  if [ ! -s "$LIST" ]; then echo "(пока нет)"; return; fi
  local i=0 u e
  while IFS=$'\037' read -r tok name url date n desc hw mode; do
    i=$((i+1))
    u=$(users_of "$tok" | wc -l)
    echo "$i. $name  ($n серверов, скачана $date$([ "$u" -gt 0 ] && echo ", у клиентов: $u"))"
    echo "      режим: $(mode_text "${mode:-}" "$(meta "$tok" until)" "$tok")$([ "${mode:-}" != live ] && [ -n "$(meta "$tok" frozen_at)" ] && echo " (сама, $(meta "$tok" frozen_at))")"
    e=$(meta "$tok" expire); [[ "$e" =~ ^[0-9]+$ ]] && [ "$e" -gt 0 ] && echo "      срок у провайдера: до $(dmy "$e")"
    [ -n "${desc:-}" ] && echo "      описание: $desc"
    [ -n "${hw:-}" ] && echo "      HWID: $hw"
    [ "$(jq '.order // [] | length' "$(rules "$tok")")" -gt 0 ] && echo "      свой порядок серверов"
    [ -n "$(meta "$tok" proxy)" ] && echo "      качается через прокси: $(px_text "$(meta "$tok" proxy)")"
    echo "      $FROZEN_BASE/$tok"
    echo "      источник: ${url:0:60}$([ ${#url} -gt 60 ] && echo …)"
  done < <(rows)
}

pick() { # -> ROW (строка списка)
  local k total
  total=$(wc -l < "$LIST")
  [ "$total" -gt 0 ] || { echo "Список пуст."; return 1; }
  read -rp "Номер подписки: " k
  [[ "$k" =~ ^[0-9]+$ ]] && [ "$k" -ge 1 ] && [ "$k" -le "$total" ] || { echo "Нет такой."; return 1; }
  ROW=$(sed -n "${k}p" "$LIST" | tr '\t' '\037')
}

ask_name() { # $1 текущее -> NEW_NAME
  local v
  read -rp "Название в Happ${1:+ ($1)}: " v
  NEW_NAME=$(printf '%s' "${v:-$1}" | tr -d '\t|')
  [ ${#NEW_NAME} -gt 25 ] && echo "  (длиннее 25 символов — Happ обрежет)"
  return 0
}

ask_desc() { # $1 текущее -> NEW_DESC ; «-» очищает
  local v
  echo "Описание (показывается в Happ под подпиской). Enter — оставить, «-» — убрать."
  [ -n "$1" ] && echo "  сейчас: $1"
  read -rp "> " v
  case "$v" in
    "") NEW_DESC=$1 ;;
    -)  NEW_DESC="" ;;
    *)  NEW_DESC=$(printf '%s' "$v" | tr -d '\t') ;;
  esac
  [ ${#NEW_DESC} -gt 200 ] && echo "  (длиннее 200 символов — Happ обрежет)"
  return 0
}

gen_hwid() { head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

ask_hwid() { # $1 текущее -> NEW_HW
  local v keep="без HWID"; [ -n "$1" ] && keep="оставить «$1»"
  echo "HWID — нужен, только если провайдер ограничивает устройства."
  echo "  Enter — $keep, «+» — сгенерировать новый, «-» — убрать,"
  echo "  или вставь HWID своего телефона, чтобы не занимать лишнее устройство."
  read -rp "> " v
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in
    "") NEW_HW=$1 ;;
    -)  NEW_HW="" ;;
    +)  NEW_HW=$(gen_hwid); echo "  HWID: $NEW_HW" ;;
    *)  if [[ "$v" =~ ^[A-Za-z0-9=-]{10,64}$ ]]; then NEW_HW=$v
        else echo "  HWID — 10–64 символа: латиница, цифры, «=», «-». Оставляю как было."; NEW_HW=$1; fi ;;
  esac
  return 0
}

px_text() { printf '%s' "$1" | sed -E 's#//[^/@]*@#//***@#'; }   # без логина/пароля

ask_proxy() { # $1 текущий -> NEW_PX
  local v keep="без прокси"; [ -n "$1" ] && keep="оставить $(px_text "$1")"
  echo "Прокси для скачивания — нужен, если провайдер не пускает IP сервера (таймаут при скачивании)."
  echo "  Enter — $keep, «-» — убрать, или адрес: socks5h://логин:пароль@хост:порт, http://хост:порт"
  read -rp "> " v
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in
    "") NEW_PX=$1 ;;
    -)  NEW_PX="" ;;
    *)  if [[ "$v" =~ ^(https?|socks4a?|socks5h?)://[^[:space:]]+:[0-9]+/?$ ]]; then NEW_PX=$v
        else echo "  Не понял адрес прокси (нужно схема://[логин:пароль@]хост:порт). Оставляю как было."; NEW_PX=$1; fi ;;
  esac
  return 0
}

ask_mode() { # $1 режим $2 until $3 токен -> NEW_MODE NEW_UNTIL
  local v d cur; cur=$(mode_text "${1:-}" "${2:-}" "${3:-}")
  echo "Режим:"
  echo "  1) заморожена — не меняется"
  echo "  2) обновляется всегда"
  echo "  3) обновляется до конца подписки, за $FREEZE_DAYS дн. до конца — замораживается"
  read -rp "Enter — $cur: " v
  NEW_MODE=${1:-frozen}; NEW_UNTIL=${2:-}
  case "$v" in
    1) NEW_MODE=frozen; NEW_UNTIL="" ;;
    2) NEW_MODE=live;   NEW_UNTIL="" ;;
    3) NEW_MODE=live
       echo "Когда кончается подписка? Enter — взять срок у провайдера, или дата ДД.ММ.ГГГГ"
       read -rp "> " d
       d=$(printf '%s' "$d" | tr -d '[:space:]')
       if [ -z "$d" ]; then NEW_UNTIL=auto
       elif [[ "$d" =~ ^([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})$ ]] \
            && NEW_UNTIL=$(printf '%04d-%02d-%02d' "${BASH_REMATCH[3]}" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[1]}))") \
            && date -d "$NEW_UNTIL" >/dev/null 2>&1; then :
       else echo "  Не понял дату — беру срок у провайдера."; NEW_UNTIL=auto; fi ;;
  esac
  return 0
}

add() {
  local url tok
  read -rp "Ссылка на подписку: " url
  url=$(echo "$url" | tr -d '[:space:]')
  [[ "$url" =~ ^https?:// ]] || { echo "Нужна ссылка, начинающаяся с http(s)://"; return; }
  ask_name "Подписка"
  ask_desc ""
  ask_hwid ""
  ask_proxy ""
  ask_mode frozen "" ""
  tok=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
  [ -n "$NEW_PX" ] && set_meta "$tok" proxy "$NEW_PX"
  fetch "$url" "$tok" "$NEW_NAME" "$NEW_HW" || { rm -f "$RAWDIR/$tok".* "$RULESDIR/$tok.json"; return; }
  save_row "$tok" "$NEW_NAME" "$url" "$(date +%F)" "$BUILT" "$NEW_DESC" "$NEW_HW" "$NEW_MODE"
  if ! gen_nginx; then
    rm -f "$DIR/$tok".* "$RAWDIR/$tok".* "$RULESDIR/$tok.json"
    awk -F'\t' -v t="$tok" '$1!=t' "$LIST" > "$LIST.tmp" && cat "$LIST.tmp" > "$LIST" && rm -f "$LIST.tmp"
    return
  fi
  set_meta "$tok" until "$NEW_UNTIL"
  if [ "$NEW_UNTIL" = auto ] && [ -z "$(end_ts "$tok")" ]; then
    echo "⚠ Провайдер не сообщает срок подписки — задай дату: пункт 3 → режим 3."
  fi
  check_freeze "$tok" 2>&1 || true
  echo; echo "Готово, серверов: $BUILT. Ссылка для Happ:"
  echo "  $FROZEN_BASE/$tok"
  echo "Серверы можно переименовать/отключить: пункт 4. Добавить клиенту: пункт 5."
}

refetch() {
  local tok name url date n desc hw mode
  pick || return
  IFS=$'\037' read -r tok name url date n desc hw mode <<< "$ROW"
  echo "Перекачиваю «$name»… ссылка для Happ останется той же."
  fetch "$url" "$tok" "$name" "${hw:-}" || { echo "Старая копия не тронута."; return; }
  save_row "$tok" "$name" "$url" "$(date +%F)" "$BUILT" "${desc:-}" "${hw:-}" "${mode:-frozen}"
  echo "Обновлено, серверов: $BUILT из $FETCHED. В Happ обнови подписку."
  apply_clients "$tok"
}

edit_meta() {
  local tok name url date n desc hw mode f a px
  pick || return
  IFS=$'\037' read -r tok name url date n desc hw mode <<< "$ROW"
  ask_name "$name"
  ask_desc "${desc:-}"
  ask_hwid "${hw:-}"
  px=$(meta "$tok" proxy); ask_proxy "$px"
  ask_mode "${mode:-frozen}" "$(meta "$tok" until)" "$tok"
  set_meta "$tok" proxy "$NEW_PX"
  if [ "$NEW_HW" != "${hw:-}" ] || [ "$NEW_PX" != "$px" ]; then
    read -rp "HWID или прокси изменены. Перекачать подписку сейчас? [Y/n]: " a
    if [[ ! "$a" =~ ^[nNнН]$ ]]; then
      if fetch "$url" "$tok" "$NEW_NAME" "$NEW_HW"; then n=$BUILT; date=$(date +%F); echo "Скачано серверов: $FETCHED."
      else echo "Старая копия не тронута, HWID всё равно сохраняю."; fi
    fi
  fi
  # снова «обновляется» — сразу скачать свежую версию (и свежий срок подписки)
  if [ "$NEW_MODE" = live ] && [ "${mode:-}" != live ]; then
    set_meta "$tok" frozen_at ""
    if fetch "$url" "$tok" "$NEW_NAME" "$NEW_HW"; then n=$BUILT; date=$(date +%F); fi
  fi
  save_row "$tok" "$NEW_NAME" "$url" "$date" "$n" "$NEW_DESC" "$NEW_HW" "$NEW_MODE"
  set_meta "$tok" until "$NEW_UNTIL"
  if [ "$NEW_MODE" = live ] && [ "$NEW_UNTIL" = auto ] && [ -z "$(end_ts "$tok")" ]; then
    echo "⚠ Провайдер не сообщает срок подписки — замораживать не по чему. Задай дату вручную."
  fi
  check_freeze "$tok" 2>&1 || true
  f="$DIR/$tok.txt"
  [ -f "$f" ] && sed -i "1s|^#profile-title: .*|#profile-title: base64:$(b64 "$NEW_NAME")|" "$f"
  if gen_nginx; then
    echo "Сохранено. В Happ обнови подписку."
  else
    save_row "$tok" "$name" "$url" "$date" "$n" "${desc:-}" "$NEW_HW" "$NEW_MODE"   # откат названия/описания
    [ -f "$f" ] && sed -i "1s|^#profile-title: .*|#profile-title: base64:$(b64 "$name")|" "$f"
  fi
}

# --- серверы подписки: переименовать / отключить ---
servers() {
  local tok name url date n desc hw mode rf r list c nums k key new changed=0
  pick || return
  IFS=$'\037' read -r tok name url date n desc hw mode <<< "$ROW"
  rf=$(rules "$tok"); r=$(raw "$tok")
  [ -f "$r" ] || { echo "Нет скачанной копии — сначала «Перекачать»."; return; }
  while true; do
    list=$(py list "$(src "$tok")" "$rf")
    echo; echo "=== Серверы «$name» ==="
    [ -n "$list" ] || { echo "(в подписке нет серверов)"; return; }
    while IFS=$'\037' read -r i key proto new off; do
      printf '%3s. %s %s%s   (%s)\n' "$i" "$([ "$off" = 1 ] && echo '[выкл]' || echo '[вкл] ')" "$key" \
        "$([ -n "$new" ] && echo " → $new")" "$proto"
    done <<< "$list"
    echo; echo "1) Переименовать   2) Выключить/включить   3) Вернуть исходные имена   4) Включить все   0) Готово"
    read -rp "> " c || break
    case "$c" in
      1) read -rp "Номер сервера: " k
         key=$(awk -F'\037' -v k="$k" '$1==k{print $2}' <<< "$list")
         [ -n "$key" ] || { echo "Нет такого."; continue; }
         read -rp "Новое имя для «$key» (Enter — исходное): " new
         if [ -n "$new" ]; then jq --arg k "$key" --arg v "$new" '.rename[$k]=$v' "$rf" > "$rf.tmp"
         else jq --arg k "$key" 'del(.rename[$k])' "$rf" > "$rf.tmp"; fi
         mv "$rf.tmp" "$rf"; changed=1 ;;
      2) read -rp "Номера через пробел: " nums
         for k in $nums; do
           key=$(awk -F'\037' -v k="$k" '$1==k{print $2}' <<< "$list")
           [ -n "$key" ] || { echo "  нет номера $k"; continue; }
           jq --arg k "$key" 'if (.skip|index($k)) then .skip -= [$k] else .skip += [$k] end' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
         done; changed=1 ;;
      3) jq '.rename={}' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"; changed=1 ;;
      4) jq '.skip=[]' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"; changed=1 ;;
      0|q|"") break ;;
      *) echo "?" ;;
    esac
  done
  [ "$changed" = 1 ] || return 0
  build "$tok" "$name" || { echo "Не удалось пересобрать подписку."; return; }
  save_row "$tok" "$name" "$url" "$date" "$BUILT" "${desc:-}" "${hw:-}" "${mode:-frozen}"
  echo "Сохранено, включено серверов: $BUILT. В Happ обнови подписку."
  apply_clients "$tok"
}

# --- подписки провайдеров у клиентов склеенной подписки ---
clients_menu() {
  local ids notes k sid note cur subs toks i nums t sel line names
  [ -s "$CLIENTS" ] || { echo "Нет клиентов (clients.sh) — подписки добавляются в их склеенную JSON-подписку."; return; }
  [ -s "$LIST" ] || { echo "Сначала добавь подписку провайдера (пункт 1)."; return; }
  while true; do
    echo; echo "=== Подписки провайдеров у клиентов ==="
    i=0; ids=()
    while IFS='|' read -r sid note _; do
      sid=$(printf '%s' "$sid" | tr -d '[:space:]')
      [[ -z "$sid" || "$sid" == \#* ]] && continue
      i=$((i+1)); ids+=("$sid")
      cur=$(awk -F'|' -v s="$sid" '$1==s{print $2}' "$CSUBS")
      names=""
      for t in ${cur//,/ }; do
        line=$(awk -F'\t' -v t="$t" '$1==t{print $2}' "$LIST")
        names+="${names:+, }${line:-?}"
      done
      echo "$i. ${note:-$sid}  ($sid)"
      echo "      подписки: ${names:-—}"
    done < "$CLIENTS"
    echo; read -rp "Номер клиента (Enter — назад): " k
    [ -n "$k" ] || return 0
    [[ "$k" =~ ^[0-9]+$ ]] && [ "$k" -ge 1 ] && [ "$k" -le "${#ids[@]}" ] || { echo "Нет такого."; continue; }
    sid=${ids[$((k-1))]}
    cur=$(awk -F'|' -v s="$sid" '$1==s{print $2}' "$CSUBS")
    echo; echo "Подписки для $sid ([x] — добавлена):"
    mapfile -t toks < <(cut -f1 "$LIST")
    i=0
    while IFS=$'\037' read -r t name _ _ n _ _ mode; do
      i=$((i+1))
      [[ ",$cur," == *",$t,"* ]] && sel="[x]" || sel="[ ]"
      echo "  $i. $sel $name  ($n серверов, $(mode_text "${mode:-}" "$(meta "$t" until)" "$t"))"
    done < <(rows)
    read -rp "Номера через пробел — добавить/убрать: " nums
    for k in $nums; do
      [[ "$k" =~ ^[0-9]+$ ]] && [ "$k" -ge 1 ] && [ "$k" -le "${#toks[@]}" ] || { echo "  нет номера $k"; continue; }
      t=${toks[$((k-1))]}
      if [[ ",$cur," == *",$t,"* ]]; then cur=$(tr ',' '\n' <<< "$cur" | grep -vxF "$t" | paste -sd, -)
      else cur="${cur:+$cur,}$t"; fi
    done
    awk -F'|' -v s="$sid" '$1!=s' "$CSUBS" > "$CSUBS.tmp"
    [ -n "$cur" ] && echo "$sid|$cur" >> "$CSUBS.tmp"
    cat "$CSUBS.tmp" > "$CSUBS"; rm -f "$CSUBS.tmp"
    if [ -x "$MERGE" ]; then echo "Обновляю подписки клиентов…"; "$MERGE" || true; fi
    echo "Готово. Клиенту достаточно обновить подписку в Happ."
  done
}

# --- порядок серверов подписки (так их увидят в Happ и в склеенных подписках клиентов) ---
order_menu() {
  local tok name url date n desc hw mode rf list i c nums t to moved=0 changed=0
  local keys=() labels=() idx=() sel=() picked=() rest=()
  pick || return
  IFS=$'\037' read -r tok name url date n desc hw mode <<< "$ROW"
  rf=$(rules "$tok")
  [ -f "$(raw "$tok")" ] || { echo "Нет скачанной копии — сначала «Перекачать»."; return; }
  load_order() { # $1 — файл копии; заполняет keys/labels, idx = по порядку
    keys=(); labels=(); idx=()
    while IFS=$'\037' read -r _ key _ new off; do
      keys+=("$key"); labels+=("$([ "$off" = 1 ] && echo '[выкл] ')${new:-$key}")
    done < <(py list "$1" "$rf")
    for i in "${!keys[@]}"; do idx+=("$i"); done
  }
  load_order "$(src "$tok")"
  [ "${#keys[@]}" -gt 0 ] || { echo "(в подписке нет серверов)"; return; }
  while true; do
    echo; echo "=== Порядок серверов «$name» (так их увидят в Happ) ==="
    for i in "${!idx[@]}"; do printf '%3d. %s\n' $((i+1)) "${labels[${idx[$i]}]}"; done
    echo
    echo "1) Переместить (можно несколько: «5 6 7» или «5-7»)   2) Как у провайдера   0) Сохранить и выйти"
    read -rp "> " c || break
    case "$c" in
      1) read -rp "Какие номера: " nums
         sel=()
         for t in ${nums//,/ }; do
           if [[ "$t" =~ ^([0-9]+)-([0-9]+)$ ]]; then sel+=($(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"))
           else sel+=("$t"); fi
         done
         picked=(); rest=()
         for i in "${!idx[@]}"; do
           if [[ " ${sel[*]-} " == *" $((i+1)) "* ]]; then picked+=("${idx[$i]}"); else rest+=("${idx[$i]}"); fi
         done
         [ "${#picked[@]}" -gt 0 ] || { echo "  нет таких номеров"; continue; }
         read -rp "На какое место поставить (1 — в начало, $(( ${#rest[@]} + 1 )) — в конец): " to
         [[ "$to" =~ ^[0-9]+$ ]] && [ "$to" -ge 1 ] || { echo "Не понял место."; continue; }
         [ "$to" -gt $(( ${#rest[@]} + 1 )) ] && to=$(( ${#rest[@]} + 1 ))
         idx=("${rest[@]:0:$((to-1))}" "${picked[@]}" "${rest[@]:$((to-1))}")
         moved=1; changed=1 ;;
      2) jq 'del(.order)' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
         load_order "$(raw "$tok")"; moved=0; changed=1
         echo "Порядок как в подписке провайдера." ;;
      0|q|"") break ;;
      *) echo "?" ;;
    esac
  done
  [ "$changed" = 1 ] || return 0
  if [ "$moved" = 1 ]; then
    for i in "${idx[@]}"; do printf '%s\n' "${keys[$i]}"; done | jq -R . | jq -s . > "$ORDTMP/order.json"
    jq --slurpfile o "$ORDTMP/order.json" '.order = $o[0]' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
  fi
  build "$tok" "$name" || { echo "Не удалось пересобрать подписку."; return; }
  save_row "$tok" "$name" "$url" "$date" "$BUILT" "${desc:-}" "${hw:-}" "${mode:-frozen}"
  echo "Сохранено. В Happ обнови подписку."
  apply_clients "$tok"
}

delete() {
  local tok name a u
  pick || return
  IFS=$'\037' read -r tok name _ <<< "$ROW"
  u=$(users_of "$tok" | wc -l)
  [ "$u" -gt 0 ] && echo "Подписка добавлена клиентам: $u — у них её серверы пропадут."
  read -rp "Удалить «$name»? Ссылка перестанет работать [y/N]: " a
  [[ "$a" =~ ^[yYдД]$ ]] || return
  rm -f "$DIR/$tok.txt" "$DIR/$tok.json" "$RAWDIR/$tok".* "$RULESDIR/$tok.json"
  awk -F'\t' -v t="$tok" '$1!=t' "$LIST" > "$LIST.tmp" && cat "$LIST.tmp" > "$LIST" && rm -f "$LIST.tmp"
  # убрать у клиентов
  awk -F'|' -v OFS='|' -v t="$tok" '{n=split($2,a,","); s=""; for(i=1;i<=n;i++) if(a[i]!=t) s=s (s?",":"") a[i]; if(s!="") print $1,s}' \
    "$CSUBS" > "$CSUBS.tmp" && cat "$CSUBS.tmp" > "$CSUBS" && rm -f "$CSUBS.tmp"
  gen_nginx || true
  [ "$u" -gt 0 ] && [ -x "$MERGE" ] && { echo "Обновляю подписки клиентов…"; "$MERGE" || true; }
  echo "Удалено."
}

migrate
[ "${1:-}" = --clients ] && { clients_menu; exit 0; }
# старый frozen.conf (одно общее правило) → переписать на новый формат
[ -s "$LIST" ] && [ -f "$NGX" ] && ! grep -q '^location = ' "$NGX" && gen_nginx

while true; do
  show
  echo
  echo "1) Добавить подписку   2) Перекачать   3) Название, описание, HWID, режим"
  echo "4) Серверы (переименовать/отключить)   5) Подписки клиентам   6) Удалить"
  echo "7) Порядок серверов   0) Назад"
  read -rp "> " c || exit 0
  case "$c" in
    1) add ;;
    2) refetch ;;
    3) edit_meta ;;
    4) servers ;;
    7) order_menu ;;
    5) clients_menu ;;
    6) delete ;;
    0|q|"") exit 0 ;;
    *) echo "?" ;;
  esac
done
