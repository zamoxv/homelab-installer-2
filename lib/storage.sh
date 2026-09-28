#!/usr/bin/env bash
# Discos, LVM y raíces de media. Usado por los módulos storage/datadisk/samba
# y por lib/hw.sh (root_disk) para no duplicar la detección de discos.
set -euo pipefail

# Discos físicos (ruta completa, ej. /dev/nvme0n1, una por línea, sin
# 'exit' temprano) que hay DEBAJO del origen de montaje/swap $1. 'lsblk -s'
# recorre las dependencias en sentido inverso (desde el LV/partición/cripto
# HACIA ABAJO hasta el/los disco/s real/es); subir por PKNAME no alcanza
# cuando el origen está sobre LVM (PKNAME de un LV queda vacío). No cortar
# en la primera coincidencia importa: un VG con varios PV (LVM sobre varios
# discos) puede tener más de un disco físico debajo de un mismo LV, y hay
# que devolverlos todos para poder excluirlos todos. '-r' evita caracteres
# de árbol en el nombre; '-p' da la ruta completa. Best-effort: si lsblk
# falla no aborta al llamador (se consume dentro de un 'while read' vía
# process substitution, cuyo código de salida no se propaga).
_disks_under() {
  local src="$1"
  [[ -n "$src" ]] || return 0
  lsblk -srnpo NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}'
}

# Disco físico "principal" de la raíz, solo para mostrar en el dashboard
# (informativo, best-effort). NO USAR para decidir qué discos excluir de
# datadisk: para eso está system_disks(), que devuelve el conjunto completo
# y falla cerrado.
root_disk() {
  local src
  src="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
  _disks_under "$src" | head -n1
}

# Conjunto (una ruta completa por línea, ej. /dev/nvme0n1, sin duplicados) de
# TODOS los discos físicos a EXCLUIR siempre de cualquier flujo que formatee
# o reutilice un disco (datadisk): los que sostienen la raíz, /boot,
# /boot/efi y cualquier swap activa. Ante LVM con varios PV, _disks_under
# camina el árbol completo y trae todos los discos del VG (no solo el
# primero), así que también cubre ese caso.
#
# FALLA CERRADO a propósito: si no se puede determinar ni un disco, o algún
# resultado no resulta ser un block device real, esta función NO imprime
# nada y devuelve 1. El llamador (datadisk) DEBE tratar "conjunto vacío"
# como "no se puede garantizar qué es seguro tocar" y abortar sin listar
# ningún candidato — nunca asumir "ninguno detectado = está todo permitido".
system_disks() {
  local mnt src d
  local -A seen=()
  local result=()

  for mnt in / /boot /boot/efi; do
    # /boot y /boot/efi son opcionales (p. ej. equipos BIOS sin ESP): si el
    # punto de montaje no existe, findmnt falla y se omite.
    src="$(findmnt -no SOURCE "$mnt" 2>/dev/null | sed 's/\[.*//')" || true
    [[ -n "$src" ]] || continue
    while read -r d; do
      [[ -n "$d" ]] || continue
      [[ -n "${seen[$d]:-}" ]] && continue
      seen[$d]=1
      result+=("$d")
    done < <(_disks_under "$src")
  done

  while read -r src; do
    [[ -n "$src" ]] || continue
    # Swap en archivo (p. ej. /swap.img): se resuelve el dispositivo del
    # filesystem que lo contiene.
    if [[ -f "$src" ]]; then
      src="$(findmnt -no SOURCE -T "$src" 2>/dev/null | sed 's/\[.*//')" || true
      [[ -n "$src" ]] || continue
    fi
    while read -r d; do
      [[ -n "$d" ]] || continue
      [[ -n "${seen[$d]:-}" ]] && continue
      seen[$d]=1
      result+=("$d")
    done < <(_disks_under "$src")
  done < <(swapon --show=NAME --noheadings 2>/dev/null)

  # Ni un disco determinado: no se puede garantizar nada, fallar cerrado.
  if [[ ${#result[@]} -eq 0 ]]; then
    return 1
  fi

  # Cada resultado debe ser un block device real; si alguno no lo es, algo
  # salió mal en la detección y tampoco se puede confiar en el conjunto.
  for d in "${result[@]}"; do
    if [[ ! -b "$d" ]]; then
      return 1
    fi
  done

  printf '%s\n' "${result[@]}"
}

# Lista los puntos de montaje del pool de media: MEDIA_ROOT y los /srv/mediaN
# adicionales que estén montados (discos sumados con el módulo datadisk). Una
# raíz por línea.
media_roots() {
  local d
  echo "$MEDIA_ROOT"   # raíz base, exista o no todavía (storage la crea)
  for d in "${MEDIA_ROOT}"[0-9]*; do
    if [[ -d "$d" ]] && mountpoint -q "$d" 2>/dev/null; then echo "$d"; fi
  done
}

# Crea la estructura estándar de carpetas de media en la raíz $1, con dueño y
# permisos del grupo de media. Idempotente. La usan storage (MEDIA_ROOT) y
# datadisk (cada disco nuevo).
create_media_skeleton() {
  local root="$1" f
  sudo mkdir -p "$root"
  for f in "${MEDIA_FOLDERS[@]}"; do sudo mkdir -p "$root/$f"; done
  sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$root"
  # setgid en directorios (el grupo se hereda) y 0664 en archivos: no marca
  # como ejecutables archivos de media si el disco ya traía contenido.
  sudo find "$root" -type d -exec chmod 2775 {} + 2>/dev/null || true
  sudo find "$root" -type f -exec chmod 0664 {} + 2>/dev/null || true
}
