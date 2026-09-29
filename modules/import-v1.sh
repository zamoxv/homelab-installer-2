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

_import_v1_main() {
  local tar_path

  tar_path=$(input_box "Importar desde HLI v1" "Ruta al backup-<fecha>.tar.gz del HLI v1:") || return 0
  [[ -n "$tar_path" ]] || { msg "Ruta vacía: se cancela."; return 0; }

  # IMPORT_WORK_DIR (global, no 'local work'): la limpia el trap EXIT del
  # bloque de ejecución real de más abajo aunque algo falle entre medio bajo
  # 'set -e' ('trap ... RETURN' no es local a la función que lo arma, así
  # que no sirve acá — mismo motivo ya documentado en modules/dokploy.sh).
  IMPORT_WORK_DIR="$(importer_extract "$tar_path")" || { msg "No se pudo extraer el backup. Revise la ruta y que sea un tar.gz válido del HLI v1."; return 1; }

  local summary=""

  if [[ -d "$IMPORT_WORK_DIR/jellyfin" ]]; then
    if importer_container_safe jellyfin; then
      if confirm "¿Importar Jellyfin (jellyfin/lib + jellyfin/etc del backup)?"; then
        importer_jellyfin "$IMPORT_WORK_DIR"
        summary+="  - Jellyfin: importado.\n"
      fi
    else
      summary+="  - Jellyfin: OMITIDO (el contenedor 'jellyfin' está activo o su estado no se pudo determinar).\n"
    fi
  fi

  if [[ -d "$IMPORT_WORK_DIR/qbittorrent" ]]; then
    if importer_container_safe qbittorrent; then
      if confirm "¿Importar qBittorrent (qbittorrent/config + qbittorrent/share del backup)?"; then
        importer_qbittorrent "$IMPORT_WORK_DIR"
        summary+="  - qBittorrent: importado.\n"
      fi
    else
      summary+="  - qBittorrent: OMITIDO (el contenedor 'qbittorrent' está activo o su estado no se pudo determinar).\n"
    fi
  fi

  if [[ -f "$IMPORT_WORK_DIR/adguard/AdGuardHome.yaml" ]]; then
    if importer_container_safe adguard; then
      if confirm "¿Importar AdGuard Home (AdGuardHome.yaml del backup, normalizado a 0.0.0.0:3053)?"; then
        importer_adguard "$IMPORT_WORK_DIR"
        summary+="  - AdGuard Home: importado.\n"
      fi
    else
      summary+="  - AdGuard Home: OMITIDO (el contenedor 'adguard' está activo o su estado no se pudo determinar).\n"
    fi
  fi

  if [[ -f "$IMPORT_WORK_DIR/ssh/authorized_keys" ]]; then
    if confirm "¿Fusionar ssh/authorized_keys del backup con las claves actuales de $SERVER_USER?"; then
      importer_authorized_keys "$IMPORT_WORK_DIR"
      summary+="  - Claves SSH: fusionadas.\n"
    fi
  fi

  local samba_ref
  samba_ref="$(importer_samba_reference "$IMPORT_WORK_DIR")"

  importer_cleanup "$IMPORT_WORK_DIR"
  IMPORT_WORK_DIR=""

  [[ -n "$summary" ]] || summary="  (nada importado)\n"
  msg "Importación desde HLI v1 finalizada.\n\n${summary}\n${samba_ref}\n\nSamba y la config del propio HLI NO se importan automáticamente (ver comentario del módulo)."

  mark_done import-v1
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap '[[ -n "${IMPORT_WORK_DIR:-}" ]] && importer_cleanup "$IMPORT_WORK_DIR"' EXIT
  _import_v1_main
fi
