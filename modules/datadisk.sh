#!/usr/bin/env bash
# HLI-MODULE: datadisk
# HLI-DESC: Sumar un disco de datos al pool de media (/srv/mediaN)
# HLI-ORDER: 22
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

# Conjunto de discos del sistema a excluir SIEMPRE (raíz, /boot, /boot/efi,
# swap). system_disks() falla cerrado: si no puede garantizar el conjunto
# completo, no imprime nada. Ante esa duda, este módulo NO debe listar ni un
# solo candidato (mejor no ofrecer nada que arriesgar formatear el disco del
# sistema).
mapfile -t SYS_DISKS < <(system_disks)
if [[ ${#SYS_DISKS[@]} -eq 0 ]]; then
  msg "No se pudo determinar con certeza el/los disco/s del sistema (raíz, /boot, /boot/efi o swap).\n\nPor seguridad, HLI 2 no muestra ningún candidato en este caso. Revise manualmente con 'lsblk' y 'findmnt -no SOURCE /' antes de continuar."
  exit 1
fi

# Claves = rutas completas (/dev/sda, no "sda"): con '-p', la columna PKNAME
# de lsblk también trae la ruta completa del padre, así que comparamos todo
# en el mismo formato en vez de mezclar nombres cortos y rutas completas.
declare -A SYS_DISK_SET=()
for d in "${SYS_DISKS[@]}"; do
  SYS_DISK_SET["$d"]=1
done

sys_disks_str="$(printf '%s ' "${!SYS_DISK_SET[@]}")"

# Candidatos: discos/particiones que NO pertenecen al conjunto de discos del
# sistema. Comparación EXACTA por ruta completa de disco (nunca por prefijo
# de string, que podía matchear discos distintos con nombres parecidos, ej.
# /dev/sda vs /dev/sda1 vs /dev/sdaX); las particiones se excluyen por su
# disco padre real (columna PKNAME de lsblk), no por el propio nombre de la
# partición.
lines=()
while IFS=$'\t' read -r dev type pkname size; do
  [[ -n "$dev" ]] || continue
  case "$type" in
    disk)
      [[ -n "${SYS_DISK_SET[$dev]:-}" ]] && continue
      ;;
    part)
      [[ -n "${SYS_DISK_SET[$pkname]:-}" ]] && continue
      ;;
    *)
      continue
      ;;
  esac
  lines+=("$dev"$'\t'"$size")
done < <(lsblk -rpno NAME,TYPE,PKNAME,SIZE 2>/dev/null)

if [[ ${#lines[@]} -eq 0 ]]; then
  msg "No se detectó ningún disco/partición aparte del/de los disco/s del sistema ($sys_disks_str).\n\nConecte el disco e intente de nuevo."
  exit 0
fi

menu_args=()
for l in "${lines[@]}"; do
  dev="$(cut -f1 <<<"$l")"
  size="$(cut -f2 <<<"$l")"
  fs="$(lsblk -rpno FSTYPE "$dev" 2>/dev/null | head -n1)"
  menu_args+=("$dev" "$size — ${fs:-sin-fs}")
done

DEV=$(dialog --clear --title "Disco de datos" \
  --menu "Disco/s del sistema (EXCLUIDO/s): $sys_disks_str\n\nSeleccione la partición/disco para el pool de media:" \
  18 78 8 "${menu_args[@]}" 3>&1 1>&2 2>&3) || exit 0

MODEL="$(lsblk -dno MODEL "$DEV" 2>/dev/null | head -n1 | xargs || true)"
SIZE="$(lsblk -dno SIZE "$DEV" 2>/dev/null | head -n1)"
fstype="$(lsblk -rpno FSTYPE "$DEV" 2>/dev/null | head -n1)"

if [[ -z "$fstype" ]]; then
  action="formatear"
else
  action=$(dialog --clear --title "Disco de datos" \
    --menu "$DEV ya tiene un sistema de archivos ($fstype).\n\n¿Qué desea hacer?" \
    14 70 3 \
    usar "Usar el contenido existente (no borra)" \
    formatear "Formatear en ext4 (BORRA TODO)" \
    3>&1 1>&2 2>&3) || exit 0
fi

# Punto de montaje por defecto inteligente: si MEDIA_ROOT ya está ocupado
# (montado o con datos), sugerir el primer /srv/mediaN libre (media2, media3...).
default_mp="$MEDIA_ROOT"
if mountpoint -q "$MEDIA_ROOT" 2>/dev/null || [[ -n "$(ls -A "$MEDIA_ROOT" 2>/dev/null)" ]]; then
  n=2
  while mountpoint -q "${MEDIA_ROOT}${n}" 2>/dev/null || [[ -n "$(ls -A "${MEDIA_ROOT}${n}" 2>/dev/null)" ]]; do
    n=$((n + 1))
  done
  default_mp="${MEDIA_ROOT}${n}"
fi

MP=$(input_box "Disco de datos" "Punto de montaje:" "$default_mp") || exit 0

# Resumen ("dry-run") antes de tocar nada: dispositivo, tamaño, modelo, acción
# y punto de montaje, todo junto para confirmar de una vez.
confirm "Se va a configurar el siguiente disco de datos:\n\nDispositivo : $DEV\nTamaño      : ${SIZE:-N/D}\nModelo      : ${MODEL:-N/D}\nAcción      : $action\nMontaje     : $MP\nfstab       : por UUID, con 'nofail'\n\n¿Continuar?" || exit 0

if [[ "$action" == "formatear" ]]; then
  confirm "Se va a FORMATEAR $DEV en ext4.\n\nSE BORRA TODO su contenido. ¿Continuar?" || exit 0
  confirm "ÚLTIMA confirmación: formatear $DEV y borrar todo.\n\n¿Seguro?" || exit 0
  sudo umount "$DEV" 2>/dev/null || true
  sudo mkfs.ext4 -F "$DEV"
fi

if [[ -d "$MP" && -n "$(ls -A "$MP" 2>/dev/null)" ]]; then
  confirm "OJO: $MP ya tiene contenido.\n\nAl montar el disco ahí, ese contenido queda OCULTO (no se borra, pero no se ve hasta desmontar el disco).\n\n¿Continuar igual?" || exit 0
fi

UUID="$(sudo blkid -s UUID -o value "$DEV" 2>/dev/null)"
[[ -n "$UUID" ]] || { msg "No pude obtener el UUID de $DEV."; exit 0; }

sudo mkdir -p "$MP"

# /etc/fstab por UUID + nofail. Se quita cualquier entrada previa del mismo
# UUID para que sea idempotente (re-ejecutar no duplica líneas).
sudo sed -i "\#^UUID=$UUID #d" /etc/fstab 2>/dev/null || true
echo "UUID=$UUID $MP ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null

sudo systemctl daemon-reload 2>/dev/null || true
sudo mount "$MP" 2>/dev/null || sudo mount -a

# Si el disco va a una raíz del pool (/srv/media o /srv/media<dígitos>), crea
# la estructura de carpetas de media sobre él. Si va a otro punto de montaje,
# solo ajusta dueño y permisos sin imponerle la estructura de media.
if [[ "$MP" == "$MEDIA_ROOT" || "$MP" =~ ^"$MEDIA_ROOT"[0-9]+$ ]]; then
  create_media_skeleton "$MP"
else
  sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$MP"
  sudo chmod -R 2775 "$MP"
fi

msg "Disco de datos configurado.\n\n$DEV → $MP\nEn /etc/fstab por UUID, con 'nofail' (el servidor arranca aunque el disco no esté conectado).\nSe monta solo en cada arranque."

mark_done datadisk
