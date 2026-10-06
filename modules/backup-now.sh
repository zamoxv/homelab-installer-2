#!/usr/bin/env bash
# HLI-MODULE: backup-now
# HLI-DESC: Hacer backup ahora (local + Cloudflare R2)
# HLI-ORDER: 71
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
#
# Corre el mismo backup que el timer (bin/hli2-backup run, como root) en primer
# plano, con la salida de restic visible, y muestra el resultado.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

_backup_now_main() {
  if ! priv_file_exists "$BACKUP_PASSWORD_FILE"; then
    msg "Los backups no están configurados todavía.\n\nCorra primero el módulo 'backup-setup'."
    return 1
  fi

  confirm "Se hará un backup completo ahora.\n\nLos servicios con base de datos (Vaultwarden, Jellyfin, Home Assistant, AdGuard) se detienen unos segundos durante la copia local y se vuelven a iniciar solos; AdGuard es el DNS de la casa.\n\n¿Continuar?" || return 0

  hli_busy_end
  clear 2>/dev/null || true
  echo "== Backup de HLI 2 (puede tardar; el avance se muestra abajo) =="
  local rc=0
  sudo -n "$SCRIPT_DIR/bin/hli2-backup" run || rc=$?
  echo
  if [[ -t 0 ]]; then
    read -r -p "Presione Enter para ver el resultado... " _ || true
  fi

  local summary
  summary="$(backup_status_summary)"
  if [[ "$rc" -eq 0 ]]; then
    msg "Backup terminado.\n\n$summary"
  else
    msg "El backup terminó con errores (código $rc).\n\n$summary\n\nLog: $LOG_DIR/backup.log (sudo less)"
    return 1
  fi
  mark_done backup-now
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _backup_now_main
fi
