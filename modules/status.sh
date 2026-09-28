#!/usr/bin/env bash
# HLI-MODULE: status
# HLI-DESC: Ver estado de servicios
# HLI-ORDER: 90
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

{
  echo "== Sistema =="
  hostnamectl || true
  echo
  echo "== IP =="
  hostname -I || true
  echo
  echo "== Servicios (registro: services/*.conf) =="
  ip="$(get_ip)"
  while read -r id; do
    [[ -n "$id" ]] || continue
    name="$(service_get "$id" NAME)"
    state="$(service_state "$id")"
    url="$(service_url "$id" "$ip")"
    printf "%-16s %-20s %s\n" "$name" "$state" "$url"
  done < <(service_list)
  echo
  echo "== Disco =="
  df -h
  echo
  echo "== /srv =="
  sudo du -sh /srv/* 2>/dev/null || true
} > /tmp/hli2-status.txt

dialog --title "Estado del servidor" --textbox /tmp/hli2-status.txt 28 100 || cat /tmp/hli2-status.txt

mark_done status
