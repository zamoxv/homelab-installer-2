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
#   2. Con espacio libre suficiente (estimado con 'du' de lo actual, o con
#      'restic stats' si la ruta no existe todavía), cada ruta se restaura
#      PRIMERO en una carpeta de paso vecina (<ruta>.hli2-restore-tmp, mismo
#      sistema de archivos) con los contenedores AÚN en marcha:
#      'restic restore --target <paso> --include <ruta>' recrea la ruta absoluta
#      dentro de <paso>, con dueños y modos de la foto (como root). La carpeta de
#      paso se crea con 'mkdir' (sin -p) y se comprueba que no es un enlace y es
#      de root; antes se rechazan enlaces simbólicos en la ruta o en su padre.
#   3. Recién con todo restaurado en pasos se detienen los contenedores afectados
#      (lista de recuperación primero, como en el backup; siempre se vuelven a
#      iniciar, también ante señales).
#   4. Cada servicio se intercambia con las señales ignoradas de principio a fin:
#      lo actual pasa a <ruta>.hli2-before-restore-<fecha> (un 'mv', atómico) y
#      lo restaurado ocupa su lugar. Antes se anota un diario en el estado de root
#      (restore-swap-journal): si el equipo se cae a medias, 'hli2-backup recover'
#      (o el siguiente run/restore) lo DESHACE ANTES de iniciar ningún contenedor
#      (si no, Docker crearía una carpeta vacía y el servicio arrancaría sin
#      datos). Si falla un intercambio, o el proceso aborta con 'set -e', se
#      deshace todo el servicio. Es un reemplazo, no una mezcla.
#   5. Copias previas: las de corridas exitosas se registran en
#      restore-old-copies (estado de root). Se conservan la MÁS VIEJA (el estado
#      anterior a las restauraciones) y la más nueva de cada ruta; las del medio
#      se borran. Nunca se borra nada de una corrida que terminó en error ni si la
#      restauración anterior quedó interrumpida. --discard-old (el módulo lo pasa
#      solo si acaba de hacer un backup de seguridad verificado) las borra todas.
#      Las copias de los .env de /etc/hli2 se guardan FUERA de /etc/hli2 pero en el
#      mismo sistema de archivos (/etc/hli2-old-secrets, 0700): así el 'mv' es un
#      renombrado atómico y los secretos viejos no entran en los backups.
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
RS_PLAN_DST=() RS_PLAN_OLD=() RS_PLAN_HAD=()   # intercambio planeado del servicio en curso
RS_SW_DST=() RS_SW_OLD=() RS_SW_HAD=()   # intercambios ya hechos del servicio en curso
RS_KEPT_DST=() RS_KEPT_OLD=()      # copias previas creadas por esta corrida
RS_PLAN_CONTAINERS=()              # contenedores a detener
RS_SECRET_FILES=()                 # .env de /etc/hli2 ya en carpeta de paso
RS_DONE=""                         # servicios ya restaurados (para los mensajes)
RS_PREV_RESULT=""                  # resultado de la restauración anterior
RS_REVERTED=0                      # 1 si el estado es el de una restauración revertida por la recuperación
RS_JOURNAL_FAILED=0                # 1 si la recuperación no pudo deshacer un intercambio
RS_JOURNAL_REVERTED=""             # rutas que la recuperación devolvió a su lugar
declare -A RS_STAGED=()            # servicio -> rutas en carpeta de paso (una por línea)

RESTORE_JOURNAL="$BACKUP_STATE_DIR/restore-swap-journal"
RESTORE_OLD_REGISTRY="$BACKUP_STATE_DIR/restore-old-copies"
# Junto a /etc/hli2 (mismo sistema de archivos: el 'mv' es un renombrado, nunca una
# copia a medias) y fuera de él (no entra en los backups, que respaldan /etc/hli2).
RESTORE_OLD_SECRETS_DIR="${SECRETS_DIR}-old-secrets"
RESTORE_OLD_TS_RE='[0-9]{8}-[0-9]{6}'
RESTORE_JOURNAL_FAILED="$BACKUP_STATE_DIR/restore-swap-journal.failed"
RESTORE_SPACE_MARGIN_PCT=10
RESTORE_SPACE_MARGIN_BYTES=67108864

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

_restore_signals_ignore() { trap '' INT TERM HUP PIPE; }
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

# Escribe el estado con los valores dados (resultado, origen, foto, fecha de la foto,
# destino, módulos, mensaje, revertida). 0644, sin secretos.
_restore_status_write_raw() {
  local tmp
  tmp="$(mktemp "$BACKUP_STATE_DIR/.rstatus.XXXXXX")" || return 1
  {
    printf 'timestamp=%s\n' "$(date -Is)"
    printf 'result=%s\n' "$1"
    printf 'source=%s\n' "$2"
    printf 'snapshot=%s\n' "$3"
    printf 'snapshot_time=%s\n' "$4"
    printf 'target=%s\n' "$5"
    printf 'modules=%s\n' "$6"
    printf 'message=%s\n' "${7//$'\n'/ }"
    printf 'reverted=%s\n' "$8"
  } > "$tmp"
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$RESTORE_STATUS_FILE"
}

