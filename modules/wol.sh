#!/usr/bin/env bash
# HLI-MODULE: wol
# HLI-DESC: Wake-on-LAN
# HLI-ORDER: 30
# HLI-DEFAULT: yes
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

IFACE="$(detect_iface || true)"

if [[ -z "$IFACE" ]]; then
  # ESC en el diálogo devuelve 255: tratarlo como cancelación deliberada del
  # módulo, no dejar que 'set -e' lo mate a mitad de camino.
  IFACE=$(input_box "Wake-on-LAN" "No se pudo detectar la interfaz. Ingrese el nombre de la interfaz de red:" "enp0s25") || exit 1
fi

if [[ -z "$IFACE" ]]; then
  msg "No se ingresó ninguna interfaz de red. Se cancela el módulo Wake-on-LAN."
  exit 1
fi

hli_apt install ethtool

sudo tee /etc/systemd/system/hli2-wol.service > /dev/null <<EOF
[Unit]
Description=HLI 2 - Habilitar Wake on LAN
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ethtool -s $IFACE wol g

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable hli2-wol.service
sudo systemctl start hli2-wol.service || true

mark_done wol
