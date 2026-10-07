#!/usr/bin/env bash
# HLI-MODULE: backup-restore
# HLI-DESC: Restaurar un backup (un servicio o todo, desde local o R2)
# HLI-ORDER: 72
# HLI-DEFAULT: no
# HLI-TIPO: tool
# HLI-TUI: yes
#
# Restauración guiada (v2.5, parte 2): origen (copia local o Cloudflare R2),
# fecha de la foto y qué restaurar (un servicio o "todo"). Todo lo que toca los
# datos lo hace bin/hli2-backup (subcomando 'restore') como root, desde la copia
# root-owned del código; este módulo solo pregunta, valida lo que el usuario
# eligió contra las listas que devuelve root, y muestra el resultado. La
# estrategia de restauración (carpeta de paso, intercambio, qué se salta en
# "todo") está documentada en lib/restore.sh.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

_BR_EXE="$BACKUP_INSTALL_DIR/bin/hli2-backup"
_BR_MAX_SNAPSHOTS=40

# Nombre para mostrar de lo elegido.
_br_target_label() {
  local target="$1"
  if [[ "$target" == "all" ]]; then
    printf 'TODO (todos los servicios con datos, la configuración de Samba y los secretos de /etc/hli2)'
  else
    service_get "$target" NAME
  fi
}

# Ítems del menú de "qué restaurar": 'all' y los servicios con datos (tag, texto).
# Con origen R2, lo "solo local" (archivos de OpenCloud) se avisa en el propio ítem.
_br_target_items() {
  local source="$1" id name note
  printf '%s\n%s\n' "all" "Todo: servicios, Samba y /etc/hli2 (para migrar a un equipo nuevo)"
  while read -r id; do
    [[ -n "$id" ]] || continue
    [[ -n "$(service_get "$id" DATA)" ]] || continue
    name="$(service_get "$id" NAME)"
    note=""
    if [[ "$source" == "r2" && -n "$(service_get "$id" BACKUP_LOCAL_ONLY)" ]]; then
      note=" (solo la configuración: los archivos no están en la copia externa)"
    fi
    printf '%s\n%s\n' "$id" "$name$note"
  done < <(service_list)
}

# ¿Algún dato de lo elegido es "solo local" (no está en la copia externa)?
_br_has_local_only() {
  local target="$1" id
  while read -r id; do
    [[ -n "$id" ]] || continue
    if [[ "$target" == "all" || "$target" == "$id" ]] && [[ -n "$(service_get "$id" BACKUP_LOCAL_ONLY)" ]]; then
      return 0
    fi
  done < <(service_list)
  return 1
}

# Corre el backup de seguridad previo en primer plano. 0 = terminó bien.
_br_safety_backup() {
  local rc=0
  hli_busy_end
  clear 2>/dev/null || true
  echo "== Backup de seguridad del estado actual (puede tardar; el avance se muestra abajo) =="
  # Sin retención: podría borrar justo la foto que se va a restaurar.
  sudo -n "$_BR_EXE" run --no-retention || rc=$?
  echo
  return "$rc"
}

