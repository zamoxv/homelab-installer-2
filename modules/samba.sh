#!/usr/bin/env bash
# HLI-MODULE: samba
# HLI-DESC: Samba nativo + un recurso por disco de media
# HLI-ORDER: 40
# HLI-DEFAULT: yes
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

# Emite un bloque de recurso Samba. Uso interno de _samba_write_shares.
_samba_share_block() {
  cat <<EOF

[$1]
   path = $2
   browseable = yes
   read only = no
   guest ok = no
   valid users = $SERVER_USER
   force group = $MEDIA_GROUP
   create mask = 0664
   directory mask = 2775
EOF
}

# (Re)escribe el bloque de recursos de HLI 2 en smb.conf: un recurso por
# disco de media (media_roots) + backups. Idempotente: reemplaza el bloque
# entre marcadores en vez de acumular entradas.
#
# Devuelve 1 (y avisa con msg, sin dejar el sistema peor de lo que estaba) si:
#  - no se puede respaldar smb.conf antes de tocarlo,
#  - el archivo tiene un marcador START/END incompleto (huérfano: borrar
#    "hasta el que sigue" en ese caso se comería el resto del archivo),
#  - la config generada no pasa 'testparm -s' (sintácticamente inválida),
#  - smbd no puede reiniciar con la config nueva (se restaura el respaldo).
_samba_write_shares() {
  local conf="/etc/samba/smb.conf" backup tmp_new has_start has_end
  [[ -f "$conf" ]] || return 0

  backup="/etc/samba/smb.conf.backup.$(date +%F-%H%M%S)"
  if ! sudo cp "$conf" "$backup"; then
    msg "No se pudo respaldar $conf antes de modificarlo.\n\nSe aborta sin tocar la configuración de Samba."
    return 1
  fi

  has_start=0
  grep -q '^### HLI2-SAMBA START' "$conf" 2>/dev/null && has_start=1
  has_end=0
  grep -q '^### HLI2-SAMBA END' "$conf" 2>/dev/null && has_end=1
  if [[ "$has_start" -ne "$has_end" ]]; then
    msg "smb.conf tiene un marcador de HLI 2 sin su par (START sin END, o END sin START).\n\nSe aborta sin modificar el archivo para no borrar de más. Revise $conf manualmente.\n\nRespaldo tomado igual en: $backup"
    return 1
  fi

  tmp_new="$(mktemp)"
  {
    sudo sed '/### HLI2-SAMBA START/,/### HLI2-SAMBA END/d' "$conf"
    echo ""
    echo "### HLI2-SAMBA START"
    while read -r root; do
      [[ -n "$root" ]] || continue
      _samba_share_block "$(basename "$root")" "$root"
    done < <(media_roots)
    _samba_share_block backups "$BACKUP_ROOT"
    echo "### HLI2-SAMBA END"
  } > "$tmp_new"

  if ! sudo testparm -s "$tmp_new" >/dev/null 2>&1; then
    msg "La configuración de Samba generada no es válida (testparm la rechazó).\n\nNo se aplicó ningún cambio: smb.conf sigue como estaba.\nRespaldo en: $backup"
    rm -f "$tmp_new"
    return 1
  fi

  sudo cp "$tmp_new" "$conf"
  rm -f "$tmp_new"

  if ! sudo systemctl restart smbd; then
    sudo cp "$backup" "$conf"
    sudo systemctl restart smbd 2>/dev/null || true
    msg "Samba no pudo reiniciar con la configuración nueva.\n\nSe restauró el smb.conf anterior desde:\n$backup"
    return 1
  fi
}

hli_apt install samba

sudo smbpasswd -a "$SERVER_USER" || true
sudo systemctl enable smbd

_samba_write_shares

msg "Samba configurado: un recurso por disco de media (media, media2, ...) + backups.\n\nUsuario: $SERVER_USER"

mark_done samba
