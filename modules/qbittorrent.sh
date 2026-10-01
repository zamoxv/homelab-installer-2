#!/usr/bin/env bash
# HLI-MODULE: qbittorrent
# HLI-DESC: qBittorrent (contenedor, vía API de Dokploy)
# HLI-ORDER: 61
# HLI-DEFAULT: yes
# HLI-TUI: yes
# HLI-REQUIERE: dokploy-api
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

_qbittorrent_prepare_dirs() {
  sudo mkdir -p "$APPDATA_ROOT/qbittorrent/config"
  sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$APPDATA_ROOT/qbittorrent"
}

_qbittorrent_offer_import() {
  confirm "¿Importar la configuración de qBittorrent desde un backup del HLI v1 (backup-<fecha>.tar.gz)?" || return 0

  if ! importer_container_safe qbittorrent; then
    msg "El contenedor 'qbittorrent' parece estar activo o su estado no se pudo determinar. Por seguridad, la importación solo corre con el contenedor detenido o ausente."
    return 1
  fi

  local tar_path
  tar_path=$(input_box "Importar qBittorrent" "Ruta al backup-<fecha>.tar.gz del HLI v1:") || return 0
  [[ -n "$tar_path" ]] || return 0

  if importer_dest_has_content "$APPDATA_ROOT/qbittorrent/config"; then
    confirm "Ya hay datos en $APPDATA_ROOT/qbittorrent/config.\n\n¿Importar de todos modos? Los archivos del backup se fusionan/sobrescriben encima (rsync)." \
      || return 0
  fi

  # IMPORT_WORK_DIR (global): la limpia el trap EXIT de más abajo (ver el
  # mismo comentario en modules/jellyfin.sh sobre por qué no un trap RETURN).
  IMPORT_WORK_DIR="$(importer_extract "$tar_path")" || { msg "No se pudo extraer el backup. Revise la ruta y que sea un tar.gz válido del HLI v1."; return 1; }
  importer_qbittorrent "$IMPORT_WORK_DIR"
  importer_cleanup "$IMPORT_WORK_DIR"
  IMPORT_WORK_DIR=""
  msg "Configuración de qBittorrent importada desde el backup.\n\nVerifique la ruta de descargas por defecto en el WebUI: si el backup venía de otro disco/punto de montaje, puede necesitar ajustarla a mano."
}

_qbittorrent_main() {
  _qbittorrent_prepare_dirs
  _qbittorrent_offer_import || true

  dokploy_preflight || return 1

  local project_json environment_id compose_file composeId url
  project_json="$(dokploy_project_find_or_create)" || { msg "No se pudo crear/encontrar el proyecto 'homelab' en Dokploy."; return 1; }
  environment_id="$(dokploy_environment_default_id "$project_json")" || { msg "No se pudo resolver el ambiente por defecto del proyecto 'homelab' en Dokploy."; return 1; }

  compose_file="$(mktemp)"
  if ! compose_render_qbittorrent > "$compose_file"; then
    msg "No se pudo renderizar el compose de qBittorrent (revise usuario/grupo de media)."
    rm -f "$compose_file"
    return 1
  fi

  if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "qbittorrent" "$compose_file")"; then
    msg "Falló el despliegue de qBittorrent vía la API de Dokploy. Revise las credenciales y el panel."
    rm -f "$compose_file"
    return 1
  fi
  rm -f "$compose_file"

  local status_note
  if service_wait_active qbittorrent 120; then
    status_note="qBittorrent está corriendo."
  else
    status_note="qBittorrent no terminó de arrancar dentro de los 120 segundos de espera. Puede seguir iniciando: revise el panel de Dokploy."
  fi

  url="$(service_url qbittorrent)" || true
  msg "qBittorrent desplegado (composeId=$composeId).\n\n$status_note\n\nURL: ${url:-N/D}\n\nContraseña temporal del WebUI: revise los logs del contenedor la primera vez (linuxserver la genera e imprime al inicio si no hay una guardada)."

  mark_done qbittorrent
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap '[[ -n "${IMPORT_WORK_DIR:-}" ]] && importer_cleanup "$IMPORT_WORK_DIR"' EXIT
  _qbittorrent_main
fi
