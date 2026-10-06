#!/usr/bin/env bash
# Backups con restic: copia local (repositorio en el disco de media) + copia
# externa (Cloudflare R2). Ver ROADMAP.md, "Backups: dos copias, una
# herramienta" y v2.5.
#
# Esta biblioteca corre COMO ROOT: la invocan bin/hli2-backup (servicio
# systemd y acción manual vía 'sudo') y nunca el usuario sin privilegios
# directamente. Por eso no antepone 'sudo' a restic ni a las escrituras de
# estado; los accesos a /etc/hli2 sí pasan por priv_file_read/secret_get
# (lib/secrets.sh), que funcionan igual como root y hacen el flujo testeable.
#
# Datos y convenciones (el restore, v2.5 parte 2, se apoya en esto):
#   - Repo local: $BACKUP_ROOT (root 0700). Repo R2: RESTIC_REPOSITORY de
#     /etc/hli2/restic.env. Misma contraseña en ambos (archivo
#     $BACKUP_PASSWORD_FILE, 0600), pasada a restic por RESTIC_PASSWORD_FILE.
#   - Dos fotos locales por corrida, mismas rutas salvo las "solo local":
#       tag "full"  -> todo lo respaldable (menos cachés).
#       tag "cloud" -> sin las rutas SERVICE_BACKUP_LOCAL_ONLY; esta es la
#                      que 'restic copy' lleva a R2 (tags y host se conservan).
#     La retención agrupa por host+tags, así cada tag tiene su historial.
#   - Las rutas se guardan absolutas: restaurar = 'restic restore --target /
#     --include <ruta>'.
#   - Estado legible por el usuario: $BACKUP_STATUS_FILE (CLAVE=valor, 0644,
#     sin secretos).
#
# Supuestos de restic (paquete de Ubuntu 24.04 noble: 0.16.4), verificados
# contra la documentación 0.16: 'restic copy --from-repo --from-password-file
# --tag' (no existe --repo2, que es de 0.14 viejo); R2 con backend s3 usa
# AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY y AWS_DEFAULT_REGION=auto (la
# región 'auto' es la que documenta Cloudflare; NO verificado en hardware).
set -euo pipefail

BACKUP_PASSWORD_FILE="${HLI2_BACKUP_PASSWORD_FILE:-$SECRETS_DIR/restic-password}"
BACKUP_STATUS_FILE="${HLI2_BACKUP_STATUS_FILE:-$STATE_DIR/backup-status}"
BACKUP_CHECK_STAMP="${HLI2_BACKUP_CHECK_STAMP:-$STATE_DIR/backup-last-check}"
BACKUP_CACHE_DIR="${HLI2_BACKUP_CACHE_DIR:-/var/cache/hli2/restic}"
BACKUP_CHECK_EVERY_DAYS=7
BACKUP_CHECK_SUBSET="5%"
BACKUP_STOP_TIMEOUT=30
BACKUP_STALE_HOURS=36
BACKUP_KEEP=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)

# Contenedores que ESTE proceso detuvo y todavía no volvieron a arrancar
# (mismo patrón que IMPORT_STOPPED_CONTAINERS en lib/importer.sh).
BACKUP_STOPPED_CONTAINERS=""

# Credenciales de R2 cargadas desde /etc/hli2/restic.env. NO se exportan:
# solo viajan en el entorno del proceso restic (ver _backup_restic_r2).
_BK_R2_REPO=""
_BK_R2_KEY=""
_BK_R2_SECRET=""
_BK_R2_REGION=""

# Resultado de la corrida (lo vuelca _backup_status_write).
BK_RESULT="ok" BK_LOCAL="ok" BK_CLOUD="not-configured" BK_CHECK="skipped"
BK_ID_FULL="" BK_ID_CLOUD="" BK_MSG=""

_backup_log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

# Agrega un aviso/error corto al mensaje del estado (sin saltos de línea).
_backup_msg_add() {
  local m="${1//$'\n'/ }"
  BK_MSG+="${BK_MSG:+; }$m"
}

# Escalada de resultado: ok < warning < error.
_backup_worse() {
  case "$1" in
    error) BK_RESULT=error ;;
    warning) [[ "$BK_RESULT" == "error" ]] || BK_RESULT=warning ;;
  esac
  return 0
}

# --- Seguridad del destino ---------------------------------------------------

# Id de dispositivo del sistema de archivos que contiene $1. Función aparte
# para que los tests puedan simular dos discos distintos.
_backup_devid() {
  stat -c %d -- "$1"
}

