#!/usr/bin/env bash
# HLI-MODULE: jellyfin
# HLI-DESC: Jellyfin (contenedor, vía API de Dokploy)
# HLI-ORDER: 60
# HLI-DEFAULT: yes
# HLI-TUI: yes
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

  if ! importer_container_safe jellyfin; then
    msg "El contenedor 'jellyfin' parece estar activo o su estado no se pudo determinar. Por seguridad, la importación solo corre con el contenedor detenido o ausente.\n\nDeténgalo (o cancele el despliegue actual) y reintente."
    return 1
  fi

  local tar_path
  tar_path=$(input_box "Importar Jellyfin" "Ruta al backup-<fecha>.tar.gz del HLI v1:") || return 0
  [[ -n "$tar_path" ]] || return 0

  if importer_dest_has_content "$APPDATA_ROOT/jellyfin/config"; then
    confirm "Ya hay datos en $APPDATA_ROOT/jellyfin/config.\n\n¿Importar de todos modos? Los archivos del backup se fusionan/sobrescriben encima (rsync)." \
      || return 0
  fi

  # IMPORT_WORK_DIR (global): la limpia el trap EXIT de más abajo aunque
  # algo falle entre medio bajo 'set -e' ('trap ... RETURN' no sirve, no es
  # local a esta función — mismo motivo documentado en modules/dokploy.sh).
  IMPORT_WORK_DIR="$(importer_extract "$tar_path")" || { msg "No se pudo extraer el backup. Revise la ruta y que sea un tar.gz válido del HLI v1."; return 1; }
  importer_jellyfin "$IMPORT_WORK_DIR"
  importer_cleanup "$IMPORT_WORK_DIR"
  IMPORT_WORK_DIR=""
  msg "Configuración de Jellyfin importada desde el backup."
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

  if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "jellyfin" "$compose_file")"; then
    msg "Falló el despliegue de Jellyfin vía la API de Dokploy. Revise las credenciales y el panel."
    rm -f "$compose_file"
    return 1
  fi
  rm -f "$compose_file"

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
  trap '[[ -n "${IMPORT_WORK_DIR:-}" ]] && importer_cleanup "$IMPORT_WORK_DIR"' EXIT
  _jellyfin_main
fi
