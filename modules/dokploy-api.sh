#!/usr/bin/env bash
# HLI-MODULE: dokploy-api
# HLI-DESC: Configurar o cambiar el token de la API de Dokploy
# HLI-ORDER: 52
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
#
# Punto de entrada desde Herramientas para (re)configurar la API de
# Dokploy (por ejemplo, si el token se revocó o se regeneró en el panel).
# Toda la lógica real (instrucciones, backup de la config anterior, pedir
# IP/puerto/token, verificar con 'project.all', reintentar o restaurar ante
# un fallo) vive en dokploy_api_configure_verified (lib/dokploy_api.sh): es
# la MISMA función que usa modules/dokploy.sh al terminar la instalación (o
# cuando Dokploy ya está instalado pero la API no está configurada) — una
# sola implementación, nunca duplicada entre los dos módulos.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

dokploy_api_configure_verified