# Falla cerrado si $BACKUP_ROOT está en el mismo dispositivo que '/': un
# disco de media montado tarde (o no montado) deja escribir en la carpeta
# oculta del disco del sistema, que se llenaría en silencio y, peor, los
# contenedores seguirían escribiendo ahí (lección del 2026-10-06). Se
# evalúa el ancestro existente más cercano, sin crear nada antes.
_backup_guard_fs() {
  local p="$BACKUP_ROOT" root_dev dev
  while [[ ! -e "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
  root_dev="$(_backup_devid /)" || { _backup_msg_add "no se pudo leer el disco de /"; return 1; }
  dev="$(_backup_devid "$p")" || { _backup_msg_add "no se pudo leer el disco de $p"; return 1; }
  if [[ -z "$root_dev" || -z "$dev" || "$dev" == "$root_dev" ]]; then
    _backup_msg_add "$BACKUP_ROOT está en el mismo disco que el sistema (¿falta montar el disco de media?). No se hace backup"
    return 1
  fi
  return 0
}

# --- Selección de rutas desde el registro de servicios ------------------------

# Llena BK_PATHS (foto full), BK_CLOUD_PATHS (foto cloud: sin las rutas solo
# local), BK_EXCLUDE_ARGS y BK_LOCAL_ONLY. Solo rutas que existen. Nunca
# /srv/media*.
_backup_collect() {
  local id p
  local -a all=() excl=() lonly=()
  local -A seen=() is_excl=() is_lonly=()
  BK_PATHS=() BK_CLOUD_PATHS=() BK_EXCLUDE_ARGS=() BK_LOCAL_ONLY=()

  while read -r id; do
    [[ -n "$id" ]] || continue
    while IFS= read -r p; do
      if [[ -n "$p" ]]; then all+=("$p"); fi
    done < <(service_get "$id" DATA)
    while IFS= read -r p; do
      if [[ -n "$p" ]]; then excl+=("$p"); fi
    done < <(service_get "$id" BACKUP_EXCLUDE)
    while IFS= read -r p; do
      if [[ -n "$p" ]]; then lonly+=("$p"); fi
    done < <(service_get "$id" BACKUP_LOCAL_ONLY)
  done < <(service_list)

  all+=("/etc/samba/smb.conf" "$SECRETS_DIR" "$STATE_DIR" "$SCRIPT_DIR/config")
  # La contraseña de restic nunca viaja dentro de sus propios repositorios.
  excl+=("$BACKUP_PASSWORD_FILE")

  for p in "${excl[@]}"; do is_excl[$p]=1; BK_EXCLUDE_ARGS+=("--exclude=$p"); done
  for p in "${lonly[@]}"; do is_lonly[$p]=1; BK_LOCAL_ONLY+=("$p"); done

  for p in "${all[@]}"; do
    if [[ -n "${seen[$p]:-}" || -n "${is_excl[$p]:-}" ]]; then continue; fi
    seen[$p]=1
    if [[ ! -e "$p" ]]; then continue; fi
    BK_PATHS+=("$p")
    if [[ -z "${is_lonly[$p]:-}" ]]; then BK_CLOUD_PATHS+=("$p"); fi
  done
  return 0
}

# --- Contenedores ------------------------------------------------------------

# Nombres de contenedor de los servicios con SERVICE_BACKUP_KIND=sqlite.
_backup_sqlite_containers() {
  local id
  while read -r id; do
    [[ -n "$id" ]] || continue
    if [[ "$(service_get "$id" BACKUP_KIND)" == "sqlite" && "$(service_get "$id" KIND)" == "container" ]]; then
      service_get "$id" CONTAINER
    fi
  done < <(service_list)
}

_backup_container_running() {
  local out
  out="$(hli_docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" || return 1
  [[ "$out" == "true" ]]
}

# Detiene los contenedores sqlite que estén corriendo. Cada nombre se anota
# ANTES de detenerlo: si 'docker stop' falla a medias, igual se intenta
# levantarlo después. Devuelve 1 si alguno no se pudo detener (la foto sería
# inconsistente: el llamador no la toma).
_backup_stop_sqlite() {
  local c
  while read -r c; do
    [[ -n "$c" ]] || continue
    _backup_container_running "$c" || continue
    BACKUP_STOPPED_CONTAINERS+="$c "
    _backup_log "Deteniendo '$c' para la copia consistente"
    if ! hli_docker stop -t "$BACKUP_STOP_TIMEOUT" "$c" >/dev/null 2>&1; then
      hli_error "no se pudo detener '$c'"
      return 1
    fi
  done < <(_backup_sqlite_containers)
  return 0
}

# Vuelve a levantar lo que este proceso detuvo. Nunca falla (se usa dentro de
# un trap EXIT): lo que no arranca queda registrado con el comando exacto.
_backup_restart_container() {
  local c="$1"
  hli_docker start "$c" >/dev/null 2>&1 && return 0
  hli_error "no se pudo volver a iniciar '$c'. Inícielo a mano: sudo docker start $c"
  return 1
}

backup_restart_stopped() {
  local c remaining=""
  for c in $BACKUP_STOPPED_CONTAINERS; do
    _backup_log "Iniciando '$c'"
    if ! _backup_restart_container "$c"; then remaining+="$c "; fi
  done
  BACKUP_STOPPED_CONTAINERS="$remaining"
  [[ -z "$remaining" ]]
}

# Trap EXIT de bin/hli2-backup: lo detenido SIEMPRE se levanta, y las
# credenciales cargadas no sobreviven al proceso.
backup_exit_cleanup() {
  backup_restart_stopped || true
  _BK_R2_REPO="" _BK_R2_KEY="" _BK_R2_SECRET="" _BK_R2_REGION=""
  return 0
}

# --- restic ------------------------------------------------------------------

# Entorno de restic SOLO para ese proceso (prefijo de comando, no 'export'):
# la contraseña va por archivo y las claves de R2 nunca llegan a argv.
_backup_restic_local() {
  RESTIC_REPOSITORY="$BACKUP_ROOT" RESTIC_PASSWORD_FILE="$BACKUP_PASSWORD_FILE" \
    RESTIC_CACHE_DIR="$BACKUP_CACHE_DIR" restic "$@"
}

_backup_restic_r2() {
  RESTIC_REPOSITORY="$_BK_R2_REPO" RESTIC_PASSWORD_FILE="$BACKUP_PASSWORD_FILE" \
    RESTIC_CACHE_DIR="$BACKUP_CACHE_DIR" \
    AWS_ACCESS_KEY_ID="$_BK_R2_KEY" AWS_SECRET_ACCESS_KEY="$_BK_R2_SECRET" \
    AWS_DEFAULT_REGION="${_BK_R2_REGION:-auto}" restic "$@"
}

# Carga la configuración de R2. 0 = configurada; 1 = no configurada.
backup_r2_load() {
  _BK_R2_REPO="" _BK_R2_KEY="" _BK_R2_SECRET="" _BK_R2_REGION=""
  secret_file_exists restic || return 1
  _BK_R2_REPO="$(secret_get restic RESTIC_REPOSITORY 2>/dev/null)" || return 1
  _BK_R2_KEY="$(secret_get restic AWS_ACCESS_KEY_ID 2>/dev/null)" || return 1
  _BK_R2_SECRET="$(secret_get restic AWS_SECRET_ACCESS_KEY 2>/dev/null)" || return 1
  _BK_R2_REGION="$(secret_get restic AWS_DEFAULT_REGION 2>/dev/null)" || _BK_R2_REGION="auto"
  [[ -n "$_BK_R2_REPO" && -n "$_BK_R2_KEY" && -n "$_BK_R2_SECRET" ]]
}

# Corre "$@" mostrando la salida (terminal/log) y guardándola en $1. Devuelve
# el código de salida del comando (no el de tee).
_backup_tee() {
  local out="$1" rc=0
  shift
  "$@" 2>&1 | tee "$out" || rc="${PIPESTATUS[0]}"
  return "$rc"
}

# Toma la foto con tag $1 (full|cloud). Deja el id en BK_LAST_ID. Devuelve el
# código de restic (3 = foto creada pero con archivos ilegibles).
_backup_snapshot() {
  local tag="$1" out rc=0
  local -a paths excl=("${BK_EXCLUDE_ARGS[@]}")
  BK_LAST_ID=""
  if [[ "$tag" == "cloud" ]]; then
    paths=("${BK_CLOUD_PATHS[@]}")
    local p
    for p in "${BK_LOCAL_ONLY[@]}"; do excl+=("--exclude=$p"); done
  else
    paths=("${BK_PATHS[@]}")
  fi
  out="$(mktemp)"
  _backup_log "Foto local '$tag' (${#paths[@]} rutas)"
  _backup_tee "$out" _backup_restic_local backup --tag "$tag" "${excl[@]}" -- "${paths[@]}" || rc=$?
  BK_LAST_ID="$(sed -n 's/^snapshot \([0-9a-f]\{6,\}\) saved.*/\1/p' "$out" | tail -n1)"
  rm -f "$out"
  return "$rc"
}

# Foto local con manejo de resultado: ok / warning (rc 3) / error.
_backup_take() {
  local tag="$1" rc=0
  _backup_snapshot "$tag" || rc=$?
  case "$rc" in
    0) ;;
    3)
      BK_LOCAL=warning
      _backup_worse warning
      _backup_msg_add "la foto '$tag' se creó con archivos ilegibles"
      ;;
    *)
      BK_LOCAL=error
      _backup_worse error
      _backup_msg_add "falló la foto local '$tag' (código $rc)"
      return 1
      ;;
  esac
  if [[ "$tag" == "full" ]]; then BK_ID_FULL="$BK_LAST_ID"; else BK_ID_CLOUD="$BK_LAST_ID"; fi
  return 0
}

