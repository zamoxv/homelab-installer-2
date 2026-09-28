#!/usr/bin/env bash
# Punto de entrada de HLI 2. Ejecutar como: bash bootstrap.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export DEBIAN_FRONTEND=noninteractive

# Pedir sudo una vez y mantenerlo vigente durante toda la sesión, para que un
# módulo corriendo en segundo plano (bajo la barra de progreso) no se cuelgue
# esperando la contraseña.
sudo -v
( while true; do sudo -n true 2>/dev/null || exit; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; tput sgr0 2>/dev/null; clear 2>/dev/null' EXIT

if ! command -v dialog >/dev/null 2>&1; then
  echo "Instalando dialog..."
  sudo apt update
  sudo apt install -y dialog
fi

source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/ui/menu.sh"

ensure_runtime

main_menu
