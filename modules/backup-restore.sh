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
_BR_PAGE="${HLI2_RESTORE_PAGE:-40}"

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

# Cantidad de rutas de $2 (servicio) que existen en la copia $1 (local|r2): sus
# datos menos las cachés excluidas y, en R2, menos las "solo local".
_br_restorable_count() {
  local source="$1" id="$2" p x skip n=0
  local -a excl=() lonly=()
  while IFS= read -r x; do [[ -z "$x" ]] || excl+=("$x"); done < <(service_get "$id" BACKUP_EXCLUDE)
  while IFS= read -r x; do [[ -z "$x" ]] || lonly+=("$x"); done < <(service_get "$id" BACKUP_LOCAL_ONLY)
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    skip=0
    for x in "${excl[@]}"; do [[ "$x" == "$p" ]] && skip=1; done
    if [[ "$source" == "r2" ]]; then
      for x in "${lonly[@]}"; do [[ "$x" == "$p" ]] && skip=1; done
    fi
    if [[ "$skip" -eq 0 ]]; then n=$(( n + 1 )); fi
  done < <(service_get "$id" DATA)
  printf '%s' "$n"
}

# Epoch de una clave de fecha del estado ('' si no se puede leer).
_br_epoch() {
  date -d "$1" +%s 2>/dev/null || true
}

# ¿El estado del último backup lo dejó el backup de seguridad de ESTA corrida?
# Resultado 'ok', con foto 'full' y fecha no anterior al inicio ($1, epoch). Solo
# entonces la restauración puede descartar la copia previa en disco.
_br_safety_fresh_ok() {
  local start="$1" ts e
  [[ "$(backup_status_get result)" == "ok" && -n "$(backup_status_get snapshot_full)" ]] || return 1
  ts="$(backup_status_get timestamp)"
  e="$(_br_epoch "$ts")"
  [[ "$e" =~ ^[0-9]+$ ]] && (( e >= start ))
}

# ¿El estado de la restauración es de ESTA llamada ($1 = epoch de inicio, $2 foto,
# $3 destino)? Si la llamada falló antes de empezar (p. ej. 'sudo -n' vencido) el
# archivo conserva el resultado de una restauración anterior, que no se debe mostrar.
_br_restore_status_fresh() {
  local start="$1" e
  e="$(_br_epoch "$(restore_status_get timestamp)")"
  [[ "$e" =~ ^[0-9]+$ ]] && (( e >= start )) \
    && [[ "$(restore_status_get snapshot)" == "$2" && "$(restore_status_get target)" == "$3" ]]
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
  local -a snap_ids=() snap_times=()
  local sid stime
  while IFS=$'\t' read -r sid stime; do
    [[ "$sid" =~ ^[0-9a-f]{8,64}$ && -n "$stime" ]] || continue
    snap_ids+=("$sid") snap_times+=("$stime")
  done <<<"$list"
  if [[ ${#snap_ids[@]} -eq 0 ]]; then
    msg "No hay fotos para restaurar en $source_label."
    return 1
  fi
  # Páginas de $_BR_PAGE fotos, la más nueva primero; "ver más antiguas" pasa a la
  # página siguiente (la retención deja unas 17 por copia, pero un historial largo no se esconde).
  local snapshot="" i offset=0 snapshot_time=""
  while true; do
    local -a snap_items=()
    for (( i = offset; i < offset + _BR_PAGE && i < ${#snap_ids[@]}; i++ )); do
      snap_items+=("${snap_ids[$i]}" "$(restore_fmt_time "${snap_times[$i]}")")
    done
    if (( offset + _BR_PAGE < ${#snap_ids[@]} )); then
      snap_items+=("more" "Ver fotos más antiguas...")
    fi
    snapshot="$(menu_box "Restaurar — fecha" "Foto a restaurar (la más nueva primero):" "${snap_items[@]}")" || return 0
    if [[ "$snapshot" == "more" ]]; then
      offset=$(( offset + _BR_PAGE ))
      continue
    fi
    break
  done
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
  if [[ "$source" == "r2" && "$target" != "all" && "$(_br_restorable_count r2 "$target")" -eq 0 ]]; then
    msg "Los datos de $(_br_target_label "$target") solo existen en la copia local: no están en la copia externa (R2), así que no hay nada que restaurar desde ahí.\n\nElija la copia local, si el disco de media sigue disponible."
    return 0
  fi

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

  # Backup de seguridad (por defecto, sí). Hay tres respuestas: sí (0), no (1) y
  # ESC/otro (cancela TODO: no se interpreta como "no hacer backup y seguir").
  local -a opts=()
  local rc=0 crc=0 safety_start restore_start
  confirm "¿Hacer un backup de seguridad del estado actual antes de restaurar?\n\nRecomendado: si la fecha elegida no era la correcta, podrá volver al estado de ahora. Tarda unos minutos y no borra copias viejas." || crc=$?
  case "$crc" in
    0)
      safety_start="$(date +%s)"
      if _br_safety_backup; then
        # Solo si el estado del backup lo confirma (resultado correcto, con foto, de
        # ESTA corrida) la copia previa en disco sobra: el estado actual ya está en el repositorio.
        if _br_safety_fresh_ok "$safety_start"; then
          opts+=(--discard-old)
        else
          msg "No se pudo confirmar el resultado del backup de seguridad: se restaurará igual, pero la copia previa de cada carpeta se conservará en disco."
        fi
      else
        confirm "El backup de seguridad terminó con errores (ver $LOG_DIR/backup.log).\n\n¿Restaurar de todas formas? Lo actual se conservará en disco junto a cada carpeta, pero no habrá copia de seguridad en el repositorio." no || return 1
      fi
      ;;
    1) ;;
    *)
      msg "Restauración cancelada: no se respondió a la pregunta del backup de seguridad. No se cambió nada."
      return 0
      ;;
  esac

  # 5. Restauración (como root, desde la copia root-owned)
  hli_busy_end
  clear 2>/dev/null || true
  echo "== Restauración (puede tardar; el avance se muestra abajo) =="
  restore_start="$(date +%s)"
  rc=0
  sudo -n "$_BR_EXE" restore --source "$source" --snapshot "$snapshot" --target "$target" "${opts[@]}" "${extra[@]}" || rc=$?
  echo
  if [[ -t 0 ]]; then
    read -r -p "Presione Enter para ver el resultado... " _ || true
  fi

  # 6. Resultado (solo si lo dejó ESTA llamada: si falló antes de empezar, el archivo
  # de estado es de una restauración anterior y no se muestra como si fuera esta).
  local summary result
  if ! _br_restore_status_fresh "$restore_start" "$snapshot" "$target"; then
    msg "No se pudo leer el resultado de la restauración (código $rc): el estado no se actualizó. ¿Venció la sesión de sudo?\n\nNo se sabe si se restauró algo. Revise el log: $LOG_DIR/backup.log (sudo less)"
    return 1
  fi
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