_backup_forget() {
  local which="$1" rc=0
  _backup_log "Retención ($which)"
  if [[ "$which" == "local" ]]; then
    _backup_restic_local forget --group-by host,tags "${BACKUP_KEEP[@]}" --prune || rc=$?
  else
    _backup_restic_r2 forget --group-by host,tags "${BACKUP_KEEP[@]}" --prune || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    _backup_worse warning
    _backup_msg_add "falló la retención ($which)"
  fi
  return 0
}

_backup_check_due() {
  local last now
  [[ -f "$BACKUP_CHECK_STAMP" ]] || return 0
  last="$(stat -c %Y -- "$BACKUP_CHECK_STAMP" 2>/dev/null)" || return 0
  now="$(date +%s)"
  (( now - last >= BACKUP_CHECK_EVERY_DAYS * 86400 ))
}

# 'restic check' con una muestra de los datos, a lo sumo una vez por semana.
_backup_check() {
  local rc=0 r2=$1
  if ! _backup_check_due; then BK_CHECK=skipped; return 0; fi
  BK_CHECK=ok
  _backup_log "Chequeo de integridad (muestra $BACKUP_CHECK_SUBSET) local"
  _backup_restic_local check --read-data-subset="$BACKUP_CHECK_SUBSET" || rc=$?
  if [[ "$r2" == "1" ]]; then
    _backup_log "Chequeo de integridad (muestra $BACKUP_CHECK_SUBSET) R2"
    _backup_restic_r2 check --read-data-subset="$BACKUP_CHECK_SUBSET" || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    BK_CHECK=error
    _backup_worse error
    _backup_msg_add "falló el chequeo de integridad"
  else
    : > "$BACKUP_CHECK_STAMP"
  fi
  return 0
}

