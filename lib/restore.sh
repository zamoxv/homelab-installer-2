#!/usr/bin/env bash
# Restauración de backups (v2.5, parte 2). Complementa lib/backup.sh y corre,
# igual que él, COMO ROOT desde bin/hli2-backup (subcomandos 'restore' y
# 'snapshots'); el usuario solo la alcanza a través del módulo
# modules/backup-restore.sh, que llama al punto de entrada con 'sudo'. Los
# argumentos vienen del usuario y se pasan a root: se validan de forma
# estricta (ver restore_parse_args) y las rutas salen SIEMPRE del registro de
# servicios de la copia root-owned, nunca de los argumentos.
#
# Estrategia (decidida a propósito):
#   1. Se resuelve y verifica la foto: el id (hexadecimal) tiene que existir en
#      el repositorio elegido con el tag esperado ('full' en el local, 'cloud'
#      en R2), y se usa su id completo.
#   2. Se detienen los contenedores afectados (lista de recuperación primero,
#      como en el backup; siempre se vuelven a iniciar, también ante señales).
#   3. Cada ruta se restaura PRIMERO en una carpeta de paso vecina
#      (<ruta>.hli2-restore-tmp, mismo sistema de archivos) con
#      'restic restore --target <paso> --include <ruta>': restic recrea la ruta
#      absoluta dentro de <paso>, con dueños y modos de la foto (como root).
#   4. Solo si TODAS las rutas del servicio se restauraron bien se intercambian:
#      lo actual pasa a <ruta>.hli2-before-restore-<fecha> (un 'mv', atómico) y
#      lo restaurado ocupa su lugar. Si falla un intercambio se deshace todo el
#      servicio. Es un reemplazo, no una mezcla: la carpeta queda IDÉNTICA a la
#      foto. Una restauración fallida o interrumpida nunca deja una carpeta a
#      medio escribir (las señales se ignoran durante los dos 'mv').
#   5. Al terminar bien se conserva la ÚLTIMA copia previa de cada ruta (las
#      anteriores se borran); con --discard-old (el módulo lo pasa si acaba de
#      hacer un backup de seguridad) se borra también esa.
#
# "Todo" (--target all): todos los servicios con datos + /etc/samba/smb.conf
# (es el dato de 'smbd') + los .env de /etc/hli2. NUNCA toca restic-password
# (ni va dentro de los backups). restic.env (credenciales de R2) solo con
# --with-restic-env, y dokploy.env nunca (describe una instancia de Dokploy
# que en un equipo nuevo es otra: pisarlo rompería la API recién configurada).
# El estado del HLI (/var/lib/hli2) y su config no se restauran: vuelven al
# reinstalar el HLI.
#
# Supuestos de restic 0.16.4 (NO verificados en hardware): 'restore <id>
# --target <dir> --include <ruta-absoluta>' restaura la ruta con todo su
# contenido bajo <dir>/<ruta>; crea <dir> si falta; 'snapshots --json' trae
# 'id', 'short_id', 'time' y 'tags'; 'snapshots --tag T <id>' admite el id
# corto como argumento posicional.
set -euo pipefail

RESTORE_STATUS_FILE="$BACKUP_STATE_DIR/restore-status"
RESTORE_STAGE_SUFFIX=".hli2-restore-tmp"
RESTORE_OLD_SUFFIX=".hli2-before-restore"

# Resultado de la corrida. RS_ACTIVE=1 mientras haya una restauración en curso:
# si el proceso muere, el trap deja 'interrupted'.
RS_RESULT="ok" RS_SOURCE="" RS_SNAPSHOT="" RS_TARGET="" RS_MSG="" RS_MODULES=""
RS_DISCARD=0 RS_WITH_RESTIC_ENV=0 RS_ACTIVE=0 RS_RID="" RS_STIME="" RS_TS=""
RS_STAGES=()                       # carpetas de paso vivas (limpieza ante una salida anormal)
RS_SW_DST=() RS_SW_OLD=() RS_SW_HAD=()   # intercambios del servicio en curso
RS_KEPT_DST=() RS_KEPT_OLD=()      # copias previas que quedaron en disco

# --- Utilidades ----------------------------------------------------------------------

