#!/usr/bin/env bash
# HLI-MODULE: base
# HLI-DESC: Paquetes base y utilidades del sistema
# HLI-ORDER: 10
# HLI-DEFAULT: yes
# HLI-TUI: no
#
# Solo utilidades del host. Docker/Dokploy NO se instalan acá: eso es la fase
# v2.1 (módulo "dokploy").
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

hli_apt update
hli_apt upgrade --with-new-pkgs

hli_apt install \
  curl wget git nano vim htop btop rsync unzip dialog \
  ethtool smartmontools lm-sensors ca-certificates gnupg \
  net-tools lsof ncdu jq

sudo mkdir -p "$APPDATA_ROOT"
sudo chown "$SERVER_USER:$SERVER_USER" "$APPDATA_ROOT" 2>/dev/null || true

mark_done base
