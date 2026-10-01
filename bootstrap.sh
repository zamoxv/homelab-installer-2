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
# 'stty echo' PRIMERO: hallazgo de revisión — hli_busy() (lib/core.sh) apaga
# el eco del teclado en /dev/tty mientras un módulo trabaja (despliegues,
# validación canaria...) y lo reactiva con hli_busy_end() a la vuelta. Si el
# usuario corta con Ctrl+C justo en ese momento, la señal llega a TODO el
# grupo de procesos en primer plano (este script Y el módulo hijo corriendo
# bajo 'bash "$path"" en run_module) — el 'hli_busy_end' de run_module (que
# corre en ESTE proceso, después de 'bash "$path"') puede no llegar a
# ejecutarse nunca si la señal también terminó a ESTE proceso antes. Este
# trap EXIT es la única red de seguridad garantizada: bash lo corre al
# salir sea cual sea el motivo (normal, señal, 'set -e'), así que reactivar
# el eco acá, antes de cualquier otra cosa, evita dejar la terminal del
# usuario sin eco de teclado tras una interrupción.
trap 'stty echo </dev/tty 2>/dev/null || true; kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; tput sgr0 2>/dev/null; clear 2>/dev/null' EXIT

if ! command -v dialog >/dev/null 2>&1; then
  echo "Instalando dialog..."
  # lib/core.sh (hli_apt) todavía no está cargado acá: mismo criterio a mano
  # (incluidas las mismas opciones no-interactivas: sin ellas, un prompt de
  # dpkg/needrestart invisible podría colgar esta instalación temprana,
  # antes de que exista siquiera la barra de progreso para notarlo).
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get update </dev/null
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    dialog </dev/null
fi

source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/ui/menu.sh"

ensure_runtime

main_menu
