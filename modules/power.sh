#!/usr/bin/env bash
# HLI-MODULE: power
# HLI-DESC: Gestión de energía (no suspender, ignorar tapa)
# HLI-ORDER: 25
# HLI-DEFAULT: yes
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

# 1. Desactivar suspensión e hibernación por completo (idempotente).
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# 2. Ignorar el cierre de tapa mediante un drop-in, sin tocar el logind.conf
#    principal del sistema (re-ejecutable sin acumular cambios).
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/hli2.conf > /dev/null <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
EOF

sudo systemctl restart systemd-logind

# 3. Si hay swap, la suspensión/hibernación ya quedó deshabilitada arriba;
#    preguntar si de todos modos se quiere conservar la hibernación (no
#    recomendado en un servidor 24/7).
if [[ -n "$(swapon --show=NAME --noheadings 2>/dev/null)" ]]; then
  swap_size="$(free -h | awk '/Swap:/ {print $2}')" || true
  if confirm "Swap detectada ($swap_size).\n\n¿Desea MANTENER la hibernación?\n(No recomendado para un servidor 24/7)"; then
    sudo systemctl unmask hibernate.target hybrid-sleep.target
  fi
fi

mark_done power
