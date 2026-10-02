#!/usr/bin/env bash
# HLI-MODULE: import-v1
# HLI-DESC: Importar configuración desde un backup del HLI v1 (todo en uno)
# HLI-ORDER: 59
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
#
# Extrae UNA vez un backup-<fecha>.tar.gz del HLI v1 (homelab-installer) e
# importa lo que corresponda a cada componente (Jellyfin, qBittorrent,
# AdGuard, claves SSH). Alternativa a hacerlo servicio por servicio desde
# cada módulo (jellyfin.sh/qbittorrent.sh/adguard.sh también ofrecen la
# importación individual con el mismo backup). Samba y la config del propio
# HLI NUNCA se importan a ciegas acá: Samba lo genera el módulo "samba"
# (v2.0), y default.conf del v1 no es compatible con el formato de HLI 2.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

# Resultado de importer_apply_service -> línea del resumen.
_import_v1_note() {
  local label="$1" rc="$2"
  case "$rc" in
    0) printf '  - %s: importado.\n' "$label" ;;
    10) printf '  - %s: importado, pero NO se pudo volver a desplegar (ejecute su módulo desde el menú).\n' "$label" ;;
    *) printf '  - %s: FALLÓ la importación (ver el log).\n' "$label" ;;
  esac
}

_import_v1_main() {
  local tar_path

  tar_path=$(input_box "Importar desde HLI v1" "Ruta al backup-<fecha>.tar.gz del HLI v1:") || return 0
  [[ -n "$tar_path" ]] || { msg "Ruta vacía: se cancela."; return 0; }

  # 1) Inspeccionar el backup SIN extraerlo (importer_inspect): qué
  # componentes trae y cuánto pesa. En el shell actual, no en $(...): así la
  # caché del listado sobrevive y importer_extract no relee el tar.
  importer_inspect "$tar_path" || { msg "No se pudo leer el backup. Revise la ruta y que sea un tar.gz válido del HLI v1."; return 1; }

  # 2) Decidir (y preguntar) por componente ANTES de extraer: la extracción
  # es lo lento, y no tiene sentido hacerla si no se va a importar nada.
  local summary="" do_jf=0 do_qb=0 do_ag=0 do_ssh=0

  if importer_inspect_has jellyfin; then
    if confirm "¿Importar Jellyfin (jellyfin/lib + jellyfin/etc del backup)?"; then
      if importer_gate_service jellyfin "Jellyfin"; then do_jf=1; else summary+="  - Jellyfin: OMITIDO.\n"; fi
    else
      summary+="  - Jellyfin: no seleccionado.\n"
    fi
  else
    summary+="  - Jellyfin: no viene en el backup.\n"
  fi

  if importer_inspect_has qbittorrent; then
    if confirm "¿Importar qBittorrent (qbittorrent/config + qbittorrent/share del backup)?"; then
      if importer_gate_service qbittorrent "qBittorrent"; then do_qb=1; else summary+="  - qBittorrent: OMITIDO.\n"; fi
    else
      summary+="  - qBittorrent: no seleccionado.\n"
    fi
  else
    summary+="  - qBittorrent: no viene en el backup.\n"
  fi

  if importer_inspect_has adguard; then
    if confirm "¿Importar AdGuard Home (AdGuardHome.yaml del backup, normalizado a 0.0.0.0:3053)?"; then
      if importer_gate_service adguard "AdGuard Home"; then do_ag=1; else summary+="  - AdGuard Home: OMITIDO.\n"; fi
    else
      summary+="  - AdGuard Home: no seleccionado.\n"
    fi
  else
    summary+="  - AdGuard Home: no viene en el backup.\n"
  fi

  if importer_inspect_has ssh; then
    if confirm "¿Fusionar ssh/authorized_keys del backup con las claves actuales de $SERVER_USER?"; then
      do_ssh=1
    else
      summary+="  - Claves SSH: no seleccionado.\n"
    fi
  else
    summary+="  - Claves SSH: no vienen en el backup.\n"
  fi

  if [[ $(( do_jf + do_qb + do_ag + do_ssh )) -eq 0 ]]; then
    [[ -n "$summary" ]] || summary="  (nada importado)\n"
    msg "Importación desde HLI v1 finalizada: no se extrajo el backup porque no hay nada que importar.\n\n${summary}"
    mark_done import-v1
    return 0
  fi

  # 3) Extraer UNA vez. IMPORT_WORK_DIR (global, no 'local work'): la limpia
  # el trap EXIT del bloque de ejecución real de más abajo aunque algo falle
  # entre medio bajo 'set -e' ('trap ... RETURN' no es local a la función
  # que lo arma, así que no sirve acá — mismo motivo ya documentado en
  # modules/dokploy.sh).
  importer_extract "$tar_path" || { msg "No se pudo extraer el backup. Revise el log del módulo (import-v1.log)."; return 1; }

  local rc
  if [[ "$do_jf" -eq 1 ]]; then
    rc=0; importer_apply_service jellyfin importer_jellyfin "$IMPORT_WORK_DIR" "Jellyfin" || rc=$?
    summary+="$(_import_v1_note "Jellyfin" "$rc")\n"
  fi
  if [[ "$do_qb" -eq 1 ]]; then
    rc=0; importer_apply_service qbittorrent importer_qbittorrent "$IMPORT_WORK_DIR" "qBittorrent" || rc=$?
    summary+="$(_import_v1_note "qBittorrent" "$rc")\n"
  fi
  if [[ "$do_ag" -eq 1 ]]; then
    rc=0; importer_apply_service adguard importer_adguard "$IMPORT_WORK_DIR" "AdGuard Home" || rc=$?
    summary+="$(_import_v1_note "AdGuard Home" "$rc")\n"
  fi
  if [[ "$do_ssh" -eq 1 ]]; then
    importer_authorized_keys "$IMPORT_WORK_DIR"
    summary+="  - Claves SSH: fusionadas.\n"
  fi

  local samba_ref
  samba_ref="$(importer_samba_reference "$IMPORT_WORK_DIR")"

  importer_cleanup "$IMPORT_WORK_DIR"
  IMPORT_WORK_DIR=""

  msg "Importación desde HLI v1 finalizada.\n\n${summary}\n${samba_ref}\n\nSamba y la config del propio HLI NO se importan automáticamente (ver comentario del módulo)."

  mark_done import-v1
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap importer_exit_cleanup EXIT
  _import_v1_main
fi