# --- Estado --------------------------------------------------------------------

_backup_status_write() {
  local tmp="$BACKUP_STATUS_FILE.tmp"
  install -m 0644 /dev/null "$tmp"
  {
    printf 'timestamp=%s\n' "$(date -Is)"
    printf 'result=%s\n' "$BK_RESULT"
    printf 'local=%s\n' "$BK_LOCAL"
    printf 'cloud=%s\n' "$BK_CLOUD"
    printf 'check=%s\n' "$BK_CHECK"
    printf 'snapshot_full=%s\n' "$BK_ID_FULL"
    printf 'snapshot_cloud=%s\n' "$BK_ID_CLOUD"
    printf 'message=%s\n' "$BK_MSG"
  } > "$tmp"
  mv -f -- "$tmp" "$BACKUP_STATUS_FILE"
}

# Valor de una clave del archivo de estado (vacío si no existe). Lo leen el
# usuario sin privilegios (dashboard, backup-now): el archivo es 0644.
backup_status_get() {
  local key="$1" line
  [[ -r "$BACKUP_STATUS_FILE" ]] || return 0
  while IFS= read -r line; do
    case "$line" in "${key}="*) printf '%s' "${line#"${key}="}"; return 0 ;; esac
  done < "$BACKUP_STATUS_FILE"
  return 0
}

_backup_res_es() {
  case "$1" in
    ok) echo "correcto" ;;
    warning) echo "con avisos" ;;
    error) echo "ERROR" ;;
    not-configured) echo "no configurada" ;;
    skipped) echo "omitido" ;;
    *) echo "${1:-N/D}" ;;
  esac
}

# Texto del estado del último backup, para el dashboard y backup-now.
backup_status_summary() {
  local ts res msg when age
  if [[ ! -r "$BACKUP_STATUS_FILE" ]]; then
    printf '  Último backup : sin backups todavía\n'
    return 0
  fi
  ts="$(backup_status_get timestamp)"
  res="$(backup_status_get result)"
  when="${ts/T/ }"; when="${when:0:16}"
  printf '  Último backup : %s — %s\n' "${when:-N/D}" "$(_backup_res_es "$res")"
  printf '  Copia local   : %s\n' "$(_backup_res_es "$(backup_status_get local)")"
  printf '  Copia externa : %s\n' "$(_backup_res_es "$(backup_status_get cloud)")"
  msg="$(backup_status_get message)"
  [[ -z "$msg" ]] || printf '  Detalle       : %s\n' "$msg"
  if age="$(date -d "$ts" +%s 2>/dev/null)" && (( $(date +%s) - age > BACKUP_STALE_HOURS * 3600 )); then
    printf '  AVISO         : el último backup tiene más de %s horas\n' "$BACKUP_STALE_HOURS"
  fi
  return 0
}

