#!/usr/bin/env bash
# HLI-MODULE: dokploy-api
# HLI-DESC: Configurar o cambiar el token de la API de Dokploy
# HLI-ORDER: 52
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
#
# Pide de nuevo la dirección y el token de la API de Dokploy (por ejemplo,
# si el token se revocó o se regeneró en el panel) y verifica que funcionen
# antes de dejarlos guardados. Si la verificación falla, restaura las
# credenciales anteriores.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

backup=""
if priv_file_exists "$DOKPLOY_ENV_FILE" 2>/dev/null; then
  backup="${DOKPLOY_ENV_FILE}.anterior"
  sudo install -m 0600 -o root -g root /dev/null "$backup"
  sudo cp "$DOKPLOY_ENV_FILE" "$backup"
fi

_restore_previous() {
  if [[ -n "$backup" ]]; then
    sudo cp "$backup" "$DOKPLOY_ENV_FILE"
    sudo rm -f "$backup"
  else
    sudo rm -f "$DOKPLOY_ENV_FILE"
  fi
}

if ! dokploy_api_setup; then
  _restore_previous
  msg "No se cambió la configuración de la API de Dokploy."
  exit 0
fi

hli_busy "Verificando la conexión con Dokploy..."
if ! dokploy_api_get "project.all" >/dev/null; then
  _restore_previous
  msg "Dokploy no aceptó la dirección o el token ingresados.\n\nSe mantuvo la configuración anterior.\n\nRevise la dirección del panel y copie el token de nuevo desde Configuración -> Perfil -> API/CLI."
  exit 1
fi

[[ -n "$backup" ]] && sudo rm -f "$backup"
log "API de Dokploy reconfigurada y verificada."
msg "Conexión con Dokploy verificada. El nuevo token quedó guardado."
