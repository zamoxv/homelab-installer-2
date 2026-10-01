#!/usr/bin/env bash
# HLI-MODULE: homeassistant
# HLI-DESC: Home Assistant (contenedor, modo Container, red del host, vía API de Dokploy)
# HLI-ORDER: 64
# HLI-DEFAULT: yes
# HLI-TUI: yes
# HLI-REQUIERE: dokploy-api
#
# Modo "Container" (sin add-ons/supervisor), network_mode: host (decisiones
# #5 y #7 del roadmap): el uso previsto son integraciones Xiaomi y Samsung
# por LAN (mDNS/SSDP), que no necesitan add-ons ni acceso a Bluetooth/USB del
# host — por eso este módulo NO pide "privileged" ni monta dispositivos, a
# diferencia del docker-compose de ejemplo oficial (ver
# compose/homeassistant/docker-compose.yml para el detalle citado).
# No hay importación desde el HLI v1: ese proyecto no incluía Home Assistant.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

_homeassistant_prepare_dirs() {
  # root:root: la imagen oficial ghcr.io/home-assistant/home-assistant no
  # soporta mapeo de usuario por variables de entorno (a diferencia de
  # linuxserver/qbittorrent) y gestiona sus propios permisos corriendo como
  # root — mismo criterio que modules/adguard.sh.
  sudo mkdir -p "$APPDATA_ROOT/homeassistant/config"
  sudo chown -R root:root "$APPDATA_ROOT/homeassistant"
}

_homeassistant_main() {
  _homeassistant_prepare_dirs

  dokploy_preflight || return 1

  local project_json environment_id compose_file composeId url
  project_json="$(dokploy_project_find_or_create)" || { msg "No se pudo crear/encontrar el proyecto 'homelab' en Dokploy."; return 1; }
  environment_id="$(dokploy_environment_default_id "$project_json")" || { msg "No se pudo resolver el ambiente por defecto del proyecto 'homelab' en Dokploy."; return 1; }

  compose_file="$(mktemp)"
  if ! compose_render_homeassistant > "$compose_file"; then
    msg "No se pudo renderizar el compose de Home Assistant."
    rm -f "$compose_file"
    return 1
  fi

  if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "homeassistant" "$compose_file")"; then
    msg "Falló el despliegue de Home Assistant vía la API de Dokploy. Revise las credenciales y el panel."
    rm -f "$compose_file"
    return 1
  fi
  rm -f "$compose_file"

  local status_note
  if service_wait_active homeassistant 120; then
    status_note="Home Assistant está corriendo."
  else
    status_note="Home Assistant no terminó de arrancar dentro de los 120 segundos de espera (el primer arranque puede tardar varios minutos). Puede seguir iniciando: revise el panel de Dokploy."
  fi

  url="$(service_url homeassistant)" || true
  msg "Home Assistant desplegado (composeId=$composeId).\n\n$status_note\n\nURL: ${url:-N/D} (solo LAN: network_mode host, sin Traefik).\n\nSi es la primera vez, complete el asistente de configuración inicial desde esa URL."

  mark_done homeassistant
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _homeassistant_main
fi
