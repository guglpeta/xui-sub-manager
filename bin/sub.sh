#!/usr/bin/env bash
# Главное меню управления подписками: клиенты, прокси, группы, подписки провайдеров, порядок.
B=/usr/local/bin
while true; do
  echo; echo "=== Управление подписками ==="
  echo "1) Клиенты   2) Прокси   3) Группы   4) TLS у прокси   5) Обновить подписки"
  echo "6) Подписки провайдеров   7) Подписки провайдеров у клиентов"
  echo "8) Порядок серверов у клиента   0) Выход"
  read -rp "> " c || exit 0
  case "$c" in
    1) "$B/clients.sh" ;;
    2) "$B/proxies.sh" ;;
    3) "$B/groups.sh" ;;
    4) "$B/tls-switch.sh" ;;
    5) "$B/merge-json.sh" ;;
    6) "$B/freeze-sub.sh" ;;
    7) "$B/freeze-sub.sh" --clients ;;
    8) "$B/order-sub.sh" ;;
    0|q|"") exit 0 ;;
    *) echo "?" ;;
  esac
done