_restore_status_write() {
  _restore_status_write_raw "$RS_RESULT" "$RS_SOURCE" "$RS_SNAPSHOT" "$RS_STIME" "$RS_TARGET" "$RS_MODULES" "$RS_MSG" "$RS_REVERTED"
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
  [[ "$(restore_status_get reverted)" != "1" ]] || printf '  AVISO        : la última restauración se revirtió (quedó a medias); lo anterior volvió a su lugar\n'

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
# _restore_service_stage: esta función corre en un subshell).
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

# --- Seguridad de rutas -------------------------------------------------------------------------

# Rechaza lo que un enlace simbólico podría desviar: una ruta de datos que sea un
# enlace (p. ej. un disco extra enlazado), un padre que sea o pase por un enlace
# (su 'realpath' tiene que ser él mismo) o una carpeta de paso que ya sea un
# enlace. El motivo queda en RS_MSG.
_restore_path_guard() {
  local p="$1" parent real
  if ! _restore_path_ok "$p"; then
    _restore_msg_add "ruta de datos no válida: $p"
    return 1
  fi
  parent="$(dirname -- "$p")"
  real="$(realpath -m -- "$parent")" || real=""
  if [[ "$real" != "$parent" ]]; then
    _restore_msg_add "la carpeta $parent es un enlace simbólico o pasa por uno (apunta a $real): no se restaura"
    return 1
  fi
  if _restore_priv test -L "$p"; then
    _restore_msg_add "$p es un enlace simbólico (¿datos en otro disco?): no se restaura"
    return 1
  fi
  if _restore_priv test -L "$p$RESTORE_STAGE_SUFFIX"; then
    _restore_msg_add "$p$RESTORE_STAGE_SUFFIX es un enlace simbólico: bórrelo a mano y reintente"
    return 1
  fi
  return 0
}

# Crea la carpeta de paso de $1 de forma segura: se borra la que haya dejado una
# corrida interrumpida (solo si es una carpeta normal, nunca un enlace), se crea
# con 'mkdir' SIN -p (falla si apareció algo) y se comprueba enseguida que no es
# un enlace y que es del usuario que corre (root).
_restore_stage_prepare() {
  local p="$1" stage owner
  stage="$p$RESTORE_STAGE_SUFFIX"
  if _restore_exists "$stage"; then
    if _restore_priv test -L "$stage" || ! _restore_priv test -d "$stage"; then
      _restore_msg_add "$stage no es una carpeta normal: bórrela a mano y reintente"
      return 1
    fi
    _restore_priv rm -rf -- "$stage" || return 1
  fi
  _restore_priv mkdir -p -- "$(dirname -- "$p")" || return 1
  _restore_priv mkdir -- "$stage" || { _restore_msg_add "no se pudo crear $stage"; return 1; }
  RS_STAGES+=("$stage")
  if _restore_priv test -L "$stage" || ! _restore_priv test -d "$stage"; then
    _restore_msg_add "$stage no es una carpeta normal"
    return 1
  fi
  owner="$(_restore_priv stat -c '%u' -- "$stage")" || return 1
  if [[ "$owner" != "$(id -u)" ]]; then
    _restore_msg_add "$stage no es del usuario que restaura (dueño $owner)"
    return 1
  fi
  return 0
}

# --- Espacio libre -------------------------------------------------------------------------------

# Bytes libres del sistema de archivos que contiene $1 (o su ancestro existente).
_restore_free_bytes() {
  local p="$1"
  while [[ ! -e "$p" && "$p" != "/" ]]; do p="$(dirname -- "$p")"; done
  df -B1 --output=avail -- "$p" 2>/dev/null | tail -n1 | tr -d ' '
}

# Punto de montaje del sistema de archivos que contiene $1 (clave de agrupación).
_restore_fs_key() {
  local p="$1"
  while [[ ! -e "$p" && "$p" != "/" ]]; do p="$(dirname -- "$p")"; done
  df --output=target -- "$p" 2>/dev/null | tail -n1
}

# Comprueba, ANTES de restaurar nada, que cada sistema de archivos tiene lugar
# para las carpetas de paso (lo actual se aparta con 'mv': no consume espacio). La
# estimación es el 'du' de lo que hay ahora (la foto es parecida); si alguna ruta
# no existe todavía (equipo nuevo) se usa el tamaño total de la foto
# ('restic stats --mode restore-size', una cota superior) para ese sistema de
# archivos. Margen: 10 % + 64 MiB. Recibe las rutas como argumentos.
_restore_space_preflight() {
  local p key sz stats total req avail unknown=0
  local -A need=() unk=()
  for p in "$@"; do
    key="$(_restore_fs_key "$p")"
    [[ -n "$key" ]] || key="/"
    if _restore_exists "$p"; then
      sz="$(du -sb -- "$p" 2>/dev/null | cut -f1)" || sz=""
      [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
      need[$key]=$(( ${need[$key]:-0} + sz ))
    else
      need[$key]=$(( ${need[$key]:-0} ))
      unk[$key]=1
      unknown=1
    fi
  done
  if [[ "$unknown" -eq 1 ]]; then
    stats="$(_restore_restic stats --mode restore-size --json "$RS_RID" 2>/dev/null </dev/null)" || stats=""
    total="$(printf '%s' "$stats" | jq -r '.total_size // empty' 2>/dev/null)" || total=""
    if [[ "$total" =~ ^[0-9]+$ ]]; then
      for key in "${!unk[@]}"; do need[$key]=$(( ${need[$key]} + total )); done
    else
      _restore_worse warning
      _restore_msg_add "no se pudo estimar el tamaño de la foto: no se comprobó el espacio libre"
    fi
  fi
  for key in "${!need[@]}"; do
    req=$(( need[$key] + need[$key] * RESTORE_SPACE_MARGIN_PCT / 100 + RESTORE_SPACE_MARGIN_BYTES ))
    avail="$(_restore_free_bytes "$key")"
    [[ "$avail" =~ ^[0-9]+$ ]] || continue
    if (( avail < req )); then
      _restore_msg_add "espacio insuficiente en $key: se necesitan unos $(( req / 1048576 )) MiB y hay $(( avail / 1048576 )) MiB libres; no se restaura nada"
      return 1
    fi
  done
  return 0
}

# --- Contenedores ----------------------------------------------------------------------------

# Consulta (sin detener nada) qué contenedores de los servicios de la restauración
# hay que detener. Deja RS_PLAN_CONTAINERS y anota en RS_MODULES los servicios cuyo
# contenedor no existe (hay que desplegarlos con su módulo). Un estado de Docker que
# no se puede confirmar corta la restauración: no se reemplaza una carpeta que
# quizá esté en uso.
_restore_containers_plan() {
  local id c rc presence
  local -a missing=()
  RS_PLAN_CONTAINERS=()
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
      0) RS_PLAN_CONTAINERS+=("$c") ;;
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
  return 0
}

# Detiene los contenedores de RS_PLAN_CONTAINERS (TODOS los del servicio, no solo
# los de base de datos: se reemplaza su carpeta). Anota la lista de recuperación
# antes de detener nada y deja todos en BACKUP_STOPPED_CONTAINERS de entrada: si
# llega una señal a medias, el cleanup intenta levantarlos a todos.
_restore_containers_stop() {
  local c
  [[ ${#RS_PLAN_CONTAINERS[@]} -gt 0 ]] || return 0
  _backup_recovery_write "${RS_PLAN_CONTAINERS[@]}" || { hli_error "no se pudo guardar la lista de recuperación"; return 1; }
  for c in "${RS_PLAN_CONTAINERS[@]}"; do BACKUP_STOPPED_CONTAINERS+="$c "; done
  for c in "${RS_PLAN_CONTAINERS[@]}"; do
    _backup_log "Deteniendo '$c' para restaurar sus datos"
    if ! hli_docker stop -t "$BACKUP_STOP_TIMEOUT" "$c" >/dev/null 2>&1 </dev/null; then
      _restore_msg_add "no se pudo detener '$c'; no se restaura nada"
      return 1
    fi
  done
  return 0
}

# --- Fase 1: restaurar en carpetas de paso (contenedores en marcha) --------------------------

# Restaura la ruta $1 de la foto en su carpeta de paso. 0 = restaurada (queda en
# <paso><ruta>); 2 = la foto no la contiene; 1 = error.
_restore_stage_path() {
  local p="$1" stage rc=0
  stage="$p$RESTORE_STAGE_SUFFIX"
  _restore_path_guard "$p" || return 1
  _restore_stage_prepare "$p" || return 1
  _backup_log "Restaurando $p en la carpeta de paso"
  _restore_restic restore "$RS_RID" --target "$stage" --include "$p" </dev/null || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    hli_error "restic no pudo restaurar $p (código $rc)"
    _restore_msg_add "restic no pudo restaurar $p (código $rc)"
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

_restore_stage_drop_all() {
  _restore_stage_drop "${RS_STAGES[@]}"
  RS_STAGES=()
  RS_STAGED=()
  RS_SECRET_FILES=()
}

# Valida una smb.conf ya restaurada en la carpeta de paso con 'testparm' (si está
# instalado): una configuración rota dejaría a Samba caído.
_restore_validate_staged() {
  local f="$1"
  [[ "$(basename -- "$f")" == "smb.conf" ]] || return 0
  if ! command -v testparm >/dev/null 2>&1; then
    _backup_log "testparm no está instalado: no se valida la configuración de Samba"
    return 0
  fi
  testparm -s -- "$f" >/dev/null 2>&1 </dev/null
}

# Fase 1 de un servicio: restaura todas sus rutas en carpetas de paso. 0 = listo
# (RS_STAGED[$id]); 1 = error (RS_MSG); 3 = la foto no tiene datos de este servicio;
# 4 = todos sus datos son "solo local" y el origen es R2.
_restore_service_stage() {
  local id="$1" p rc has_lonly=0
  local -a paths=() staged=()
  while IFS= read -r p; do
    [[ -z "$p" ]] || paths+=("$p")
  done < <(_restore_service_paths "$id")
  if [[ "$RS_SOURCE" == "r2" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      has_lonly=1
      _restore_worse warning
      _restore_msg_add "no se restauró $p: solo existe en la copia local, no en la externa (lo actual no se toca)"
    done < <(service_get "$id" BACKUP_LOCAL_ONLY)
  fi
  if [[ ${#paths[@]} -eq 0 ]]; then
    [[ "$has_lonly" -eq 1 ]] && return 4
    return 3
  fi

  for p in "${paths[@]}"; do
    rc=0
    _restore_stage_path "$p" || rc=$?
    case "$rc" in
      0) staged+=("$p") ;;
      2)
        _restore_worse warning
        _restore_msg_add "la foto no contiene $p (se deja como está)"
        ;;
      *) return 1 ;;
    esac
  done
  [[ ${#staged[@]} -gt 0 ]] || return 3

  for p in "${staged[@]}"; do
    if ! _restore_validate_staged "$p$RESTORE_STAGE_SUFFIX$p"; then
      _restore_msg_add "la configuración de Samba de la foto no es válida (testparm): no se restaura $p"
      return 1
    fi
  done
  RS_STAGED[$id]="$(printf '%s\n' "${staged[@]}")"
  return 0
}

# Prepara la carpeta de copias previas de los .env: junto a /etc/hli2, en su mismo
# sistema de archivos (así el 'mv' es un renombrado atómico: nunca una copia a medias
# que luego se tome por completa), root 0700, no un enlace. Si no cumple, no se
# restauran secretos (se comprueba en la fase 1, antes de detener ni cambiar nada).
_restore_secrets_old_dir_prepare() {
  if _restore_priv test -L "$RESTORE_OLD_SECRETS_DIR"; then
    _restore_msg_add "$RESTORE_OLD_SECRETS_DIR es un enlace simbólico: no se restauran los secretos"
    return 1
  fi
  _restore_priv install -d -m 0700 "$RESTORE_OLD_SECRETS_DIR" || return 1
  if ! _restore_same_fs "$RESTORE_OLD_SECRETS_DIR" "$SECRETS_DIR"; then
    _restore_msg_add "$RESTORE_OLD_SECRETS_DIR no está en el mismo sistema de archivos que $SECRETS_DIR: no se restauran los secretos"
    return 1
  fi
  return 0
}

# Fase 1 de /etc/hli2 (solo 'todo'): deja en RS_SECRET_FILES los '<servicio>.env'
# restaurados en la carpeta de paso. Se salta restic.env (salvo --with-restic-env),
# dokploy.env y todo lo que no sea un '<servicio>.env' regular. La contraseña de
# restic no viaja en los backups y nunca se toca. 0 = listo (puede ser vacío);
# 2 = la foto no contiene /etc/hli2; 1 = error.
_restore_secrets_stage() {
  local dir f name rc=0
  local -a files=()
  RS_SECRET_FILES=()
  _restore_stage_path "$SECRETS_DIR" || rc=$?
  case "$rc" in
    0) ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
  dir="$SECRETS_DIR$RESTORE_STAGE_SUFFIX$SECRETS_DIR"
  while IFS= read -r f; do
    [[ -z "$f" ]] || files+=("$f")
  done < <(_restore_priv find "$dir" -maxdepth 1 -type f -print 2>/dev/null)
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
    RS_SECRET_FILES+=("$f")
  done
  if [[ ${#RS_SECRET_FILES[@]} -gt 0 ]]; then _restore_secrets_old_dir_prepare || return 1; fi
  return 0
}

# --- Fase 2: intercambio -----------------------------------------------------------------------

# ¿$1 y $2 están en el mismo sistema de archivos (mismo id de dispositivo)?
_restore_same_fs() {
  local a b
  a="$(_restore_priv stat -c %d -- "$1" 2>/dev/null)" || return 1
  b="$(_restore_priv stat -c %d -- "$2" 2>/dev/null)" || return 1
  [[ -n "$a" && "$a" == "$b" ]]
}

# 'sync' del archivo/sistema de archivos: el diario tiene que estar en disco ANTES
# del primer 'mv' (si se corta la luz con el diario en el caché, no habría nada que deshacer).
_restore_sync() {
  sync "$@" 2>/dev/null || true
}

# Diario del intercambio en curso (estado de root): una línea 'destino<TAB>copia<TAB>había'
# por ruta. Si el proceso muere a medias, restore_journal_recover lo deshace.
_restore_journal_write() {
  local tmp i
  tmp="$(mktemp "$BACKUP_STATE_DIR/.swap.XXXXXX")" || return 1
  for (( i = 0; i < ${#RS_PLAN_DST[@]}; i++ )); do
    printf '%s\t%s\t%s\n' "${RS_PLAN_DST[$i]}" "${RS_PLAN_OLD[$i]}" "${RS_PLAN_HAD[$i]}"
  done > "$tmp" || { rm -f "$tmp"; return 1; }
  # Duradero antes del primer 'mv': archivo, renombrado y entrada de directorio.
  _restore_sync -- "$tmp"
  mv -f -- "$tmp" "$RESTORE_JOURNAL" || return 1
  _restore_sync -f -- "$BACKUP_STATE_DIR"
}

_restore_journal_clear() {
  rm -f -- "$RESTORE_JOURNAL"
  _restore_sync -f -- "$BACKUP_STATE_DIR"
}

# ¿$1 es una ruta que una restauración puede tocar? Solo las rutas de datos del
# registro de servicios (de la copia root-owned) o '<SECRETS_DIR>/<servicio>.env'.
_restore_dst_allowed() {
  local dst="$1" id p name
  if [[ "$dst" == "$SECRETS_DIR/"* ]]; then
    name="${dst#"$SECRETS_DIR"/}"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*\.env$ ]]
    return
  fi
  while read -r id; do
    [[ -n "$id" ]] || continue
    while IFS= read -r p; do
      [[ "$p" == "$dst" ]] && return 0
    done < <(service_get "$id" DATA)
  done < <(service_list)
  return 1
}

# ¿$2 es exactamente el nombre de copia previa que esta biblioteca le da a $1?
# '<destino>.hli2-before-restore-<AAAAMMDD-HHMMSS>' o, para un .env,
# '<SECRETS_DIR>-old-secrets/<archivo>.hli2-before-restore-<AAAAMMDD-HHMMSS>'.
_restore_old_name_ok() {
  local dst="$1" old="$2" ts
  if [[ "$dst" == "$SECRETS_DIR/"* ]]; then
    [[ "$old" == "$RESTORE_OLD_SECRETS_DIR/$(basename -- "$dst")$RESTORE_OLD_SUFFIX-"* ]] || return 1
    ts="${old##*"$RESTORE_OLD_SUFFIX"-}"
  else
    [[ "$old" == "$dst$RESTORE_OLD_SUFFIX-"* ]] || return 1
    ts="${old#"$dst$RESTORE_OLD_SUFFIX"-}"
  fi
  [[ "$ts" =~ ^$RESTORE_OLD_TS_RE$ ]]
}

# Destino al que pertenece una copia previa ($1), o vacío si no tiene la forma esperada.
_restore_old_to_dst() {
  local old="$1" base name
  [[ "$old" =~ ^(.+)\.hli2-before-restore-$RESTORE_OLD_TS_RE$ ]] || return 1
  base="${BASH_REMATCH[1]}"
  if [[ "$base" == "$RESTORE_OLD_SECRETS_DIR/"* ]]; then
    printf '%s/%s' "$SECRETS_DIR" "${base#"$RESTORE_OLD_SECRETS_DIR"/}"
  else
    printf '%s' "$base"
  fi
}

# Deshace el intercambio que un proceso muerto dejó a medias (diario presente): para
# cada ruta, de atrás hacia adelante, devuelve lo apartado a su lugar. Corre ANTES
# de iniciar ningún contenedor (backup_recover y el servicio hli2-restore-journal lo
# llaman primero): sin esto, Docker crearía una carpeta vacía en el lugar que falta y
# el servicio arrancaría sin datos. Cada línea se valida antes de tocar nada: el
# destino tiene que estar en la lista del registro de servicios (o ser un .env de
# /etc/hli2) y la copia llamarse exactamente como la nombra esta biblioteca. Nunca se
# borra un destino si la copia previa no existe (un renombrado en el mismo sistema de
# archivos garantiza que, si existe, está completa).
#
# 0 = nada que hacer o deshecho (queda constancia en el estado de la restauración:
# 'interrumpida', 'revertida'); 1 = algún 'mv' falló: el diario se conserva como
# restore-swap-journal.failed (0600) y el estado queda en error con las rutas.
restore_journal_recover() {
  RS_JOURNAL_FAILED=0
  [[ -s "$RESTORE_JOURNAL" ]] || return 0
  local dst old had i failed="" reverted=""
  local -a D=() O=() H=()
  while IFS=$'\t' read -r dst old had; do
    if _restore_path_ok "$dst" && _restore_path_ok "$old" && [[ "$had" =~ ^[01]$ ]] \
       && _restore_dst_allowed "$dst" && _restore_old_name_ok "$dst" "$old"; then
      D+=("$dst") O+=("$old") H+=("$had")
    else
      _backup_log "Recuperación: línea inválida en el diario de restauración, se ignora"
    fi
  done < "$RESTORE_JOURNAL"
  _backup_log "Recuperación: se deshace una restauración que quedó a medias"
  for (( i = ${#D[@]} - 1; i >= 0; i-- )); do
    if [[ "${H[$i]}" == "1" ]]; then
      if _restore_exists "${O[$i]}"; then
        # Un .env con la copia en otro sistema de archivos no es un renombrado: no
        # se puede garantizar que esté completa.
        if [[ "${D[$i]}" == "$SECRETS_DIR/"* ]] && ! _restore_same_fs "$(dirname -- "${O[$i]}")" "$SECRETS_DIR"; then
          hli_error "la copia ${O[$i]} no está en el mismo sistema de archivos que $SECRETS_DIR: no se revierte ${D[$i]}"
          failed+="${failed:+, }${D[$i]}"
          continue
        fi
        if _restore_exists "${D[$i]}" && ! _restore_priv rm -rf -- "${D[$i]}"; then
          hli_error "no se pudo quitar ${D[$i]}; lo anterior sigue en ${O[$i]}"
          failed+="${failed:+, }${D[$i]}"
          continue
        fi
        if _restore_priv mv -T -- "${O[$i]}" "${D[$i]}"; then
          _backup_log "Recuperación: ${D[$i]} vuelve a su estado anterior"
          reverted+="${reverted:+, }${D[$i]}"
        else
          hli_error "no se pudo devolver ${D[$i]} a su lugar; lo anterior está en ${O[$i]}"
          failed+="${failed:+, }${D[$i]} (lo anterior en ${O[$i]})"
        fi
      fi
    elif _restore_exists "${D[$i]}"; then
      if _restore_priv rm -rf -- "${D[$i]}"; then
        reverted+="${reverted:+, }${D[$i]}"
      else
        failed+="${failed:+, }${D[$i]}"
      fi
    fi
  done
  if [[ -n "$failed" ]]; then
    mv -f -- "$RESTORE_JOURNAL" "$RESTORE_JOURNAL_FAILED" && chmod 0600 "$RESTORE_JOURNAL_FAILED" || true
    _restore_sync -f -- "$BACKUP_STATE_DIR"
    RS_JOURNAL_FAILED=1
    _restore_status_write_raw error "$(restore_status_get source)" "$(restore_status_get snapshot)" "$(restore_status_get snapshot_time)" \
      "$(restore_status_get target)" "" "no se pudo revertir una restauración interrumpida: $failed. El diario se conservó en $RESTORE_JOURNAL_FAILED: devuelva a mano cada carpeta desde su copia '.hli2-before-restore-*'" 0 || true
    return 1
  fi
  _restore_journal_clear
  RS_JOURNAL_REVERTED="$reverted"
  _restore_status_write_raw interrupted "$(restore_status_get source)" "$(restore_status_get snapshot)" "$(restore_status_get snapshot_time)" \
    "$(restore_status_get target)" "" "la restauración quedó a medias (corte de luz o proceso terminado) y se revirtió: ${reverted:-nada que devolver}" 1 || true
  return 0
}

# Subcomando 'journal-recover': solo deshace el intercambio interrumpido, SIN docker.
# Lo corre hli2-restore-journal.service antes de iniciar Docker, en el arranque.
restore_journal_recover_main() {
  restore_status_mark_stale || true
  restore_journal_recover
}

# Intercambia $1 (ya restaurado en la carpeta de paso) por $2 (destino): lo actual
# ($4=1 si existe) pasa a $3 y lo restaurado ocupa su lugar. Anota lo hecho en
# RS_SW_* para poder deshacerlo. Las señales las ignora el llamador (toda la fase).
_restore_swap_one() {
  local src="$1" dst="$2" old="$3" had="$4"
  trap '' PIPE
  if [[ "$had" == "1" ]]; then
    if ! _restore_priv mv -T -- "$dst" "$old"; then
      hli_error "no se pudo apartar $dst"
      return 1
    fi
  fi
  if ! _restore_priv mv -T -- "$src" "$dst"; then
    if [[ "$had" == "1" ]]; then
      _restore_priv mv -T -- "$old" "$dst" || hli_error "no se pudo devolver $dst a su lugar; lo anterior está en $old"
    fi
    hli_error "no se pudo colocar lo restaurado en $dst"
    return 1
  fi
  RS_SW_DST+=("$dst") RS_SW_OLD+=("$old") RS_SW_HAD+=("$had")
  return 0
}

# Deshace los intercambios de RS_SW_* (de atrás hacia adelante). El llamador ya
# tiene las señales ignoradas.
_restore_undo_swaps() {
  local i
  for (( i = ${#RS_SW_DST[@]} - 1; i >= 0; i-- )); do
    _restore_priv rm -rf -- "${RS_SW_DST[$i]}" || true
    if [[ "${RS_SW_HAD[$i]}" == "1" ]]; then
      _restore_priv mv -T -- "${RS_SW_OLD[$i]}" "${RS_SW_DST[$i]}" \
        || hli_error "no se pudo devolver ${RS_SW_DST[$i]} a su lugar; lo anterior está en ${RS_SW_OLD[$i]}"
    fi
  done
  RS_SW_DST=() RS_SW_OLD=() RS_SW_HAD=()
}

# Pasa los intercambios del servicio en curso a la lista de copias creadas.
_restore_swaps_commit() {
  local i
  for (( i = 0; i < ${#RS_SW_DST[@]}; i++ )); do
    if [[ "${RS_SW_HAD[$i]}" == "1" ]]; then
      RS_KEPT_DST+=("${RS_SW_DST[$i]}") RS_KEPT_OLD+=("${RS_SW_OLD[$i]}")
    fi
  done
  RS_SW_DST=() RS_SW_OLD=() RS_SW_HAD=()
}

# Ejecuta el intercambio planeado en RS_PLAN_* con $1.. = rutas de origen (carpeta
# de paso) en el mismo orden. Diario antes; señales ignoradas de principio a fin;
# ante un fallo se deshace todo. 0 = hecho; 1 = error (nada cambió).
_restore_swap_plan() {
  local i
  local -a srcs=("$@")
  RS_SW_DST=() RS_SW_OLD=() RS_SW_HAD=()
  _restore_journal_write || { hli_error "no se pudo escribir el diario de la restauración"; return 1; }
  _restore_signals_ignore
  for (( i = 0; i < ${#RS_PLAN_DST[@]}; i++ )); do
    if ! _restore_swap_one "${srcs[$i]}" "${RS_PLAN_DST[$i]}" "${RS_PLAN_OLD[$i]}" "${RS_PLAN_HAD[$i]}"; then
      _restore_undo_swaps
      _restore_journal_clear
      _restore_signals_restore
      return 1
    fi
  done
  _restore_journal_clear
  _restore_swaps_commit
  _restore_signals_restore
  return 0
}

# Fase 2 de un servicio: intercambia sus rutas en carpeta de paso.
_restore_service_swap() {
  local id="$1" p had
  local -a staged=() srcs=()
  RS_PLAN_DST=() RS_PLAN_OLD=() RS_PLAN_HAD=()
  while IFS= read -r p; do
    [[ -z "$p" ]] || staged+=("$p")
  done <<<"${RS_STAGED[$id]:-}"
  for p in "${staged[@]}"; do
    _restore_path_guard "$p" || return 1
    had=0
    if _restore_exists "$p"; then had=1; fi
    RS_PLAN_DST+=("$p") RS_PLAN_OLD+=("$p$RESTORE_OLD_SUFFIX-$RS_TS") RS_PLAN_HAD+=("$had")
    srcs+=("$p$RESTORE_STAGE_SUFFIX$p")
  done
  _restore_swap_plan "${srcs[@]}"
}

# Fase 2 de /etc/hli2: uno por uno dentro de un solo diario. Las copias previas
# van FUERA de /etc/hli2 (/etc/hli2-old-secrets, 0700, mismo sistema de archivos) para que los secretos viejos
# no entren en los backups.
_restore_secrets_swap() {
  local f name dst had
  local -a srcs=()
  RS_PLAN_DST=() RS_PLAN_OLD=() RS_PLAN_HAD=()
  [[ ${#RS_SECRET_FILES[@]} -gt 0 ]] || return 0
  for f in "${RS_SECRET_FILES[@]}"; do
    name="$(basename -- "$f")"
    dst="$SECRETS_DIR/$name"
    had=0
    if _restore_exists "$dst"; then had=1; fi
    RS_PLAN_DST+=("$dst") RS_PLAN_OLD+=("$RESTORE_OLD_SECRETS_DIR/$name$RESTORE_OLD_SUFFIX-$RS_TS") RS_PLAN_HAD+=("$had")
    srcs+=("$f")
  done
  _restore_swap_plan "${srcs[@]}" || return 1
  _backup_log "Secretos restaurados: ${#srcs[@]} archivo(s) en $SECRETS_DIR"
}

# --- Copias previas ---------------------------------------------------------------------------

# Copias previas registradas de $1 (más vieja primero; solo las que existen).
_restore_registry_copies() {
  local dst="$1" d o
  [[ -f "$RESTORE_OLD_REGISTRY" ]] || return 0
  while IFS=$'\t' read -r d o; do
    if [[ "$d" == "$dst" && -n "$o" ]] && _restore_exists "$o"; then printf '%s\n' "$o"; fi
  done < "$RESTORE_OLD_REGISTRY" | sort
  return 0
}

_restore_registry_add() {
  printf '%s\t%s\n' "$1" "$2" >> "$RESTORE_OLD_REGISTRY"
}

# Borra la copia previa $1 (solo si tiene la forma esperada) y la saca del registro.
_restore_old_drop() {
  local o="$1" tmp d x
  local dst_of
  dst_of="$(_restore_old_to_dst "$o")" || dst_of=""
  if [[ -n "$dst_of" ]] && _restore_path_ok "$o" && _restore_dst_allowed "$dst_of" && _restore_old_name_ok "$dst_of" "$o"; then
    _restore_priv rm -rf -- "$o" || true
  fi
  [[ -f "$RESTORE_OLD_REGISTRY" ]] || return 0
  tmp="$(mktemp "$BACKUP_STATE_DIR/.oldreg.XXXXXX")" || return 0
  while IFS=$'\t' read -r d x; do
    if [[ "$x" != "$o" ]]; then printf '%s\t%s\n' "$d" "$x"; fi
  done < "$RESTORE_OLD_REGISTRY" > "$tmp"
  mv -f -- "$tmp" "$RESTORE_OLD_REGISTRY"
}

# Al terminar bien: registra las copias creadas por esta corrida y limpia las del
# medio (queda la más vieja, el estado anterior a las restauraciones, y la más
# nueva). Con --discard-old se borran todas las registradas. Nunca se toca nada si la
# restauración anterior quedó interrumpida.
_restore_finalize_old() {
  local i dst o n k kept="" discard_skipped=0
  local -a copies=() dsts=()
  local -A seen=()
  for (( i = 0; i < ${#RS_KEPT_DST[@]}; i++ )); do
    _restore_registry_add "${RS_KEPT_DST[$i]}" "${RS_KEPT_OLD[$i]}"
    if [[ -z "${seen[${RS_KEPT_DST[$i]}]:-}" ]]; then seen[${RS_KEPT_DST[$i]}]=1; dsts+=("${RS_KEPT_DST[$i]}"); fi
  done
  if [[ "$RS_PREV_RESULT" == "interrupted" || "$RS_PREV_RESULT" == "running" ]]; then
    _restore_msg_add "no se borró ninguna copia previa porque la restauración anterior quedó interrumpida"
    discard_skipped=1
  fi
  for dst in "${dsts[@]}"; do
    copies=()
    while IFS= read -r o; do [[ -z "$o" ]] || copies+=("$o"); done < <(_restore_registry_copies "$dst")
    n=${#copies[@]}
    if [[ "$RS_DISCARD" -eq 1 && "$discard_skipped" -ne 1 ]]; then
      for o in "${copies[@]}"; do _restore_old_drop "$o"; done
      continue
    fi
    if [[ "$discard_skipped" -ne 1 ]]; then
      # Se conservan la primera (más vieja) y la última (más nueva).
      for (( k = 1; k < n - 1; k++ )); do _restore_old_drop "${copies[$k]}"; done
    fi
    for o in "${copies[@]}"; do
      if _restore_exists "$o"; then kept+="${kept:+, }$o"; fi
    done
  done
  if [[ -n "$kept" ]]; then
    _restore_msg_add "copias previas conservadas (bórrelas con 'sudo rm -rf' cuando confirme que todo está bien): $kept"
  fi
  return 0
}

# --- Salida y entrada principal ---------------------------------------------------------------

# Trap EXIT de la restauración: lo detenido SIEMPRE se levanta, un intercambio a
# medias se deshace, las carpetas de paso se borran y una corrida cortada deja
# 'interrupted'. Lo primero es ignorar nuevas señales y SIGPIPE (una terminal
# colgada deja la tubería de 'tee' rota: un 'printf' no puede matar el cleanup).
restore_exit_cleanup() {
  trap '' INT TERM HUP PIPE
  local rc=0 s
  if [[ ${#RS_SW_DST[@]} -gt 0 ]]; then
    _restore_undo_swaps
    _restore_journal_clear
  fi
  backup_restart_stopped || rc=1
  for s in "${RS_STAGES[@]}"; do _restore_priv rm -rf -- "$s" || true; done
  RS_STAGES=()
  if [[ "$RS_ACTIVE" == "1" ]]; then
    RS_RESULT=interrupted
    _restore_msg_add "la restauración se interrumpió antes de terminar${RS_DONE:+; ya restaurados: $RS_DONE}; el servicio en curso se deshizo y el resto quedó como estaba"
    [[ "$rc" -eq 0 ]] || _restore_msg_add "algún contenedor no volvió a iniciar (revise el log)"
    _restore_status_write || true
    RS_ACTIVE=0
  fi
  _BK_R2_REPO="" _BK_R2_KEY="" _BK_R2_SECRET="" _BK_R2_REGION=""
  return 0
}

_restore_finish() {
  if ! backup_restart_stopped; then
    _restore_worse error
    _restore_msg_add "algún contenedor no volvió a iniciar (revise el log)"
  fi
  _restore_stage_drop "${RS_STAGES[@]}"
  RS_STAGES=()
  if [[ "$RS_RESULT" == "error" && ${#RS_KEPT_OLD[@]} -gt 0 ]]; then
    _restore_msg_add "quedaron copias previas de lo ya restaurado (no se borran): ${RS_KEPT_OLD[*]}"
  fi
  _restore_status_write || true
  RS_ACTIVE=0
  _backup_log "Fin de la restauración: $RS_RESULT${RS_MSG:+ ($RS_MSG)}"
  [[ "$RS_RESULT" != "error" ]]
}

# Falla de la restauración antes de intercambiar nada.
_restore_abort() {
  RS_RESULT=error
  _backup_log "ERROR: $RS_MSG"
  _restore_stage_drop_all
  _restore_finish || true
  return 1
}

# La restauración completa (argumentos ya validados por restore_parse_args).
restore_run() {
  local id unit rc nres=0 p
  local -a restored_native=() services=() all_paths=() swap_ids=()
  umask 022   # carpetas padre creadas por nosotros: legibles para los contenedores
  RS_PREV_RESULT="$(restore_status_get result)"
  RS_ACTIVE=1 RS_RESULT=running RS_MSG="" RS_MODULES="" RS_STIME="" RS_TS="$(date +%Y%m%d-%H%M%S)" RS_DONE=""
  RS_KEPT_DST=() RS_KEPT_OLD=() RS_STAGES=() RS_STAGED=()
  _restore_status_write || true
  RS_RESULT=ok
  _backup_log "Inicio de la restauración: origen=$RS_SOURCE foto=$RS_SNAPSHOT destino=$RS_TARGET"

  # Un diario que no se pudo deshacer bloquea toda restauración nueva hasta resolverlo a mano.
  if [[ -e "$RESTORE_JOURNAL_FAILED" ]]; then
    _restore_msg_add "hay una restauración anterior sin revertir ($RESTORE_JOURNAL_FAILED): devuelva a mano las carpetas desde sus copias '.hli2-before-restore-*', borre ese archivo y reintente"
    _restore_abort
    return 1
  fi
  # Primero lo que un proceso muerto dejó a medias (intercambio y contenedores).
  RS_JOURNAL_REVERTED=""
  if ! backup_recover; then
    if [[ "$RS_JOURNAL_FAILED" -eq 1 ]]; then
      _restore_msg_add "no se pudo revertir una restauración interrumpida anterior (ver $RESTORE_JOURNAL_FAILED)"
      _restore_abort
      return 1
    fi
    _restore_worse warning
    _restore_msg_add "quedaron contenedores sin iniciar de una corrida anterior"
  fi
  if [[ -n "$RS_JOURNAL_REVERTED" ]]; then
    _restore_worse warning
    _restore_msg_add "antes de empezar se revirtió una restauración anterior que quedó a medias: $RS_JOURNAL_REVERTED"
    RS_PREV_RESULT="interrupted"
  fi

  if ! _restore_open_repo || ! _restore_resolve_snapshot; then
    _restore_abort
    return 1
  fi
  _backup_log "Foto $RS_RID ($(restore_fmt_time "$RS_STIME"))"

  mapfile -t services < <(_restore_target_services)
  _restore_containers_plan || { _restore_abort; return 1; }

  for id in "${services[@]}"; do
    [[ -n "$id" ]] || continue
    while IFS= read -r p; do [[ -z "$p" ]] || all_paths+=("$p"); done < <(_restore_service_paths "$id")
  done
  _restore_space_preflight "${all_paths[@]}" || { _restore_abort; return 1; }

  # Fase 1: todo a carpetas de paso, con los contenedores en marcha.
  for id in "${services[@]}"; do
    [[ -n "$id" ]] || continue
    rc=0
    _restore_service_stage "$id" || rc=$?
    case "$rc" in
      0) swap_ids+=("$id") ;;
      3)
        if [[ "$RS_TARGET" == "all" ]]; then
          _backup_log "La foto no contiene datos de '$id'"
        else
          _restore_worse error
          _restore_msg_add "la foto no contiene datos de '$id'"
        fi
        ;;
      4)
        if [[ "$RS_TARGET" == "all" ]]; then
          _backup_log "Todos los datos de '$id' son solo locales"
        else
          _restore_worse error
          _restore_msg_add "todos los datos de '$id' son solo locales: no están en la copia externa (use la copia local)"
        fi
        ;;
      *)
        _restore_worse error
        _restore_msg_add "falló la restauración de '$id'; lo actual quedó como estaba"
        ;;
    esac
    [[ "$RS_RESULT" != "error" ]] || break
  done
  if [[ "$RS_RESULT" != "error" && "$RS_TARGET" == "all" ]]; then
    rc=0
    _restore_secrets_stage || rc=$?
    case "$rc" in
      0) ;;
      2) _restore_worse warning; _restore_msg_add "la foto no contiene $SECRETS_DIR" ;;
      *) _restore_worse error; _restore_msg_add "falló la restauración de $SECRETS_DIR; lo actual quedó como estaba" ;;
    esac
  fi
  [[ "$RS_RESULT" != "error" ]] || { _restore_abort; return 1; }

  # Fase 2: detener, intercambiar, reiniciar.
  if ! _restore_containers_stop; then
    _restore_abort
    return 1
  fi
  for id in "${swap_ids[@]}"; do
    if _restore_service_swap "$id"; then
      nres=$(( nres + 1 ))
      RS_DONE+="${RS_DONE:+ }$id"
      if [[ "$(service_get "$id" KIND)" == "native" ]]; then restored_native+=("$id"); fi
    else
      _restore_worse error
      _restore_msg_add "falló el intercambio de '$id'; ese servicio quedó como estaba"
      break
    fi
  done
  if [[ "$RS_RESULT" != "error" && "$RS_TARGET" == "all" && ${#RS_SECRET_FILES[@]} -gt 0 ]]; then
    if _restore_secrets_swap; then
      nres=$(( nres + 1 ))
    else
      _restore_worse error
      _restore_msg_add "falló la restauración de $SECRETS_DIR; lo actual quedó como estaba"
    fi
  fi
  _restore_stage_drop_all

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
    _restore_finalize_old
    [[ "$nres" -gt 0 ]] || { _restore_worse warning; _restore_msg_add "no se restauró nada"; }
  fi
  if [[ -n "$RS_MODULES" ]]; then
    _restore_worse warning
    _restore_msg_add "faltan contenedores: ejecute los módulos indicados para desplegarlos"
  fi
  _restore_finish
}
