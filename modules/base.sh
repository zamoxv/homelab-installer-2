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

sudo apt update
sudo apt upgrade -y

sudo apt install -y \
  curl wget git nano vim htop btop rsync unzip dialog \
  ethtool smartmontools lm-sensors ca-certificates gnupg \
  net-tools lsof ncdu jq

sudo mkdir -p "$BACKUP_ROOT" "$APPDATA_ROOT"
sudo chown "$SERVER_USER:$SERVER_USER" "$BACKUP_ROOT" "$APPDATA_ROOT" 2>/dev/null || true

mark_done base