# Como root se ejecuta directo; sin ser root (solo los tests) va por 'sudo -n'
# (simulado). Todo lo que muta el disco en la restauración pasa por acá.
_restore_priv() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo -n "$@"; fi
}

_restore_exists() {
  _restore_priv test -e "$1" || _restore_priv test -L "$1"
}

_restore_msg_add() {
  local m="${1//$'\n'/ }"
  RS_MSG+="${RS_MSG:+; }$m"
}

_restore_worse() {
  case "$1" in
    error) RS_RESULT=error ;;
    warning) [[ "$RS_RESULT" == "error" ]] || RS_RESULT=warning ;;
  esac
  return 0
}

_restore_signals_ignore() { trap '' INT TERM HUP; }
_restore_signals_restore() {
  trap 'exit 143' TERM
  trap 'exit 130' INT HUP
}

# Fecha legible de un instante RFC 3339 de restic (hora local del equipo).
restore_fmt_time() {
  local t="$1" out
  if out="$(date -d "$t" '+%Y-%m-%d %H:%M' 2>/dev/null)"; then
    printf '%s' "$out"
  else
    t="${t/T/ }"
    printf '%s' "${t:0:16}"
  fi
}

# Ruta de dato apta para tocar como root: absoluta, sin '..', sin caracteres de
# patrón de restic ni espacios, y nunca '/' ni una carpeta de primer nivel.
_restore_path_ok() {
  local p="$1"
  [[ "$p" =~ ^/[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || return 1
  [[ "/$p/" != */../* && "$p" != *"/./"* ]]
}

# --- Validación de argumentos ------------------------------------------------------------

restore_valid_snapshot_id() { [[ "$1" =~ ^[0-9a-f]{8,64}$ ]]; }
restore_valid_source() { [[ "$1" == "local" || "$1" == "r2" ]]; }

# 'all' o el id de un servicio del registro que tiene datos.
restore_valid_target() {
  local t="$1" id
  [[ "$t" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || return 1
  [[ "$t" == "all" ]] && return 0
  while read -r id; do
    if [[ "$id" == "$t" ]]; then
      [[ -n "$(service_get "$id" DATA)" ]]
      return
    fi
  done < <(service_list)
  return 1
}

_restore_bad_arg() {
  printf 'ERROR: %s\n' "$1" >&2
  return 2
}

# Valida y asigna RS_SOURCE/RS_SNAPSHOT/RS_TARGET/RS_DISCARD/RS_WITH_RESTIC_ENV.
# Solo se admite la forma '--opcion valor'; una opción repetida, una opción
# desconocida o un valor inválido se rechaza SIN ejecutar nada (código 2).
restore_parse_args() {
  RS_SOURCE="" RS_SNAPSHOT="" RS_TARGET="" RS_DISCARD=0 RS_WITH_RESTIC_ENV=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source|--snapshot|--target)
        [[ $# -ge 2 ]] || { _restore_bad_arg "a $1 le falta el valor"; return 2; }
        case "$1" in
          --source)
            [[ -z "$RS_SOURCE" ]] || { _restore_bad_arg "--source repetido"; return 2; }
            restore_valid_source "$2" || { _restore_bad_arg "--source inválido (use local o r2)"; return 2; }
            RS_SOURCE="$2"
            ;;
          --snapshot)
            [[ -z "$RS_SNAPSHOT" ]] || { _restore_bad_arg "--snapshot repetido"; return 2; }
            restore_valid_snapshot_id "$2" || { _restore_bad_arg "--snapshot inválido (id hexadecimal de 8 a 64 caracteres)"; return 2; }
            RS_SNAPSHOT="$2"
            ;;
          --target)
            [[ -z "$RS_TARGET" ]] || { _restore_bad_arg "--target repetido"; return 2; }
            restore_valid_target "$2" || { _restore_bad_arg "--target inválido (use all o un servicio con datos del registro)"; return 2; }
            RS_TARGET="$2"
            ;;
        esac
        shift 2
        ;;
      --discard-old) RS_DISCARD=1; shift ;;
      --with-restic-env) RS_WITH_RESTIC_ENV=1; shift ;;
      *) _restore_bad_arg "argumento no reconocido: $(printf '%q' "$1")"; return 2 ;;
    esac
  done
  [[ -n "$RS_SOURCE" && -n "$RS_SNAPSHOT" && -n "$RS_TARGET" ]] \
    || { _restore_bad_arg "faltan argumentos (--source, --snapshot y --target son obligatorios)"; return 2; }
  return 0
}

# --- Estado ------------------------------------------------------------------------------------

_restore_status_write() {
  local tmp
  tmp="$(mktemp "$BACKUP_STATE_DIR/.rstatus.XXXXXX")" || return 1
  {
    printf 'timestamp=%s\n' "$(date -Is)"
    printf 'result=%s\n' "$RS_RESULT"
    printf 'source=%s\n' "$RS_SOURCE"
    printf 'snapshot=%s\n' "$RS_SNAPSHOT"
    printf 'snapshot_time=%s\n' "$RS_STIME"
    printf 'target=%s\n' "$RS_TARGET"
    printf 'modules=%s\n' "$RS_MODULES"
    printf 'message=%s\n' "$RS_MSG"
  } > "$tmp"
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$RESTORE_STATUS_FILE"
}

# Valor de una clave del estado de la restauración (archivo 0644, sin secretos;
# lo lee el módulo sin privilegios).
restore_status_get() {
  local key="$1" line
  [[ -r "$RESTORE_STATUS_FILE" ]] || return 0
  while IFS= read -r line; do
    case "$line" in "${key}="*) printf '%s' "${line#"${key}="}"; return 0 ;; esac
  done < "$RESTORE_STATUS_FILE"
  return 0
}

# Una restauración que murió deja 'running': se reescribe como 'interrupted'
# (solo con el bloqueo tomado).
restore_status_mark_stale() {
  [[ "$(restore_status_get result)" == "running" ]] || return 0
  RS_RESULT=interrupted
  RS_SOURCE="$(restore_status_get source)" RS_SNAPSHOT="$(restore_status_get snapshot)"
  RS_STIME="$(restore_status_get snapshot_time)" RS_TARGET="$(restore_status_get target)"
  RS_MODULES="" RS_MSG="la restauración anterior quedó interrumpida (reinicio, corte de luz o proceso terminado)"
  _restore_status_write
}

# Texto del resultado de la última restauración, para el módulo.
restore_status_summary() {
  local ts res when msg mods st
  if [[ ! -r "$RESTORE_STATUS_FILE" ]]; then
    printf '  Sin restauraciones registradas\n'
    return 0
  fi
  ts="$(restore_status_get timestamp)"
  res="$(restore_status_get result)"
  when="${ts/T/ }"; when="${when:0:16}"
  printf '  Restauración : %s — %s\n' "${when:-N/D}" "$(_backup_res_es "$res")"
  printf '  Origen       : %s\n' "$([[ "$(restore_status_get source)" == "r2" ]] && echo "copia externa (R2)" || echo "copia local")"
  st="$(restore_status_get snapshot_time)"
  printf '  Foto         : %s (%s)\n' "$([[ -n "$st" ]] && restore_fmt_time "$st" || echo N/D)" "$(restore_status_get snapshot)"
  printf '  Qué          : %s\n' "$([[ "$(restore_status_get target)" == "all" ]] && echo "todo" || restore_status_get target)"
  msg="$(restore_status_get message)"
  [[ -z "$msg" ]] || printf '  Detalle      : %s\n' "$msg"
  mods="$(restore_status_get modules)"
  [[ -z "$mods" ]] || printf '  Falta        : los contenedores de estos servicios no existen todavía; ejecute sus módulos: %s\n' "$mods"
  return 0
}

# --- Repositorio y foto ------------------------------------------------------------------------

_restore_restic() {
  if [[ "$RS_SOURCE" == "r2" ]]; then _backup_restic_r2 "$@"; else _backup_restic_local "$@"; fi
}

# Comprobaciones comunes a 'snapshots' y 'restore'. El motivo queda en RS_MSG.
_restore_open_repo() {
  command -v restic >/dev/null 2>&1 || { _restore_msg_add "restic no está instalado (ejecute backup-setup)"; return 1; }
  _backup_password_ok || { _restore_msg_add "falta la contraseña de restic o es inválida (ejecute backup-setup)"; return 1; }
  if [[ "$RS_SOURCE" == "r2" ]]; then
    backup_r2_load || { _restore_msg_add "la copia externa (R2) no está configurada (ejecute backup-setup)"; return 1; }
  else
    BK_MSG=""
    if ! _backup_guard_fs; then
      _restore_msg_add "copia local no disponible: $BK_MSG"
      return 1
    fi
    [[ -f "$BACKUP_ROOT/config" ]] || { _restore_msg_add "el repositorio local no está inicializado (ejecute backup-setup)"; return 1; }
  fi
  return 0
}

_restore_tag() {
  if [[ "$RS_SOURCE" == "r2" ]]; then echo cloud; else echo full; fi
}

# Subcomando 'snapshots --source local|r2': imprime por stdout (sin log ni
# estado: el módulo lo captura) una línea 'id_corto<TAB>fecha' por foto del tag
# correspondiente, la más nueva primero. Solo se imprimen ids y fechas con la
# forma esperada.
restore_snapshots_main() {
  local out rc=0
  RS_SOURCE=""
  if [[ $# -ne 2 || "$1" != "--source" ]] || ! restore_valid_source "$2"; then
    _restore_bad_arg "uso: hli2-backup snapshots --source local|r2" || return 2
  fi
  RS_SOURCE="$2"
  RS_MSG=""
  if ! _restore_open_repo; then
    printf 'ERROR: %s\n' "$RS_MSG" >&2
    return 1
  fi
  out="$(_restore_restic snapshots --tag "$(_restore_tag)" --json </dev/null)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf 'ERROR: no se pudo leer la lista de fotos (código %s)\n' "$rc" >&2
    return 1
  fi
  printf '%s' "$out" | jq -r '
    [ .[] | select((.short_id // "") | test("^[0-9a-f]{8,64}$"))
          | select((.time // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9:]+)$")) ]
    | sort_by(.time) | reverse | .[] | [.short_id, .time] | @tsv' \
    || { printf 'ERROR: respuesta inesperada de restic\n' >&2; return 1; }
}

# Comprueba que la foto pedida existe con el tag esperado y fija RS_RID (id
# completo) y RS_STIME (fecha). Falla si el id no identifica exactamente una.
_restore_resolve_snapshot() {
  local out n rc=0
  out="$(_restore_restic snapshots --tag "$(_restore_tag)" --json "$RS_SNAPSHOT" 2>/dev/null </dev/null)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _restore_msg_add "no se encontró la foto $RS_SNAPSHOT en la copia elegida (¿ya se eliminó por la retención?)"
    return 1
  fi
  n="$(printf '%s' "$out" | jq 'length' 2>/dev/null)" || n=""
  if [[ "$n" != "1" ]]; then
    _restore_msg_add "la foto $RS_SNAPSHOT no existe en la copia elegida o no es del tipo esperado ($(_restore_tag))"
    return 1
  fi
  RS_RID="$(printf '%s' "$out" | jq -r '.[0].id // empty' 2>/dev/null)" || RS_RID=""
  RS_STIME="$(printf '%s' "$out" | jq -r '.[0].time // empty' 2>/dev/null)" || RS_STIME=""
  restore_valid_snapshot_id "$RS_RID" || RS_RID="$RS_SNAPSHOT"
  [[ "$RS_STIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9:]+)$ ]] || RS_STIME=""
  return 0
}

# --- Registro: servicios, rutas y contenedores ---------------------------------------------

_restore_target_services() {
  local id
  if [[ "$RS_TARGET" != "all" ]]; then
    printf '%s\n' "$RS_TARGET"
    return 0
  fi
  while read -r id; do
    if [[ -n "$id" && -n "$(service_get "$id" DATA)" ]]; then printf '%s\n' "$id"; fi
  done < <(service_list)
  return 0
}

# Rutas del servicio $1 que la foto de la copia elegida contiene: sus datos
# menos las cachés excluidas y, en R2, menos las "solo local" (esas las avisa
# _restore_service: esta función corre en un subshell).
_restore_service_paths() {
  local id="$1" p x skip
  local -a excl=() lonly=()
  while IFS= read -r x; do [[ -z "$x" ]] || excl+=("$x"); done < <(service_get "$id" BACKUP_EXCLUDE)
  while IFS= read -r x; do [[ -z "$x" ]] || lonly+=("$x"); done < <(service_get "$id" BACKUP_LOCAL_ONLY)
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    skip=0
    for x in "${excl[@]}"; do [[ "$x" == "$p" ]] && skip=1; done
    if [[ "$RS_SOURCE" == "r2" ]]; then
      for x in "${lonly[@]}"; do [[ "$x" == "$p" ]] && skip=1; done
    fi
    if [[ "$skip" -eq 0 ]]; then printf '%s\n' "$p"; fi
  done < <(service_get "$id" DATA)
  return 0
}

# --- Contenedores ----------------------------------------------------------------------------

# Detiene los contenedores de los servicios de la restauración (TODOS, no solo
# los de base de datos: se reemplaza su carpeta). Anota la lista de
# recuperación antes de detener nada. Los que no existen se registran en
# RS_MODULES (hay que desplegarlos con su módulo). Un estado de docker que no
# se puede confirmar corta la restauración: no se reemplaza una carpeta que
# quizá esté en uso.
_restore_stop_containers() {
  local id c rc presence
  local -a todo=() missing=()
  presence="$(hli_docker_presence)"
  if [[ "$presence" == "unknown" ]]; then
    _restore_msg_add "no se pudo confirmar el estado de Docker (¿sudo sin sesión?); no se restaura nada"
    return 1
  fi
  while read -r id; do
    [[ -n "$id" ]] || continue
    [[ "$(service_get "$id" KIND)" == "container" ]] || continue
    c="$(service_get "$id" CONTAINER)"
    if [[ "$presence" == "absent" ]]; then
      missing+=("$id")
      continue
    fi
    rc=0
    _backup_container_state "$c" || rc=$?
    case "$rc" in
      0) todo+=("$c") ;;
      1) ;;
      3) missing+=("$id") ;;
      *)
        _restore_msg_add "no se pudo consultar el estado de '$c'; no se restaura nada"
        return 1
        ;;
    esac
  done < <(_restore_target_services)

  # Para los contenedores, el id del servicio es también el nombre del módulo
  # que lo despliega (la copia root-owned no trae modules/, no se puede comprobar).
  for id in "${missing[@]}"; do RS_MODULES+="${RS_MODULES:+ }$id"; done
  if [[ "$presence" == "absent" ]]; then
    _restore_msg_add "Docker no está instalado: se restauran solo los datos"
    RS_MODULES="dokploy${RS_MODULES:+ }$RS_MODULES"
  fi

  if [[ ${#todo[@]} -gt 0 ]]; then
    _backup_recovery_write "${todo[@]}" || { hli_error "no se pudo guardar la lista de recuperación"; return 1; }
  fi
  for c in "${todo[@]}"; do
    BACKUP_STOPPED_CONTAINERS+="$c "
    _backup_log "Deteniendo '$c' para restaurar sus datos"
    if ! hli_docker stop -t "$BACKUP_STOP_TIMEOUT" "$c" >/dev/null 2>&1 </dev/null; then
      _restore_msg_add "no se pudo detener '$c'; no se restaura nada"
      return 1
    fi
  done
  return 0
}

# --- Carpeta de paso e intercambio -------------------------------------------------------------

# Restaura la ruta $1 de la foto en su carpeta de paso. 0 = restaurada (queda en
# <paso><ruta>); 2 = la foto no la contiene; 1 = error.
_restore_stage_path() {
  local p="$1" stage rc=0
  stage="$p$RESTORE_STAGE_SUFFIX"
  _restore_path_ok "$p" || { hli_error "ruta de datos no válida: $p"; return 1; }
  RS_STAGES+=("$stage")
  _restore_priv rm -rf -- "$stage" || return 1
  _restore_priv mkdir -p -- "$(dirname -- "$p")" "$stage" || return 1
  _backup_log "Restaurando $p en la carpeta de paso"
  _restore_restic restore "$RS_RID" --target "$stage" --include "$p" </dev/null || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    hli_error "restic no pudo restaurar $p (código $rc)"
    return 1
  fi
  if ! _restore_exists "$stage$p"; then
    _backup_log "La foto no contiene $p"
    return 2
  fi
  return 0
}

_restore_stage_drop() {
  local s
  for s in "$@"; do
    _restore_priv rm -rf -- "$s" || true
  done
}

# Intercambia $1 (ya restaurado en la carpeta de paso) por $2 (destino): lo
# actual pasa a <destino>.hli2-before-restore-<fecha> y lo restaurado ocupa su
# lugar. Anota lo hecho en RS_SW_* para poder deshacerlo.
_restore_swap_one() {
  local src="$1" dst="$2" old had=0
  old="$dst$RESTORE_OLD_SUFFIX-$RS_TS"
  _restore_signals_ignore
  if _restore_exists "$dst"; then
    if ! _restore_priv mv -T -- "$dst" "$old"; then
      _restore_signals_restore
      hli_error "no se pudo apartar $dst"
      return 1
    fi
    had=1
  fi
  if ! _restore_priv mv -T -- "$src" "$dst"; then
    if [[ "$had" -eq 1 ]]; then
      _restore_priv mv -T -- "$old" "$dst" || hli_error "no se pudo devolver $dst a su lugar; lo anterior está en $old"
    fi
    _restore_signals_restore
    hli_error "no se pudo colocar lo restaurado en $dst"
    return 1
  fi
  _restore_signals_restore
  RS_SW_DST+=("$dst") RS_SW_OLD+=("$old") RS_SW_HAD+=("$had")
  return 0
}

# Deshace los intercambios de RS_SW_* (de atrás hacia adelante).
_restore_undo_swaps() {
  local i
  for (( i = ${#RS_SW_DST[@]} - 1; i >= 0; i-- )); do
    _restore_signals_ignore
    _restore_priv rm -rf -- "${RS_SW_DST[$i]}" || true
    if [[ "${RS_SW_HAD[$i]}" == "1" ]]; then
      _restore_priv mv -T -- "${RS_SW_OLD[$i]}" "${RS_SW_DST[$i]}" \
        || hli_error "no se pudo devolver ${RS_SW_DST[$i]} a su lugar; lo anterior está en ${RS_SW_OLD[$i]}"
    fi
    _restore_signals_restore
  done
  RS_SW_DST=() RS_SW_OLD=() RS_SW_HAD=()
}

# Pasa los intercambios del servicio en curso a la lista de copias conservadas.
_restore_swaps_commit() {
  local i
  for (( i = 0; i < ${#RS_SW_DST[@]}; i++ )); do
    if [[ "${RS_SW_HAD[$i]}" == "1" ]]; then
      RS_KEPT_DST+=("${RS_SW_DST[$i]}") RS_KEPT_OLD+=("${RS_SW_OLD[$i]}")
    fi
  done
  RS_SW_DST=() RS_SW_OLD=() RS_SW_HAD=()
}

# Restaura todas las rutas del servicio $1. 0 = hecho; 1 = error (nada
# cambió); 3 = la foto no tiene ningún dato de este servicio.
_restore_service() {
  local id="$1" p rc
  local -a paths=() staged=()
  while IFS= read -r p; do
    [[ -z "$p" ]] || paths+=("$p")
  done < <(_restore_service_paths "$id")
  if [[ "$RS_SOURCE" == "r2" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      _restore_worse warning
      _restore_msg_add "no se restauró $p: solo existe en la copia local, no en la externa (lo actual no se toca)"
    done < <(service_get "$id" BACKUP_LOCAL_ONLY)
  fi
  [[ ${#paths[@]} -gt 0 ]] || return 3

  for p in "${paths[@]}"; do
    rc=0
    _restore_stage_path "$p" || rc=$?
    case "$rc" in
      0) staged+=("$p") ;;
      2)
        _restore_worse warning
        _restore_msg_add "la foto no contiene $p (se deja como está)"
        ;;
      *)
        for p in "${paths[@]}"; do _restore_stage_drop "$p$RESTORE_STAGE_SUFFIX"; done
        return 1
        ;;
    esac
  done
  [[ ${#staged[@]} -gt 0 ]] || return 3

  RS_SW_DST=() RS_SW_OLD=() RS_SW_HAD=()
  for p in "${staged[@]}"; do
    if ! _restore_swap_one "$p$RESTORE_STAGE_SUFFIX$p" "$p"; then
      _restore_undo_swaps
      for p in "${paths[@]}"; do _restore_stage_drop "$p$RESTORE_STAGE_SUFFIX"; done
      return 1
    fi
  done
  _restore_swaps_commit
  for p in "${paths[@]}"; do _restore_stage_drop "$p$RESTORE_STAGE_SUFFIX"; done
  return 0
}

# Archivos .env de /etc/hli2 (solo 'todo'): uno por uno, atómicos y con copia
# previa. Se salta restic.env (salvo --with-restic-env), dokploy.env y todo lo
# que no sea un '<servicio>.env' regular. La contraseña de restic no viaja en
# los backups y nunca se toca.
_restore_secrets() {
  local stage="$SECRETS_DIR$RESTORE_STAGE_SUFFIX" dir f name n=0 rc=0
  local -a files=()
  _restore_stage_path "$SECRETS_DIR" || rc=$?
  case "$rc" in
    0) ;;
    2) _restore_worse warning; _restore_msg_add "la foto no contiene $SECRETS_DIR"; return 0 ;;
    *) return 1 ;;
  esac
  dir="$stage$SECRETS_DIR"
  while IFS= read -r f; do
    [[ -z "$f" ]] || files+=("$f")
  done < <(_restore_priv find "$dir" -maxdepth 1 -type f -print 2>/dev/null)

  RS_SW_DST=() RS_SW_OLD=() RS_SW_HAD=()
  for f in "${files[@]}"; do
    name="$(basename -- "$f")"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*\.env$ ]] || continue
    case "$name" in
      dokploy.env) _backup_log "Se conserva $name del sistema actual"; continue ;;
      restic.env)
        if [[ "$RS_WITH_RESTIC_ENV" -ne 1 ]]; then
          _backup_log "Se conserva restic.env del sistema actual"
          continue
        fi
        ;;
    esac
    if ! _restore_swap_one "$f" "$SECRETS_DIR/$name"; then
      _restore_undo_swaps
      _restore_stage_drop "$stage"
      return 1
    fi
    n=$(( n + 1 ))
  done
  _restore_swaps_commit
  _restore_stage_drop "$stage"
  _backup_log "Secretos restaurados: $n archivo(s) en $SECRETS_DIR"
  return 0
}

# Copias previas '<ruta>.hli2-before-restore-*' de $1 (una por línea).
_restore_old_copies() {
  local p="$1"
  _restore_priv find "$(dirname -- "$p")" -maxdepth 1 -name "$(basename -- "$p")$RESTORE_OLD_SUFFIX-*" -print 2>/dev/null || true
}

# Al terminar bien: de cada ruta se conserva solo la última copia previa (la de
# esta corrida); con --discard-old, ninguna.
_restore_prune_old() {
  local i o kept=""
  for (( i = 0; i < ${#RS_KEPT_DST[@]}; i++ )); do
    while IFS= read -r o; do
      [[ -n "$o" ]] || continue
      if [[ "$o" != "${RS_KEPT_OLD[$i]}" || "$RS_DISCARD" -eq 1 ]]; then
        _restore_priv rm -rf -- "$o" || true
      fi
    done < <(_restore_old_copies "${RS_KEPT_DST[$i]}")
    if [[ "$RS_DISCARD" -ne 1 ]]; then kept+="${kept:+, }${RS_KEPT_OLD[$i]}"; fi
  done
  if [[ -n "$kept" ]]; then
    _restore_msg_add "se conservó lo anterior en: $kept (bórrelo con 'sudo rm -rf' cuando confirme que todo está bien)"
  fi
  return 0
}

# --- Salida y entrada principal ---------------------------------------------------------------

# Trap EXIT de la restauración: lo detenido SIEMPRE se levanta, las carpetas de
# paso se borran y una corrida cortada deja 'interrupted'. Lo primero es ignorar
# nuevas señales (una segunda no puede abortar el reinicio).
restore_exit_cleanup() {
  trap '' INT TERM HUP
  local rc=0 s
  backup_restart_stopped || rc=1
  for s in "${RS_STAGES[@]}"; do _restore_priv rm -rf -- "$s" || true; done
  RS_STAGES=()
  if [[ "$RS_ACTIVE" == "1" ]]; then
    RS_RESULT=interrupted
    _restore_msg_add "la restauración se interrumpió antes de terminar (lo actual no se modificó, salvo servicios ya completados)"
    [[ "$rc" -eq 0 ]] || _restore_msg_add "algún contenedor no volvió a iniciar (revise el log)"
    _restore_status_write || true
    RS_ACTIVE=0
  fi
  _BK_R2_REPO="" _BK_R2_KEY="" _BK_R2_SECRET="" _BK_R2_REGION=""
  return 0
}

_restore_finish() {
  local s
  if ! backup_restart_stopped; then
    _restore_worse error
    _restore_msg_add "algún contenedor no volvió a iniciar (revise el log)"
  fi
  for s in "${RS_STAGES[@]}"; do _restore_priv rm -rf -- "$s" || true; done
  RS_STAGES=()
  _restore_status_write || true
  RS_ACTIVE=0
  _backup_log "Fin de la restauración: $RS_RESULT${RS_MSG:+ ($RS_MSG)}"
  [[ "$RS_RESULT" != "error" ]]
}

# La restauración completa (argumentos ya validados por restore_parse_args).
restore_run() {
  local id unit rc nres=0
  local -a restored_native=() services=()
  umask 022   # carpetas padre creadas por nosotros: legibles para los contenedores
  RS_ACTIVE=1 RS_RESULT=running RS_MSG="" RS_MODULES="" RS_STIME="" RS_TS="$(date +%Y%m%d-%H%M%S)"
  RS_KEPT_DST=() RS_KEPT_OLD=() RS_STAGES=()
  _restore_status_write || true
  RS_RESULT=ok
  _backup_log "Inicio de la restauración: origen=$RS_SOURCE foto=$RS_SNAPSHOT destino=$RS_TARGET"

  if ! backup_recover; then
    _restore_worse warning
    _restore_msg_add "quedaron contenedores sin iniciar de una corrida anterior"
  fi

  if ! _restore_open_repo || ! _restore_resolve_snapshot; then
    RS_RESULT=error
    _backup_log "ERROR: $RS_MSG"
    _restore_finish || true
    return 1
  fi
  _backup_log "Foto $RS_RID ($(restore_fmt_time "$RS_STIME"))"

  if ! _restore_stop_containers; then
    RS_RESULT=error
    _backup_log "ERROR: $RS_MSG"
    _restore_finish || true
    return 1
  fi

  mapfile -t services < <(_restore_target_services)
  for id in "${services[@]}"; do
    [[ -n "$id" ]] || continue
    rc=0
    _restore_service "$id" || rc=$?
    case "$rc" in
      0)
        nres=$(( nres + 1 ))
        if [[ "$(service_get "$id" KIND)" == "native" ]]; then restored_native+=("$id"); fi
        ;;
      3)
        if [[ "$RS_TARGET" == "all" ]]; then
          _backup_log "La foto no contiene datos de '$id'"
        else
          _restore_worse error
          _restore_msg_add "la foto no contiene datos de '$id'"
        fi
        ;;
      *)
        _restore_worse error
        _restore_msg_add "falló la restauración de '$id'; lo actual quedó como estaba"
        break
        ;;
    esac
  done

  if [[ "$RS_RESULT" != "error" && "$RS_TARGET" == "all" ]]; then
    if _restore_secrets; then
      nres=$(( nres + 1 ))
    else
      _restore_worse error
      _restore_msg_add "falló la restauración de $SECRETS_DIR; lo actual quedó como estaba"
    fi
  fi

  # Servicios nativos: recargan su configuración restaurada.
  for id in "${restored_native[@]}"; do
    unit="$(service_get "$id" UNIT)"
    [[ "$unit" =~ ^[A-Za-z0-9@._-]+$ ]] || continue
    _backup_log "Reiniciando la unidad '$unit'"
    if ! _restore_priv systemctl try-restart "$unit"; then
      _restore_worse warning
      _restore_msg_add "no se pudo reiniciar la unidad '$unit' (¿no está instalada?)"
      if [[ "$id" == "smbd" ]]; then RS_MODULES+="${RS_MODULES:+ }samba"; fi
    fi
  done

  if [[ "$RS_RESULT" != "error" ]]; then
    _restore_prune_old
    [[ "$nres" -gt 0 ]] || { _restore_worse warning; _restore_msg_add "no se restauró nada"; }
  fi
  if [[ -n "$RS_MODULES" ]]; then
    _restore_worse warning
    _restore_msg_add "faltan contenedores: ejecute los módulos indicados para desplegarlos"
  fi
  _restore_finish
}
