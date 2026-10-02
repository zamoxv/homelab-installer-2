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

  local tar_path
  tar_path=$(input_box "Importar qBittorrent" "Ruta al backup-<fecha>.tar.gz del HLI v1:") || return 0
  [[ -n "$tar_path" ]] || return 0

  # Estado del contenedor ANTES de extraer nada (la extracción es lo lento):
  # si está corriendo, ofrece detenerlo; si no se pudo consultar, se omite.
  # Este módulo despliega justo después, así que no hace falta volver a
  # desplegar acá ('noredeploy').
  importer_gate_service qbittorrent "qBittorrent" || return 0

  if importer_dest_has_content "$APPDATA_ROOT/qbittorrent/config"; then
    confirm "Ya hay datos en $APPDATA_ROOT/qbittorrent/config.\n\n¿Importar de todos modos? Los archivos del backup se fusionan/sobrescriben encima (rsync)." \
      || return 0
  fi

  # Solo se EXTRAE acá (IMPORT_WORK_DIR es global: importer_exit_cleanup lo
  # borra aunque se interrumpa). Detener + copiar se difiere hasta justo
  # antes del despliegue (importer_apply_pending), para minimizar el tiempo
  # que el servicio queda caído.
  importer_extract "$tar_path" || { msg "No se pudo extraer el backup. Revise la ruta, que sea un tar.gz válido del HLI v1 y el log del módulo."; return 1; }
  importer_pending_set qbittorrent importer_qbittorrent "qBittorrent"
  return 0
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

  # Detener + copiar la importación (si la hay) recién ahora, con todo lo
  # lento (canary, API, render) ya resuelto: el servicio queda caído solo
  # el instante entre esto y el despliegue.
  local imported_note=""
  [[ -n "$IMPORT_PENDING" ]] && imported_note="\n\nConfiguración importada desde el backup del HLI v1: verifique en el WebUI la ruta de descargas por defecto; si el backup venía de otro disco o punto de montaje, puede necesitar ajustarla a mano."
  if ! importer_apply_pending; then
    rm -f "$compose_file"
    return 1
  fi

  if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "qbittorrent" "$compose_file")"; then
    msg "Falló el despliegue de qBittorrent vía la API de Dokploy. Revise las credenciales y el panel."
    rm -f "$compose_file"
    return 1
  fi
  rm -f "$compose_file"
  importer_stopped_clear "$(service_get qbittorrent CONTAINER)"

  local status_note
  if service_wait_active qbittorrent 120; then
    status_note="qBittorrent está corriendo."
  else
    status_note="qBittorrent no terminó de arrancar dentro de los 120 segundos de espera. Puede seguir iniciando: revise el panel de Dokploy."
  fi

  url="$(service_url qbittorrent)" || true
  msg "qBittorrent desplegado (composeId=$composeId).\n\n$status_note\n\nURL: ${url:-N/D}\n\nContraseña temporal del WebUI: revise los logs del contenedor la primera vez (linuxserver la genera e imprime al inicio si no hay una guardada).${imported_note}"

  mark_done qbittorrent
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap importer_exit_cleanup EXIT
  _qbittorrent_main
fi
