#!/usr/bin/env bash
# HLI-MODULE: healthcheck
# HLI-DESC: Diagnóstico del servidor (Health Check)
# HLI-ORDER: 95
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

REPORT=/tmp/hli2-healthcheck.txt

# Recolección best-effort: subshell con errexit desactivado para que un
# chequeo fallido (herramienta ausente, disco sin SMART) no aborte el informe.
(
  set +e

  echo "== Sistema =="
  echo "Host    : $(hostname)"
  echo "Kernel  : $(uname -r)"
  echo "Uptime  : $(uptime -p 2>/dev/null)"
  echo

  echo "== Red =="
  echo "IP      : $(get_ip)"
  echo -n "DNS     : "
  if getent hosts github.com >/dev/null 2>&1; then
    echo "OK (resuelve github.com)"
  else
    echo "FALLA (no resuelve)"
  fi
  echo

  echo "== Memoria =="
  free -h
  echo

  echo "== Disco =="
  df -h --output=source,size,used,avail,pcent,target 2>/dev/null \
    | grep -vE '^(tmpfs|devtmpfs|udev|/dev/loop)' \
    || df -h
  echo

  echo "== Temperatura =="
  if command -v sensors >/dev/null 2>&1; then
    sensors 2>/dev/null | grep -E '°C' | head -n 10
  else
    echo "lm-sensors no instalado"
  fi
  echo

  echo "== SMART discos =="
  if command -v smartctl >/dev/null 2>&1; then
    for d in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
      # '|| true': smartctl devuelve códigos de salida no-cero por diseño
      # (son flags de estado del disco, no solo "falló el comando"); bajo
      # pipefail eso abortaría el healthcheck completo en el primer disco
      # con cualquier bit de advertencia, antes de imprimir nada del resto.
      health="$(sudo smartctl -H "/dev/$d" 2>/dev/null | grep -i 'overall-health' | sed 's/.*: //')" || true
      printf "  /dev/%-6s %s\n" "$d" "${health:-sin datos}"
    done
  else
    echo "smartmontools no instalado"
  fi
  echo

  echo "== Servicios (registro: services/*.conf) =="
  while read -r id; do
    [[ -n "$id" ]] || continue
    printf "  %-16s %s\n" "$(service_get "$id" NAME)" "$(service_state "$id")"
  done < <(service_list)
  echo

  echo "== Puertos en escucha =="
  ss -tlnH 2>/dev/null | awk '{print $4}' | sort -u | head -n 20
) > "$REPORT"

dialog --title "Health Check" --textbox "$REPORT" 30 100 || cat "$REPORT"

mark_done healthcheck
