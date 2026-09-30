#!/usr/bin/env bash
# Test end-to-end de modules/datadisk.sh, portado desde el HLI v1
# (referencia de lectura, nunca código importado) con los stubs
# especificados: lsblk/findmnt/mountpoint/systemctl/sudo/dialog.
#
# Motivo (lección de v2.2): una revisión estática + mocks de funciones NO
# detectó un bug real en este mismo módulo ('IFS=$'\t'' sobre una salida de
# 'lsblk -r' separada por ESPACIOS hacía que datadisk nunca listara ningún
# disco) — solo lo encontró correr el script REAL de punta a punta con
# comandos stubbeados por PATH. Por eso este test invoca
# 'bash modules/datadisk.sh' tal cual, nunca una función mockeada.
#
# Disco de "sistema" ($LSBLK_SYSDISK): NO se hardcodea "/dev/sda" — se toma
# del lsblk REAL del host (vía 'command -p', ignorando el PATH de stubs) que
# ya se corrió al principio del harness. system_disks() (lib/storage.sh)
# exige que sea un block device real ('[[ -b ]]'), así que tiene que ser uno
# que EXISTA de verdad en la máquina que corre el test.
#
# Disco "candidato" (/dev/sdz, a sumar al pool): fijo, nunca necesita ser un
# device real (nunca pasa por system_disks()).

_datadisk_detect_sysdisk() {
  command -p lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1; exit}'
}

# Escenario "disco estable": la huella de /dev/sdz no cambia entre la
# primera lectura y las revalidaciones posteriores -> debe llegar a
# mkfs.ext4 + escribir fstab (via 'sudo tee -a /etc/fstab', descartado por
# el stub porque /etc/fstab NO cae bajo el scratch — pero la LLAMADA sí
# debe intentarse).
test_datadisk_stable_disk_formats_and_writes_fstab() {
  export LSBLK_SYSDISK
  LSBLK_SYSDISK="$(_datadisk_detect_sysdisk)"
  [[ -n "$LSBLK_SYSDISK" && -b "$LSBLK_SYSDISK" ]] || { echo "no se detectó un disco real en este host, no se puede correr el test"; return 1; }
  export LSBLK_FP_CHANGE_AFTER_FIRST=0

  local REAL_ETC_FSTAB_HASH_BEFORE
  REAL_ETC_FSTAB_HASH_BEFORE="$(sha256sum /etc/fstab 2>/dev/null | awk '{print $1}')"

  echo "/dev/sdz" > "$DIALOG_MENU_QUEUE"
  echo "$MEDIA_ROOT" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'yes\nyes\nyes\n' > "$DIALOG_YESNO_QUEUE"

  bash "$REPO_ROOT/modules/datadisk.sh" || { echo "el módulo debería terminar en éxito en el escenario estable"; return 1; }

  assert_file_contains "$STATE_FILE" "datadisk" "mark_done datadisk" || return 1

  if ! grep -qF $'\t-F\t/dev/sdz' "$STUB_CALL_LOG"; then
    fail "debería haber corrido 'mkfs.ext4 -F /dev/sdz'"
    return 1
  fi
  if ! grep -qF '/etc/fstab' "$STUB_CALL_LOG"; then
    fail "debería haber intentado escribir /etc/fstab (aunque el stub lo descarte)"
    return 1
  fi

  # Nunca se tocó el /etc/fstab REAL de la máquina (el stub de 'tee'
  # descarta cualquier ruta fuera de STUB_SAFE_ROOT).
  assert_eq "$REAL_ETC_FSTAB_HASH_BEFORE" "$(sha256sum /etc/fstab 2>/dev/null | awk '{print $1}')" \
    "el /etc/fstab real de la máquina no debe cambiar" || return 1
}

# Escenario "disco swapeado a mitad de diálogo": la huella de /dev/sdz
# CAMBIA entre la primera lectura y la revalidación previa al formateo ->
# el módulo debe abortar SIN correr mkfs ni escribir fstab.
test_datadisk_disk_swapped_aborts_without_mkfs() {
  export LSBLK_SYSDISK
  LSBLK_SYSDISK="$(_datadisk_detect_sysdisk)"
  [[ -n "$LSBLK_SYSDISK" && -b "$LSBLK_SYSDISK" ]] || { echo "no se detectó un disco real en este host, no se puede correr el test"; return 1; }
  export LSBLK_FP_CHANGE_AFTER_FIRST=1

  echo "/dev/sdz" > "$DIALOG_MENU_QUEUE"
  echo "$MEDIA_ROOT" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'yes\nyes\nyes\n' > "$DIALOG_YESNO_QUEUE"

  if bash "$REPO_ROOT/modules/datadisk.sh"; then
    fail "el módulo NO debería terminar en éxito si el disco cambió a mitad de diálogo"
    return 1
  fi

  if grep -qF $'\t-F\t/dev/sdz' "$STUB_CALL_LOG"; then
    fail "NUNCA debería haber corrido mkfs.ext4 si el disco cambió"
    return 1
  fi
  if grep -qF '/etc/fstab' "$STUB_CALL_LOG"; then
    fail "NUNCA debería haber intentado escribir fstab si el disco cambió"
    return 1
  fi
  assert_file_not_contains "$STATE_FILE" "datadisk" "no debe marcarse hecho si se abortó" || return 1
}
