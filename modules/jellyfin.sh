#!/usr/bin/env bash
# HLI-MODULE: jellyfin
# HLI-DESC: Jellyfin (contenedor, vía API de Dokploy)
# HLI-ORDER: 60
# HLI-DEFAULT: yes
# HLI-TUI: yes
# HLI-REQUIERE: dokploy-api
#
# Prepara APPDATA/jellyfin, ofrece importar config del HLI v1, renderiza el
# compose (lib/compose.sh) y lo despliega vía la API de Dokploy
# (lib/dokploy_api.sh), corriendo antes la validación canaria obligatoria
# (lib/canary.sh) si todavía no se hizo.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

_jellyfin_prepare_dirs() {
  sudo mkdir -p "$APPDATA_ROOT/jellyfin/config" "$APPDATA_ROOT/jellyfin/cache"
  sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$APPDATA_ROOT/jellyfin"
}

_jellyfin_offer_import() {
  confirm "¿Importar la configuración de Jellyfin desde un backup del HLI v1 (backup-<fecha>.tar.gz)?" || return 0

  local tar_path
  tar_path=$(input_box "Importar Jellyfin" "Ruta al backup-<fecha>.tar.gz del HLI v1:") || return 0
  [[ -n "$tar_path" ]] || return 0

  # Estado del contenedor ANTES de extraer nada (la extracción es lo lento):
  # si está corriendo, ofrece detenerlo; si no se pudo consultar, se omite.
  # Este módulo despliega justo después, así que no hace falta volver a
  # desplegar acá ('noredeploy').
  importer_gate_service jellyfin "Jellyfin" || return 0

  if importer_dest_has_content "$APPDATA_ROOT/jellyfin/config"; then
    confirm "Ya hay datos en $APPDATA_ROOT/jellyfin/config.\n\n¿Importar de todos modos? Los archivos del backup se fusionan/sobrescriben encima (rsync)." \
      || return 0
  fi

  # Solo se EXTRAE acá (IMPORT_WORK_DIR es global: importer_exit_cleanup lo
  # borra aunque se interrumpa). Detener + copiar se difiere hasta justo
  # antes del despliegue (importer_apply_pending), para minimizar el tiempo
  # que el servicio queda caído.
  importer_extract "$tar_path" || { msg "No se pudo extraer el backup. Revise la ruta, que sea un tar.gz válido del HLI v1 y el log del módulo."; return 1; }
  importer_pending_set jellyfin importer_jellyfin "Jellyfin"
  return 0
}

_jellyfin_main() {
  _jellyfin_prepare_dirs
  _jellyfin_offer_import || true

  dokploy_preflight || return 1

  local project_json environment_id compose_file composeId port url
  project_json="$(dokploy_project_find_or_create)" || { msg "No se pudo crear/encontrar el proyecto 'homelab' en Dokploy."; return 1; }
  environment_id="$(dokploy_environment_default_id "$project_json")" || { msg "No se pudo resolver el ambiente por defecto del proyecto 'homelab' en Dokploy."; return 1; }

  compose_file="$(mktemp)"
  if ! compose_render_jellyfin > "$compose_file"; then
    msg "No se pudo renderizar el compose de Jellyfin (revise usuario/grupo de media)."
    rm -f "$compose_file"
    return 1
  fi

  # Detener + copiar la importación (si la hay) recién ahora, con todo lo
  # lento (canary, API, render) ya resuelto: el servicio queda caído solo
  # el instante entre esto y el despliegue.
  if ! importer_apply_pending; then
    rm -f "$compose_file"
    return 1
  fi

  if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "jellyfin" "$compose_file")"; then
    msg "Falló el despliegue de Jellyfin vía la API de Dokploy. Revise las credenciales y el panel."
    rm -f "$compose_file"
    return 1
  fi
  rm -f "$compose_file"
  importer_stopped_clear "$(service_get jellyfin CONTAINER)"

  local status_note
  if service_wait_active jellyfin 120; then
    status_note="Jellyfin está corriendo."
  else
    status_note="Jellyfin no terminó de arrancar dentro de los 120 segundos de espera. Puede seguir iniciando: revise el panel de Dokploy."
  fi

  url="$(service_url jellyfin)" || true
  msg "Jellyfin desplegado (composeId=$composeId).\n\n$status_note\n\nURL: ${url:-N/D}"

  mark_done jellyfin
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap importer_exit_cleanup EXIT
  _jellyfin_main
fi