_backup_restore_main() {
  if ! priv_file_exists "$BACKUP_PASSWORD_FILE"; then
    msg "Los backups no están configurados todavía.\n\nCorra primero el módulo 'backup-setup' (en un equipo nuevo, con LA MISMA contraseña de restic de los backups, para recuperarse de un desastre)."
    return 1
  fi

  # Copia root-owned del código (por si se actualizó el HLI 2 con git, o es la
  # primera vez): root solo ejecuta esa copia, nunca el checkout.
  if ! backup_refresh_install; then
    msg "No se pudo actualizar la copia del código del backup en $BACKUP_INSTALL_DIR."
    return 1
  fi

  # 1. Origen
  local source="local"
  if backup_r2_configured; then
    source="$(menu_box "Restaurar — origen" "¿Desde dónde restaurar?" \
      local "Copia local (disco de media): incluye los archivos de OpenCloud" \
      r2 "Copia externa (Cloudflare R2): sin los archivos de OpenCloud")" || return 0
  fi
  [[ "$source" == "local" || "$source" == "r2" ]] || return 0
  local source_label="la copia local"
  [[ "$source" == "local" ]] || source_label="la copia externa (R2)"

  # 2. Foto (fecha): la lista la arma root (los repositorios son de root).
  hli_busy "Leyendo las fotos disponibles en $source_label..."
  local list err
  err="$(mktemp)"
  if ! list="$(sudo -n "$_BR_EXE" snapshots --source "$source" 2>"$err")"; then
    msg "No se pudo leer la lista de fotos de $source_label.\n\n$(tail -n 3 "$err")"
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  local -a snap_items=() snap_ids=() snap_times=()
  local sid stime
  while IFS=$'\t' read -r sid stime; do
    [[ "$sid" =~ ^[0-9a-f]{8,64}$ && -n "$stime" ]] || continue
    snap_ids+=("$sid") snap_times+=("$stime")
    snap_items+=("$sid" "$(restore_fmt_time "$stime")")
    (( ${#snap_ids[@]} < _BR_MAX_SNAPSHOTS )) || break
  done <<<"$list"
  if [[ ${#snap_ids[@]} -eq 0 ]]; then
    msg "No hay fotos para restaurar en $source_label."
    return 1
  fi
  local snapshot
  snapshot="$(menu_box "Restaurar — fecha" "Foto a restaurar (la más nueva primero):" "${snap_items[@]}")" || return 0
  local i snapshot_time=""
  for (( i = 0; i < ${#snap_ids[@]}; i++ )); do
    [[ "${snap_ids[$i]}" == "$snapshot" ]] && snapshot_time="${snap_times[$i]}"
  done
  [[ -n "$snapshot_time" ]] || return 0   # solo se aceptan ids que devolvió root
  local when
  when="$(restore_fmt_time "$snapshot_time")"

  # 3. Qué restaurar
  local -a target_items=()
  while IFS= read -r sid; do target_items+=("$sid"); done < <(_br_target_items "$source")
  local target
  target="$(menu_box "Restaurar — qué" "¿Qué restaurar?" "${target_items[@]}")" || return 0
  restore_valid_target "$target" || return 0

  local -a extra=()
  if [[ "$target" == "all" ]] && confirm "¿Restaurar también restic.env (las credenciales de R2) de la foto?\n\nNormalmente NO: este equipo ya tiene las suyas, y backup-setup las vuelve a pedir en uno nuevo." no; then
    extra+=(--with-restic-env)
  fi

  # 4. Confirmación clara
  local what warn=""
  what="$(_br_target_label "$target")"
  if [[ "$target" == "all" ]]; then
    warn="\n- Se restaura también /etc/hli2 (secretos de los servicios). NO se tocan restic-password ni dokploy.env"
    [[ ${#extra[@]} -eq 0 ]] && warn+=" ni restic.env"
    warn+=" de este equipo."
  fi
  if [[ "$source" == "r2" ]] && _br_has_local_only "$target"; then
    warn+="\n- Los ARCHIVOS de OpenCloud no están en la copia externa: no se restauran (solo su configuración) y lo que hay ahora en esa carpeta no se toca."
  fi
  confirm "Se va a RESTAURAR:\n\n- Qué: $what\n- Desde: $source_label\n- Foto: $when ($snapshot)\n\nLo que hay ahora en esas carpetas será REEMPLAZADO por el contenido de esa fecha (no se mezcla). Los contenedores afectados se detienen durante la restauración y se vuelven a iniciar.\nAntes de reemplazar, lo actual se aparta junto a cada carpeta (.hli2-before-restore-<fecha>) y se conserva hasta la próxima restauración.${warn}\n\n¿Continuar?" || return 0

  # Backup de seguridad (por defecto, sí).
  local -a opts=()
  local rc=0
  if confirm "¿Hacer un backup de seguridad del estado actual antes de restaurar?\n\nRecomendado: si la fecha elegida no era la correcta, podrá volver al estado de ahora. Tarda unos minutos y no borra copias viejas."; then
    if _br_safety_backup; then
      # El estado actual ya está en el repositorio: la copia previa en disco sobra.
      opts+=(--discard-old)
    else
      confirm "El backup de seguridad terminó con errores (ver $LOG_DIR/backup.log).\n\n¿Restaurar de todas formas? Lo actual se conservará en disco junto a cada carpeta, pero no habrá copia de seguridad en el repositorio." no || return 1
    fi
  fi

  # 5. Restauración (como root, desde la copia root-owned)
  hli_busy_end
  clear 2>/dev/null || true
  echo "== Restauración (puede tardar; el avance se muestra abajo) =="
  rc=0
  sudo -n "$_BR_EXE" restore --source "$source" --snapshot "$snapshot" --target "$target" "${opts[@]}" "${extra[@]}" || rc=$?
  echo
  if [[ -t 0 ]]; then
    read -r -p "Presione Enter para ver el resultado... " _ || true
  fi

  # 6. Resultado
  local summary result
  summary="$(restore_status_summary)"
  result="$(restore_status_get result)"
  if [[ "$rc" -eq 0 && ( "$result" == "ok" || "$result" == "warning" ) ]]; then
    msg "Restauración terminada.\n\n$summary\n\nLog: $LOG_DIR/backup.log (sudo less)"
  else
    msg "La restauración terminó con errores (código $rc).\n\n$summary\n\nLog: $LOG_DIR/backup.log (sudo less)"
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _backup_restore_main
fi