# --- Entradas principales --------------------------------------------------------

_backup_preflight() {
  command -v restic >/dev/null 2>&1 || { _backup_msg_add "restic no está instalado (ejecute backup-setup)"; return 1; }
  priv_file_exists "$BACKUP_PASSWORD_FILE" || { _backup_msg_add "falta la contraseña de restic (ejecute backup-setup)"; return 1; }
  _backup_guard_fs || return 1
  [[ -f "$BACKUP_ROOT/config" ]] || { _backup_msg_add "el repositorio local no está inicializado (ejecute backup-setup)"; return 1; }
  chmod 0700 "$BACKUP_ROOT"
  return 0
}

# Un backup completo. Devuelve 1 si el resultado es 'error'. Los
# contenedores detenidos se levantan acá mismo apenas terminan las fotos, y
# además el trap de bin/hli2-backup (backup_exit_cleanup) cubre cualquier
# salida anormal.
backup_run() {
  BK_RESULT=ok BK_LOCAL=ok BK_CLOUD=not-configured BK_CHECK=skipped
  BK_ID_FULL="" BK_ID_CLOUD="" BK_MSG=""
  local r2=0
  _backup_log "Inicio del backup"

  if ! _backup_preflight; then
    BK_RESULT=error BK_LOCAL=error BK_CLOUD=skipped
    _backup_log "ERROR: $BK_MSG"
    _backup_status_write
    return 1
  fi

  _backup_collect

  # Ventana de parada: lo mínimo (las dos fotos locales, deduplicadas).
  if _backup_stop_sqlite; then
    if _backup_take full; then _backup_take cloud || true; fi
  else
    BK_LOCAL=error
    _backup_worse error
    _backup_msg_add "no se pudieron detener los contenedores con base de datos; no se tomó la foto"
  fi
  if ! backup_restart_stopped; then
    _backup_worse error
    _backup_msg_add "algún contenedor no volvió a iniciar (revise el log)"
  fi

  _backup_forget local

  if backup_r2_load; then
    r2=1
    BK_CLOUD=ok
    _backup_log "Copia externa (R2)"
    local rc=0
    _backup_restic_r2 copy --from-repo "$BACKUP_ROOT" --from-password-file "$BACKUP_PASSWORD_FILE" --tag cloud || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      BK_CLOUD=error
      _backup_worse error
      _backup_msg_add "falló la copia externa a R2 (código $rc)"
    else
      _backup_forget r2
    fi
  fi

  _backup_check "$r2"

  _backup_status_write
  _backup_log "Fin del backup: $BK_RESULT (local=$BK_LOCAL, externa=$BK_CLOUD)"
  [[ "$BK_RESULT" != "error" ]]
}

# Inicializa los repositorios que falten (idempotente). Como root.
backup_init() {
  local rc=0
  BK_MSG=""
  command -v restic >/dev/null 2>&1 || { echo "ERROR: restic no está instalado." >&2; return 1; }
  priv_file_exists "$BACKUP_PASSWORD_FILE" || { echo "ERROR: falta la contraseña de restic ($BACKUP_PASSWORD_FILE)." >&2; return 1; }
  if ! _backup_guard_fs; then echo "ERROR: $BK_MSG" >&2; return 1; fi
  install -d -m 0700 "$BACKUP_ROOT"
  chmod 0700 "$BACKUP_ROOT"
  if [[ ! -f "$BACKUP_ROOT/config" ]]; then
    _backup_log "Inicializando el repositorio local"
    _backup_restic_local init || { echo "ERROR: no se pudo inicializar el repositorio local." >&2; return 1; }
  fi
  if backup_r2_load; then
    if ! _backup_restic_r2 cat config >/dev/null 2>&1; then
      _backup_log "Inicializando el repositorio en R2"
      _backup_restic_r2 init || rc=$?
      if [[ "$rc" -ne 0 ]]; then
        echo "ERROR: no se pudo inicializar el repositorio en R2 (revise endpoint, bucket y claves)." >&2
        return 1
      fi
    fi
  fi
  _BK_R2_REPO="" _BK_R2_KEY="" _BK_R2_SECRET="" _BK_R2_REGION=""
  return 0
}
