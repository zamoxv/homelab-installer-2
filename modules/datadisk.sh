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
# 'lsblk -r' separa columnas con ESPACIOS (y escapa los espacios internos de
# los valores como \x20). PKNAME va ÚLTIMA: en discos enteros está vacía, y
# si estuviera en el medio, 'read' colapsaría los espacios consecutivos y
# correría el tamaño a la columna equivocada.
while read -r dev type size pkname; do
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
done < <(lsblk -rpno NAME,TYPE,SIZE,PKNAME 2>/dev/null)

if [[ ${#lines[@]} -eq 0 ]]; then
  msg "No se detectó ningún disco/partición aparte del/de los disco/s del sistema ($sys_disks_str).\n\nConecte el disco e intente de nuevo."
  exit 0
fi

menu_args=()
for l in "${lines[@]}"; do
  dev="$(cut -f1 <<<"$l")"
  size="$(cut -f2 <<<"$l")"
  fs="$(lsblk -dno FSTYPE "$dev" 2>/dev/null)" || fs=""
  # tail -n +2: la primera línea es el propio dispositivo (en una partición,
  # contarla a ella misma mostraba "con 1 partición(es)").
  nparts="$(lsblk -rpno TYPE "$dev" 2>/dev/null | tail -n +2 | grep -c '^part$')" || nparts=0
  if [[ -z "$fs" && "${nparts:-0}" -gt 0 ]]; then
    fs="con ${nparts} partición(es)"
  fi
  menu_args+=("$dev" "$size — ${fs:-sin-fs}")
done

DEV=$(dialog --clear --title "Disco de datos" \
  --menu "Disco/s del sistema (EXCLUIDO/s): $sys_disks_str\n\nSeleccione la partición/disco para el pool de media:" \
  18 78 8 "${menu_args[@]}" 3>&1 1>&2 2>&3) || exit 0

# Huella del dispositivo elegido (tamaño exacto en bytes, serie, WWN, modelo).
# Se toma ahora y se vuelve a comparar justo antes de cualquier acción: si el
# disco se desconectó mientras el diálogo estaba abierto y otro disco quedó en
# el mismo /dev/sdX, la huella no coincide y el módulo aborta en vez de
# formatear el disco equivocado. FALLA CERRADO: sin huella, no se continúa.
_dev_fingerprint() {
  # PARTUUID: en particiones lsblk no informa SERIAL/MODEL; el PARTUUID las
  # identifica de forma única (mkfs no lo modifica).
  # En particiones se agrega además SERIAL/MODEL del disco padre (en MBR sin
  # WWN ni PARTUUID, la huella quedaría reducida al tamaño).
  local own parent=""
  own="$(lsblk -dnbo SIZE,SERIAL,WWN,MODEL,PARTUUID "$1" 2>/dev/null)" || return 1
  [[ -n "$own" ]] || return 1
  if [[ "$(lsblk -dno TYPE "$1" 2>/dev/null)" == "part" ]]; then
    parent="$(lsblk -dnpo PKNAME "$1" 2>/dev/null)" || return 1
    [[ -n "$parent" ]] || return 1
    parent="$(lsblk -dnbo SERIAL,MODEL "$parent" 2>/dev/null)" || return 1
  fi
  printf '%s|%s\n' "$own" "$parent"
}
_abort_dev_gone() {
  msg "El dispositivo $DEV ya no está disponible o cambió (¿se desconectó o se conectó otro disco en su lugar?).\n\nHLI 2 no continúa. Vuelva a ejecutar el módulo."
  exit 1
}
FP="$(_dev_fingerprint "$DEV")" || _abort_dev_gone
[[ -n "$FP" ]] || _abort_dev_gone

# Solo informativos: si fallan, se muestran como N/D.
MODEL="$(lsblk -dno MODEL "$DEV" 2>/dev/null | head -n1 | xargs)" || MODEL=""
SIZE="$(lsblk -dno SIZE "$DEV" 2>/dev/null | head -n1)" || SIZE=""

# Sistema de archivos del PROPIO dispositivo (-d: sin hijos). Si lsblk falla,
# el disco desapareció: abortar, nunca interpretar "vacío" como "sin datos".
fstype="$(lsblk -dno FSTYPE "$DEV" 2>/dev/null)" || _abort_dev_gone

# Si es un disco entero, sus particiones (con o sin sistema de archivos). Un
# disco sin FSTYPE propio pero con particiones NO está vacío: formatearlo
# borra todas esas particiones, y hay que decirlo explícitamente.
children=""
if [[ "$(lsblk -dno TYPE "$DEV" 2>/dev/null)" == "disk" ]]; then
  children="$(lsblk -rpno NAME,FSTYPE,SIZE "$DEV" 2>/dev/null | tail -n +2)" || _abort_dev_gone
fi

# dialog no respeta saltos de línea reales en el texto: necesita '\n'.
children_msg="${children//$'\n'/\\n}"

if [[ -z "$fstype" && -n "$children" ]]; then
  action=$(dialog --clear --title "Disco de datos" \
    --menu "ATENCIÓN: $DEV es un disco entero que ya tiene particiones:\n\n${children_msg}\n\nPara usar una partición existente, cancele y elija la partición en la lista.\nFormatear el disco entero BORRA TODAS esas particiones.\n\n¿Qué desea hacer?" \
    20 78 2 \
    cancelar "No hacer nada" \
    formatear "Formatear el disco entero en ext4 (BORRA TODO)" \
    3>&1 1>&2 2>&3) || exit 0
  [[ "$action" == "formatear" ]] || exit 0
elif [[ -z "$fstype" ]]; then
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
# ¿Punto de montaje libre? No montado y sin archivos (puede tener carpetas
# vacías: la estructura que crea 'storage' en /srv/media no cuenta como
# contenido; así, el primer disco de datos se sugiere en /srv/media).
_mp_free() {
  ! mountpoint -q "$1" 2>/dev/null \
    && [[ -z "$(find "$1" -mindepth 1 -type f -print -quit 2>/dev/null)" ]]
}

default_mp="$MEDIA_ROOT"
if ! _mp_free "$MEDIA_ROOT"; then
  n=2
  while ! _mp_free "${MEDIA_ROOT}${n}"; do
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
  # Revalidar la huella inmediatamente antes de la operación destructiva.
  fp_now="$(_dev_fingerprint "$DEV")" || _abort_dev_gone
  [[ "$fp_now" == "$FP" ]] || _abort_dev_gone
  sudo umount "$DEV" 2>/dev/null || true
  sudo mkfs.ext4 -F "$DEV"
fi

if [[ -d "$MP" ]] && ! _mp_free "$MP"; then
  confirm "OJO: $MP ya tiene contenido.\n\nAl montar el disco ahí, ese contenido queda OCULTO (no se borra, pero no se ve hasta desmontar el disco).\n\n¿Continuar igual?" || exit 0
fi

# Revalidar también antes de escribir fstab/montar (camino "usar" incluido).
fp_now="$(_dev_fingerprint "$DEV")" || _abort_dev_gone
[[ "$fp_now" == "$FP" ]] || _abort_dev_gone

UUID="$(sudo blkid -s UUID -o value "$DEV" 2>/dev/null)" || UUID=""
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
