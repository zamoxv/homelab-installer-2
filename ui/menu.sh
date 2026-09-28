#!/usr/bin/env bash
set -euo pipefail

# Dashboard del servidor: hardware + red + estado de TODOS los servicios del
# registro (services/*.conf), sin hardcodear ninguno acá.
show_dashboard() {
  local ip host kernel os model cpu ram disk_root disk_use
  ip="$(get_ip || true)"
  host="$(hostname)"
  kernel="$(uname -r)"
  os="$(os_pretty)"
  model="$(hw_model)"
  cpu="$(hw_cpu)"
  ram="$(hw_ram)"
  disk_root="$(hw_disk)"
  disk_use="$(space_bar)"

  local media_block="" mr du
  while read -r mr; do
    [[ -n "$mr" ]] || continue
    du="$(df -h --output=used,size "$mr" 2>/dev/null | tail -n1 | awk '{print $1, $2}')" || true
    if [[ -n "$du" ]]; then
      media_block+="$(printf '  %-14s: %s usado / %s total' "$mr" "${du%% *}" "${du##* }")"$'\n'
    else
      media_block+="$(printf '  %-14s: sin montar' "$mr")"$'\n'
    fi
  done < <(media_roots)

  local services_block="" id name state url
  while read -r id; do
    [[ -n "$id" ]] || continue
    name="$(service_get "$id" NAME)"
    state="$(service_state "$id")"
    url="$(service_url "$id" "$ip")"
    services_block+="$(printf '  %-16s: %-18s %s' "$name" "$state" "$url")"$'\n'
  done < <(service_list)

  cat > /tmp/hli2-dashboard.txt <<EOF
========================================================
            HLI 2 — HomeLab Installer
========================================================

Equipo    : ${model:-N/D}
CPU       : ${cpu:-N/D}
Memoria   : ${ram:-N/D}
Disco     : ${disk_root:-N/D}

Servidor  : $host
Usuario   : $SERVER_USER
Sistema   : $os
Kernel    : $kernel
IP        : ${ip:-sin IP}

Servicios
$services_block
Espacio en /
  $disk_use

Discos de media
${media_block}  Backups       : $BACKUP_ROOT
  Appdata       : $APPDATA_ROOT
  Logs          : $LOG_DIR
========================================================
EOF

  dialog --title "Dashboard" --textbox /tmp/hli2-dashboard.txt 30 92
}

# Corre un módulo batch en segundo plano mostrando una barra de progreso. La
# salida va al log; si el módulo falla, avisa con la ruta del log y devuelve
# el código de salida del módulo (para que install_full/install_custom sepan
# que falló y sigan con el resto en vez de abortarse).
run_module_gauge() {
  local module="$1" title="$2" pid rc p
  run_module_quiet "$module" &
  pid=$!
  (
    p=5
    while kill -0 "$pid" 2>/dev/null; do
      echo "$p"
      if (( p < 90 )); then p=$((p + 5)); fi
      sleep 1
    done
    echo 100
  ) | dialog --title "$title" --gauge "Instalando $module..." 8 70 5 || true
  rc=0
  wait "$pid" || rc=$?
  if [[ $rc -ne 0 ]]; then
    msg "El módulo '$module' terminó con errores (código $rc).\n\nRevise el log:\n$LOG_DIR/$module.log"
  fi
  return "$rc"
}

# Módulos instalables: todos los que NO son herramientas (HLI-TIPO: tool).
_installable_modules() {
  local m
  for m in $(list_modules); do
    [[ "$(module_meta "$m" TIPO)" == "tool" ]] && continue
    echo "$m"
  done
}

# Arma un resumen "  - modulo (log: /var/log/hli2/modulo.log)" por cada
# módulo fallido, para mostrar en un solo msg() al final de la instalación.
_failed_modules_summary() {
  local f list=""
  for f in "$@"; do
    list+="  - $f ($LOG_DIR/$f.log)"$'\n'
  done
  printf '%s' "$list"
}

install_full() {
  local all=() m i=0 total failed=()
  while read -r m; do
    [[ "$(module_meta "$m" DEFAULT)" == "yes" ]] && all+=("$m")
  done < <(_installable_modules)
  total=${#all[@]}

  confirm "Se instalarán $total módulos recomendados:\n\n${all[*]}\n\n¿Continuar?" || return

  # Cada módulo se corre de forma independiente: si uno falla, se registra y
  # se sigue con el resto (nunca se aborta la instalación completa por un
  # solo módulo).
  for m in "${all[@]}"; do
    i=$((i + 1))
    if [[ "$(module_meta "$m" TUI)" == "yes" ]]; then
      run_module "$m" || failed+=("$m")
    else
      run_module_gauge "$m" "Instalación completa ($i/$total)" || failed+=("$m")
    fi
  done

  if [[ ${#failed[@]} -eq 0 ]]; then
    msg "Instalación completa finalizada sin errores.\n\nRevise el Dashboard para ver el estado de los servicios."
  else
    msg "Instalación completa finalizada CON ERRORES.\n\nMódulos que fallaron:\n$(_failed_modules_summary "${failed[@]}")\nRevise el log de cada uno para más detalle."
  fi
}

install_custom() {
  local args=() m desc state failed=()

  while read -r m; do
    desc="$(module_meta "$m" DESC)"
    [[ "$(module_meta "$m" DEFAULT)" == "yes" ]] && state="ON" || state="OFF"
    args+=("$m" "$desc" "$state")
  done < <(_installable_modules)

  if [[ ${#args[@]} -eq 0 ]]; then
    msg "No hay módulos instalables en modules/."
    return
  fi

  SELECTED=$(dialog --clear \
    --backtitle "HLI 2" \
    --title "Instalación personalizada" \
    --checklist "Seleccione módulos:" \
    22 82 12 \
    "${args[@]}" \
    3>&1 1>&2 2>&3) || return

  for item in $SELECTED; do
    item="${item//\"/}"
    run_module "$item" || failed+=("$item")
  done

  if [[ ${#failed[@]} -gt 0 ]]; then
    msg "Instalación personalizada finalizada CON ERRORES.\n\nMódulos que fallaron:\n$(_failed_modules_summary "${failed[@]}")\nRevise el log de cada uno para más detalle."
  fi
}

# Herramientas: módulos marcados HLI-TIPO: tool (status, healthcheck,
# datadisk...), descubiertos automáticamente igual que los instalables.
tools_menu() {
  local args=() m desc
  for m in $(list_modules); do
    [[ "$(module_meta "$m" TIPO)" == "tool" ]] || continue
    desc="$(module_meta "$m" DESC)"
    args+=("$m" "$desc")
  done

  if [[ ${#args[@]} -eq 0 ]]; then
    msg "No hay herramientas registradas en modules/."
    return
  fi

  local choice
  choice=$(dialog --clear \
    --backtitle "HLI 2" \
    --title "Herramientas" \
    --menu "Seleccione una herramienta:" \
    18 78 8 \
    "${args[@]}" \
    3>&1 1>&2 2>&3) || return

  run_module "$choice" || msg "La herramienta '$choice' terminó con errores.\n\nRevise el log:\n$LOG_DIR/$choice.log"
}

main_menu() {
  while true; do
    CHOICE=$(dialog --clear \
      --backtitle "HLI 2" \
      --title "Menú principal" \
      --menu "Seleccione una opción:" \
      16 78 6 \
      1 "Dashboard del servidor" \
      2 "Instalación completa recomendada" \
      3 "Instalación personalizada" \
      4 "Herramientas" \
      5 "Salir" \
      3>&1 1>&2 2>&3) || exit 0

    # El brace + '|| true' evita que un Cancelar/No en un submenú (estado != 0)
    # mate el bucle del menú por culpa de 'set -e'.
    { case "$CHOICE" in
      1) show_dashboard ;;
      2) install_full ;;
      3) install_custom ;;
      4) tools_menu ;;
      5) clear; exit 0 ;;
    esac; } || true
  done
}
