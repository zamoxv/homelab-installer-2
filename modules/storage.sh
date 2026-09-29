#!/usr/bin/env bash
# HLI-MODULE: storage
# HLI-DESC: Grupo de media, estructura /srv y expansión de LVM
# HLI-ORDER: 20
# HLI-DEFAULT: yes
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

# Ubuntu Server suele dejar el LV de raíz con tamaño fijo y el resto del VG
# sin asignar. Si la raíz está sobre LVM y hay espacio libre, ofrecer
# extender / a todo el disco. Idempotente: sin LVM o sin espacio libre, no
# hace nada.
expand_lvm_root() {
  command -v lvs >/dev/null 2>&1 || return 0

  local root_src lv_path vg free_g
  root_src="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
  [[ -n "$root_src" ]] || return 0

  # Buscar el LV cuyo dispositivo resuelve al mismo que la raíz. Bajo
  # 'pipefail', si NINGÚN LV matchea (lvm2 instalado pero la raíz no está
  # sobre LVM: caso normal, no un error) el 'while read' termina por EOF de
  # 'read' con estado 1, y sin el '|| true' esa asignación mataría el módulo
  # completo por 'set -e' antes de llegar al groupadd/skeleton de más abajo.
  lv_path="$(sudo lvs --noheadings -o lv_path 2>/dev/null | tr -d ' ' | while read -r p; do
    if [[ "$(readlink -f "$p")" == "$(readlink -f "$root_src")" ]]; then
      echo "$p"; break
    fi
  done)" || true
  [[ -n "$lv_path" ]] || return 0   # la raíz no está sobre LVM

  # '|| true' en ambas: mismo motivo que lv_path más arriba (pipefail
  # propaga el código de lvs/vgs aunque tr/cut salgan bien).
  vg="$(sudo lvs --noheadings -o vg_name "$lv_path" 2>/dev/null | tr -d ' ')" || true
  free_g="$(sudo vgs --noheadings --nosuffix --units g -o vg_free "$vg" 2>/dev/null | tr -d ' <' | cut -d. -f1)" || true
  [[ -n "$free_g" && "$free_g" -gt 0 ]] || return 0   # sin espacio libre

  if confirm "Se detectó espacio libre en el LVM.\n\nVG       : $vg\nLibre    : ${free_g} GB\nLV raíz  : $lv_path\n\n¿Extender el sistema de archivos a todo el disco?"; then
    sudo lvextend -l +100%FREE -r "$lv_path"
    msg "Sistema extendido: / ahora usa todo el espacio disponible."
  fi
}

expand_lvm_root

sudo groupadd -f "$MEDIA_GROUP"
sudo usermod -aG "$MEDIA_GROUP" "$SERVER_USER" || true

# Estructura de media en cada raíz montada (MEDIA_ROOT + discos ya sumados al
# pool con datadisk). Idempotente: re-correrlo crea las carpetas que falten.
while read -r mroot; do create_media_skeleton "$mroot"; done < <(media_roots)

sudo mkdir -p "$BACKUP_ROOT" "$APPDATA_ROOT"
sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$BACKUP_ROOT" "$APPDATA_ROOT"
sudo chmod -R 2775 "$BACKUP_ROOT" "$APPDATA_ROOT"

mark_done storage
