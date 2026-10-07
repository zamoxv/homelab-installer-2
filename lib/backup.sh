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
# Estado escrito por ROOT: nunca en STATE_DIR (de propiedad del usuario: un
# enlace simbólico plantado ahí haría que root escribiera donde el usuario
# quiera). Dir root 0755; el estado (0644, sin secretos) lo lee el usuario.
BACKUP_STATE_DIR="${HLI2_BACKUP_STATE_DIR:-/var/lib/hli2-root}"
BACKUP_STATUS_FILE="$BACKUP_STATE_DIR/backup-status"
BACKUP_CHECK_STAMP="$BACKUP_STATE_DIR/backup-last-check"
BACKUP_RECOVERY_FILE="$BACKUP_STATE_DIR/recovery-containers"
# Copia root-owned del código que ejecuta root (servicio y 'sudo'): root nunca
# ejecuta lib/*.sh, config ni services de un checkout del usuario.
BACKUP_INSTALL_DIR="${HLI2_BACKUP_INSTALL_DIR:-/usr/local/lib/hli2}"
BACKUP_CACHE_DIR="${HLI2_BACKUP_CACHE_DIR:-/var/cache/hli2/restic}"
BACKUP_CHECK_EVERY_DAYS=7
BACKUP_CHECK_SUBSET="5%"
BACKUP_STOP_TIMEOUT=30
BACKUP_STALE_HOURS=36
# Reinicio de contenedores: espera total, intervalo y pausa de "asentamiento"
# (un 'docker stop' de un cliente muerto puede seguir en el daemon).
BACKUP_RESTART_WAIT="${HLI2_BACKUP_RESTART_WAIT:-60}"
BACKUP_RESTART_POLL="${HLI2_BACKUP_RESTART_POLL:-5}"
BACKUP_RESTART_SETTLE="${HLI2_BACKUP_RESTART_SETTLE:-2}"
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

# Resultado de la corrida (lo vuelca _backup_status_write). BK_ACTIVE=1 mientras
# haya una corrida en curso: si el proceso muere, el trap deja 'interrupted'.
BK_RESULT="ok" BK_LOCAL="ok" BK_CLOUD="not-configured" BK_CHECK="skipped"
BK_ID_FULL="" BK_ID_CLOUD="" BK_MSG="" BK_ACTIVE=0 BK_WARMUP_ID=""
BK_TMP_FILES=()
BK_NO_RETENTION=0
# 'init --r2-assume-new': el usuario confirmó que el bucket de R2 es nuevo y está vacío.
BK_R2_ASSUME_NEW=0
# Código de salida de 'init' cuando la comprobación de R2 es ambigua (backup-setup pregunta).
BACKUP_INIT_RC_AMBIGUOUS=20
# Solo para el estado de un backup omitido (ver bin/hli2-backup): conserva la fecha
# del último intento REAL y anota cuándo se omitió el último.
BK_TS="" BK_LAST_SKIP=""

# Si stdout ya no existe (una terminal SSH colgada deja rota la tubería de 'tee'),
# la línea va directo al log: un registro nunca puede matar al proceso, y menos
# al cleanup que vuelve a iniciar los contenedores. (Con SIGPIPE ignorado, que es
# como corren el backup y la restauración, 'printf' solo devuelve error.)
_backup_log() {
  local line
  line="$(printf '[%s] %s' "$(date '+%F %T')" "$*")"
  printf '%s\n' "$line" 2>/dev/null || printf '%s\n' "$line" >> "$LOG_DIR/backup.log" 2>/dev/null || true
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

# --- Estado de root y copia del código ---------------------------------------------

# Crea (si falta) el directorio de estado de root y comprueba que es nuestro y
# no un enlace simbólico. Como root, 'install -d' lo deja root:root.
_backup_state_dir_ensure() {
  install -d -m 0755 "$BACKUP_STATE_DIR" 2>/dev/null || true
  if [[ -L "$BACKUP_STATE_DIR" || ! -d "$BACKUP_STATE_DIR" || ! -O "$BACKUP_STATE_DIR" ]]; then
    _backup_msg_add "el directorio de estado $BACKUP_STATE_DIR no es válido (debe ser propio y no un enlace)"
    return 1
  fi
}

# Copia ROOT-OWNED del código (bin/, lib/, services/, config/) en
# $BACKUP_INSTALL_DIR. La corre el USUARIO (con sudo en cada operación: nunca
# ejecuta nada del checkout como root) desde backup-setup y backup-now, y deja
# todo root:root, directorios 0755 y archivos 0644 (el entrypoint 0755). Solo
# archivos regulares (los enlaces simbólicos se omiten). La copia se arma en un
# directorio de paso y se intercambia entera. 'source-dir' guarda de dónde
# salió, para respaldar también la configuración real del usuario.
backup_refresh_install() {
  local src="$SCRIPT_DIR" dst="$BACKUP_INSTALL_DIR" stage f sub mode
  [[ "$(cd "$src" && pwd -P)" != "$(cd "$dst" 2>/dev/null && pwd -P || echo /nonexistent)" ]] || return 0
  stage="$dst.new"
  sudo rm -rf "$stage"
  sudo install -d -m 0755 -o root -g root "$stage" "$stage/bin" "$stage/lib" "$stage/services" "$stage/config" || return 1
  for f in "$src/bin/hli2-backup" "$src"/lib/*.sh "$src"/services/*.conf "$src/config/default.conf"; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    sub="${f#"$src"/}"
    mode=0644
    [[ "$sub" == bin/* ]] && mode=0755
    sudo install -m "$mode" -o root -g root "$f" "$stage/$sub" || return 1
  done
  printf '%s\n' "$src" | sudo tee "$stage/source-dir" >/dev/null || return 1
  sudo rm -rf "$dst.old"
  if [[ -e "$dst" ]]; then sudo mv "$dst" "$dst.old" || return 1; fi
  if ! sudo mv "$stage" "$dst"; then
    # El intercambio no es atómico: si falla el segundo mv, se restaura lo
    # anterior para no dejar el backup sin código instalado.
    if [[ -e "$dst.old" && ! -e "$dst" ]]; then sudo mv "$dst.old" "$dst" || true; fi
    return 1
  fi
  sudo rm -rf "$dst.old"
  return 0
}

# --- Seguridad del destino ---------------------------------------------------

# Id de dispositivo del sistema de archivos que contiene $1. Función aparte
# para que los tests puedan simular dos discos distintos.
_backup_devid() {
  stat -c %d -- "$1"
}

# Falla cerrado si $BACKUP_ROOT no está en un disco de datos montado aparte del
# sistema: un disco de media montado tarde (o no montado) deja escribir en la
# carpeta oculta del disco del sistema (lección del 2026-10-06). Se resuelve la
# ruta real (enlaces simbólicos) y se evalúa su ancestro existente más cercano,
# sin crear nada antes:
#   1. el punto de montaje que la contiene no puede ser '/' ni compartir
#      dispositivo con '/';
#   2. si queda bajo $MEDIA_ROOT, $MEDIA_ROOT tiene que ser un punto de montaje
#      (con /srv en otra partición y el disco de media sin montar, el punto 1
#      solo no alcanza).
_backup_guard_fs() {
  local rp p target root_dev dev media_rp
  rp="$(realpath -m -- "$BACKUP_ROOT")" || { _backup_msg_add "no se pudo resolver $BACKUP_ROOT"; return 1; }
  p="$rp"
  while [[ ! -e "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
  target="$(findmnt -n -o TARGET -T "$p" 2>/dev/null)" || target=""
  if [[ -z "$target" || "$target" == "/" ]]; then
    _backup_msg_add "$BACKUP_ROOT está en el mismo disco que el sistema (¿falta montar el disco de media?). No se hace backup"
    return 1
  fi
  root_dev="$(_backup_devid /)" || { _backup_msg_add "no se pudo leer el disco de /"; return 1; }
  dev="$(_backup_devid "$p")" || { _backup_msg_add "no se pudo leer el disco de $p"; return 1; }
  if [[ -z "$root_dev" || -z "$dev" || "$dev" == "$root_dev" ]]; then
    _backup_msg_add "$BACKUP_ROOT está en el mismo disco que el sistema (¿falta montar el disco de media?). No se hace backup"
    return 1
  fi
  media_rp="$(realpath -m -- "$MEDIA_ROOT")" || media_rp="$MEDIA_ROOT"
  case "$rp/" in
    "$media_rp/"*)
      if ! mountpoint -q "$media_rp"; then
        _backup_msg_add "$MEDIA_ROOT no es un punto de montaje (disco de media sin montar). No se hace backup"
        return 1
      fi
      ;;
  esac
  return 0
}

# Carpeta del repositorio: root:root 0700, siempre (otros flujos, como
# create_media_skeleton, pudieron haberla tocado).
_backup_secure_repo_dir() {
  chmod 0700 "$BACKUP_ROOT"
  chmod g-s,u-s "$BACKUP_ROOT"
  chown -R -h root:root "$BACKUP_ROOT"
}

# La contraseña existe y es utilizable (no vacía, sin espacios, >= 16 caracteres).
_backup_password_ok() {
  local pw
  pw="$(priv_file_read "$BACKUP_PASSWORD_FILE" 2>/dev/null)" || return 1
  pw="${pw%%$'\n'*}"
  [[ "${#pw}" -ge 16 && "$pw" != *[[:space:]]* ]]
}

# --- Selección de rutas desde el registro de servicios ------------------------

# Llena BK_PATHS (foto full), BK_CLOUD_PATHS (foto cloud: sin las rutas solo
# local), BK_EXCLUDE_ARGS y BK_LOCAL_ONLY. Solo rutas que existen. Nunca
# /srv/media*. SCRIPT_DIR es la copia root-owned; si existe 'source-dir' se
# respalda además la configuración real del usuario (solo como DATOS).
_backup_collect() {
  local id p src=""
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
  if [[ -f "$SCRIPT_DIR/source-dir" ]]; then
    IFS= read -r src < "$SCRIPT_DIR/source-dir" || true
    if [[ "$src" == /* ]]; then all+=("$src/config"); fi
  fi
  # La contraseña de restic nunca viaja dentro de sus propios repositorios.
  # (restic.env SÍ se respalda, cifrado: hace falta para recuperarse de un
  # desastre; ver ROADMAP v2.5.)
  excl+=("$BACKUP_PASSWORD_FILE" "$SECRETS_DIR/.restic-password.*")

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

# Estado de un contenedor: 0 corriendo; 1 detenido; 2 error de docker (no se
# sabe); 3 no existe ("No such object/container").
_backup_container_state() {
  local out rc=0
  out="$(hli_docker inspect -f '{{.State.Running}}' "$1" 2>&1 </dev/null)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    [[ "$out" == "true" ]] && return 0
    return 1
  fi
  case "$out" in
    *"No such"*|*"no such"*) return 3 ;;
  esac
  return 2
}

# 0 = corriendo; 1 = detenido o inexistente; 2 = error de docker (no se sabe).
_backup_container_running() {
  local rc=0
  _backup_container_state "$1" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1|3) return 1 ;;
  esac
  return 2
}

# Lista de contenedores a detener, guardada ANTES de detener nada: si el proceso
# muere (o el equipo se reinicia) a mitad de la ventana, 'recover' sabe qué
# levantar ('restart: unless-stopped' no reinicia un contenedor parado a mano).
_backup_recovery_write() {
  local tmp c
  local -A seen=()
  local -a all=()
  tmp="$(mktemp "$BACKUP_STATE_DIR/.recovery.XXXXXX")" || return 1
  # Unión con lo que una corrida anterior dejó sin levantar: nunca se pisa.
  if [[ -s "$BACKUP_RECOVERY_FILE" ]]; then
    while IFS= read -r c; do
      if [[ -n "$c" && -z "${seen[$c]:-}" ]]; then seen[$c]=1; all+=("$c"); fi
    done < "$BACKUP_RECOVERY_FILE"
  fi
  for c in "$@"; do
    if [[ -z "${seen[$c]:-}" ]]; then seen[$c]=1; all+=("$c"); fi
  done
  printf '%s\n' "${all[@]}" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$BACKUP_RECOVERY_FILE"
}

# Saca $1 de la lista de recuperación (ya está corriendo, o ya no existe); si
# no queda nada, borra el archivo. Lo demás se conserva.
_backup_recovery_drop() {
  local c tmp
  local -a keep=()
  [[ -f "$BACKUP_RECOVERY_FILE" ]] || return 0
  while IFS= read -r c; do
    if [[ -n "$c" && "$c" != "$1" ]]; then keep+=("$c"); fi
  done < "$BACKUP_RECOVERY_FILE"
  if [[ ${#keep[@]} -eq 0 ]]; then
    rm -f -- "$BACKUP_RECOVERY_FILE"
    return 0
  fi
  tmp="$(mktemp "$BACKUP_STATE_DIR/.recovery.XXXXXX")" || return 1
  printf '%s\n' "${keep[@]}" > "$tmp"
  mv -f -- "$tmp" "$BACKUP_RECOVERY_FILE"
}

# Detiene los contenedores sqlite que estén corriendo. Cada nombre se anota
# ANTES de detenerlo: si 'docker stop' falla a medias, igual se intenta
# levantarlo después. Devuelve 1 si alguno no se pudo detener (la foto sería
# inconsistente: el llamador no la toma). Un error de docker al consultar el
# estado NO es "detenido": queda como aviso (podría haberse copiado en vivo).
_backup_stop_sqlite() {
  local c rc
  local -a todo=()
  while read -r c; do
    [[ -n "$c" ]] || continue
    rc=0
    _backup_container_running "$c" || rc=$?
    case "$rc" in
      0) todo+=("$c") ;;
      1) ;;
      *)
        _backup_worse warning
        _backup_msg_add "no se pudo consultar el estado de '$c': puede haberse copiado en vivo"
        ;;
    esac
  done < <(_backup_sqlite_containers)

  if [[ ${#todo[@]} -gt 0 ]]; then
    _backup_recovery_write "${todo[@]}" || { hli_error "no se pudo guardar la lista de recuperación"; return 1; }
  fi
  for c in "${todo[@]}"; do
    BACKUP_STOPPED_CONTAINERS+="$c "
    _backup_log "Deteniendo '$c' para la copia consistente"
    if ! hli_docker stop -t "$BACKUP_STOP_TIMEOUT" "$c" >/dev/null 2>&1 </dev/null; then
      hli_error "no se pudo detener '$c'"
      return 1
    fi
  done
  return 0
}

# Levanta un contenedor y comprueba que de verdad queda corriendo (con
# reintentos): un 'docker stop' de un cliente ya muerto puede seguir
# deteniéndolo en el daemon, y 'docker start' sobre algo "a medio parar" no
# sirve. Devuelve 1 si no queda corriendo dentro de BACKUP_RESTART_WAIT.
_backup_restart_container() {
  local c="$1" waited=0 rc=0
  # Si el contenedor ya no existe (se redesplegó con otro nombre, se borró), no
  # hay nada que levantar: no se espera ni se queda en la lista para siempre.
  _backup_container_state "$c" || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    _backup_log "'$c' ya no existe: se descarta de la lista de recuperación"
    return 0
  fi
  while true; do
    hli_docker start "$c" >/dev/null 2>&1 </dev/null || true
    sleep "$BACKUP_RESTART_SETTLE"
    rc=0
    _backup_container_running "$c" || rc=$?
    [[ "$rc" -eq 0 ]] && return 0
    (( waited >= BACKUP_RESTART_WAIT )) && break
    sleep "$BACKUP_RESTART_POLL"
    waited=$(( waited + BACKUP_RESTART_POLL ))
  done
  hli_error "no se pudo volver a iniciar '$c'. Inícielo a mano: sudo docker start $c"
  return 1
}

# Vuelve a levantar lo que este proceso detuvo. Devuelve 1 si alguno no volvió
# (queda en la lista de recuperación y en BACKUP_STOPPED_CONTAINERS).
backup_restart_stopped() {
  local c remaining=""
  for c in $BACKUP_STOPPED_CONTAINERS; do
    _backup_log "Iniciando '$c'"
    if _backup_restart_container "$c"; then
      _backup_recovery_drop "$c" || true
    else
      remaining+="$c "
    fi
  done
  BACKUP_STOPPED_CONTAINERS="$remaining"
  [[ -z "$remaining" ]]
}

# Levanta lo que una corrida anterior dejó detenido (proceso muerto, corte de
# luz). Al inicio de cada 'run', en 'hli2-backup recover' (ExecStopPost y
# arranque del equipo). Devuelve 1 si algo no pudo levantarse.
backup_recover() {
  local c bad=0 blocked
  local -a names=()
  # Una restauración que murió a medias se deshace ANTES de iniciar nada (ver
  # lib/restore.sh): sin eso Docker crearía carpetas vacías donde falta la de datos.
  if ! restore_journal_recover; then
    hli_error "no se pudo deshacer una restauración interrumpida (ver restore-swap-journal.failed en $BACKUP_STATE_DIR)"
    bad=1
  fi
  # Mientras exista el diario .failed, los contenedores de los servicios afectados NO se
  # inician (ni ahora ni en las siguientes llamadas); los demás sí.
  blocked=" $(restore_journal_blocked_containers | tr '\n' ' ') "
  [[ -s "$BACKUP_RECOVERY_FILE" ]] || return "$bad"
  while IFS= read -r c; do
    if [[ "$c" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then names+=("$c"); fi
  done < "$BACKUP_RECOVERY_FILE"
  for c in "${names[@]}"; do
    if [[ "$blocked" == *" $c "* ]]; then
      _backup_log "Recuperación: NO se inicia '$c': su restauración quedó sin revertir (resuélvala y borre restore-swap-journal.failed)"
      bad=1
      continue
    fi
    _backup_log "Recuperación: iniciando '$c' (quedó detenido por un backup anterior)"
    # Lo que levanta sale de la lista; lo que no, se conserva para el próximo intento.
    if _backup_restart_container "$c" </dev/null; then
      _backup_recovery_drop "$c" || true
    else
      bad=1
    fi
  done
  return "$bad"
}

# Boot/ExecStopPost: una corrida que murió dejó 'running' en el estado; se
# reescribe como 'interrupted' (llamar solo con el bloqueo tomado).
backup_status_mark_stale() {
  [[ "$(backup_status_get result)" == "running" ]] || return 0
  BK_RESULT=interrupted BK_LOCAL=unknown BK_CLOUD=unknown BK_CHECK=unknown
  BK_ID_FULL="$(backup_status_get snapshot_full)" BK_ID_CLOUD="$(backup_status_get snapshot_cloud)"
  BK_MSG="el backup anterior quedó interrumpido (reinicio, corte de luz o proceso terminado)"
  _backup_status_write
}

# Trap EXIT de bin/hli2-backup: lo detenido SIEMPRE se levanta, una corrida
# cortada deja 'interrupted' en el estado, y las credenciales cargadas no
# sobreviven al proceso. Lo PRIMERO es ignorar nuevas señales: una segunda
# Ctrl+C/TERM no puede abortar el bucle de reinicio, ni un SIGPIPE por la tubería
# rota de una terminal colgada.
backup_exit_cleanup() {
  trap '' INT TERM HUP PIPE
  local rc=0 f
  backup_restart_stopped || rc=1
  if [[ "$BK_ACTIVE" == "1" ]]; then
    BK_RESULT=interrupted BK_LOCAL=unknown BK_CLOUD=unknown BK_CHECK=unknown
    _backup_msg_add "el backup se interrumpió antes de terminar"
    [[ "$rc" -eq 0 ]] || _backup_msg_add "algún contenedor no volvió a iniciar (revise el log)"
    _backup_status_write || true
    BK_ACTIVE=0
  fi
  for f in "${BK_TMP_FILES[@]}"; do rm -f -- "$f"; done
  BK_TMP_FILES=()
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

# Repositorio local como destino con R2 como origen (recuperación ante un desastre:
# 'init --from-repo' con las claves de R2 en el entorno de ESE proceso).
_backup_restic_local_from_r2() {
  RESTIC_REPOSITORY="$BACKUP_ROOT" RESTIC_PASSWORD_FILE="$BACKUP_PASSWORD_FILE" \
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

# ¿Hay una copia externa configurada (restic.env con repositorio)? Sin cargar
# ni exponer nada. La usan backup-setup y backup-restore.
backup_r2_configured() {
  secret_file_exists restic && secret_get restic RESTIC_REPOSITORY >/dev/null 2>&1
}

# Corre "$@" mostrando la salida (terminal/log) y guardándola en $1. Devuelve
# el código de salida del comando (no el de tee).
_backup_tee() {
  local out="$1" rc=0
  shift
  "$@" 2>&1 | tee "$out" || rc="${PIPESTATUS[0]}"
  return "$rc"
}

# Toma la foto con tag $1 (full|cloud|warmup). Deja el id en BK_LAST_ID. Devuelve
# el código de restic (3 = foto creada pero con archivos ilegibles).
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
  BK_TMP_FILES+=("$out")
  _backup_log "Foto local '$tag' (${#paths[@]} rutas)"
  _backup_tee "$out" _backup_restic_local backup --tag "$tag" --exclude-caches "${excl[@]}" -- "${paths[@]}" || rc=$?
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

# 0 = ya hay una foto 'full'; 1 = ninguna; 2 = no se pudo saber.
_backup_has_full_snapshot() {
  local out n
  out="$(_backup_restic_local snapshots --tag full --json 2>/dev/null)" || return 2
  n="$(printf '%s' "$out" | jq 'length' 2>/dev/null)" || return 2
  [[ "$n" =~ ^[0-9]+$ ]] || return 2
  (( n > 0 ))
}

# Primera corrida: una pasada EN VIVO (servicios arriba, foto 'warmup' que se
# olvida al final) para que la pasada con los servicios detenidos sea corta
# (restic la toma como foto previa y solo relee lo que cambió).
_backup_warmup() {
  local rc=0
  BK_WARMUP_ID=""
  _backup_has_full_snapshot || rc=$?
  [[ "$rc" -eq 1 ]] || return 0
  _backup_log "Primera copia: pasada previa con los servicios en marcha"
  rc=0
  _backup_snapshot warmup || rc=$?
  if [[ "$rc" -eq 0 || "$rc" -eq 3 ]]; then
    BK_WARMUP_ID="$BK_LAST_ID"
  else
    _backup_worse warning
    _backup_msg_add "falló la pasada previa (la parada será más larga)"
  fi
  return 0
}

_backup_warmup_forget() {
  [[ -n "$BK_WARMUP_ID" ]] || return 0
  _backup_restic_local forget "$BK_WARMUP_ID" || { _backup_worse warning; _backup_msg_add "no se pudo olvidar la foto previa"; }
  BK_WARMUP_ID=""
  return 0
}

_backup_forget() {
  local which="$1" rc=0
  # 'run --no-retention' (backup de seguridad previo a una restauración): la
  # retención podría borrar justo la foto que el usuario eligió restaurar.
  if [[ "${BK_NO_RETENTION:-0}" == "1" ]]; then
    _backup_log "Retención ($which) omitida (--no-retention)"
    return 0
  fi
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
  local tmp
  tmp="$(mktemp "$BACKUP_STATE_DIR/.status.XXXXXX")" || return 1
  {
    printf 'timestamp=%s\n' "${BK_TS:-$(date -Is)}"
    printf 'result=%s\n' "$BK_RESULT"
    printf 'local=%s\n' "$BK_LOCAL"
    printf 'cloud=%s\n' "$BK_CLOUD"
    printf 'check=%s\n' "$BK_CHECK"
    printf 'snapshot_full=%s\n' "$BK_ID_FULL"
    printf 'snapshot_cloud=%s\n' "$BK_ID_CLOUD"
    printf 'message=%s\n' "$BK_MSG"
    if [[ -n "$BK_LAST_SKIP" ]]; then printf 'last_skip=%s\n' "$BK_LAST_SKIP"; fi
  } > "$tmp"
  chmod 0644 "$tmp"
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
    running) echo "en curso" ;;
    interrupted) echo "INTERRUMPIDO" ;;
    pending) echo "pendiente" ;;
    unknown) echo "desconocido" ;;
    not-configured) echo "no configurada" ;;
    skipped) echo "omitido" ;;
    *) echo "${1:-N/D}" ;;
  esac
}

# Texto del estado del último backup, para el dashboard y backup-now.
backup_status_summary() {
  local ts res msg when age
  if [[ -e "$RESTORE_JOURNAL_FAILED" ]]; then
    printf '  !! RESTAURACIÓN SIN REVERTIR: una restauración quedó a medias y no se pudo deshacer.\n'
    printf '     Los servicios afectados siguen DETENIDOS y no se podan los backups. Devuelva a mano\n'
    printf '     cada carpeta desde su copia .hli2-before-restore-* y borre %s\n' "$RESTORE_JOURNAL_FAILED"
    printf '     (pasos exactos: docs/VALIDACION.md, "Diario .failed"). Detalle: %s\n' "$(restore_status_get message)"
  fi
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
  # Un backup omitido (había una restauración en curso) NO refresca la fecha de
  # arriba: el aviso de "más de N horas" sigue valiendo.
  when="$(backup_status_get last_skip)"
  if [[ -n "$when" ]]; then
    when="${when/T/ }"
    printf '  Intento omitido: %s (restauración en curso)\n' "${when:0:16}"
  fi
  if [[ "$(restore_status_get reverted)" == "1" ]]; then
    printf '  AVISO         : la última restauración se revirtió (quedó a medias): %s\n' "$(restore_status_get message)"
  fi
  if age="$(date -d "$ts" +%s 2>/dev/null)" && (( $(date +%s) - age > BACKUP_STALE_HOURS * 3600 )); then
    printf '  AVISO         : el último backup tiene más de %s horas\n' "$BACKUP_STALE_HOURS"
  fi
  return 0
}

# --- Entradas principales --------------------------------------------------------

_backup_preflight() {
  command -v restic >/dev/null 2>&1 || { _backup_msg_add "restic no está instalado (ejecute backup-setup)"; return 1; }
  _backup_password_ok || { _backup_msg_add "falta la contraseña de restic o es inválida (ejecute backup-setup)"; return 1; }
  _backup_guard_fs || return 1
  [[ -f "$BACKUP_ROOT/config" ]] || { _backup_msg_add "el repositorio local no está inicializado (ejecute backup-setup)"; return 1; }
  _backup_secure_repo_dir
  return 0
}

# Un backup completo. Devuelve 1 si el resultado es 'error'. Los
# contenedores detenidos se levantan acá mismo apenas terminan las fotos, y
# además el trap de bin/hli2-backup (backup_exit_cleanup) cubre cualquier
# salida anormal.
#
# Orden (decidido a propósito):
#   [pasada previa en vivo, solo la primera vez] -> parada -> foto full ->
#   foto cloud -> reinicio -> olvidar la previa -> copia a R2 -> retención de
#   R2 (solo si se copió una foto nueva) -> retención local (después de la
#   copia, para que nada envejezca localmente sin haber llegado a R2) ->
#   chequeo semanal.
backup_run() {
  BK_ACTIVE=1
  BK_RESULT=ok BK_LOCAL=ok BK_CLOUD=not-configured BK_CHECK=skipped
  BK_ID_FULL="" BK_ID_CLOUD="" BK_MSG="" BK_WARMUP_ID=""
  local r2=0 copied=0 rc=0

  if ! _backup_state_dir_ensure; then
    _backup_log "ERROR: $BK_MSG"
    BK_ACTIVE=0
    return 1
  fi
  # Estado 'running' desde el principio: una corrida cortada no deja un 'ok' viejo.
  BK_RESULT=running BK_LOCAL=pending BK_CLOUD=pending BK_CHECK=pending
  _backup_status_write || true
  BK_RESULT=ok BK_LOCAL=ok BK_CLOUD=not-configured BK_CHECK=skipped
  _backup_log "Inicio del backup"

  if ! backup_recover; then
    _backup_worse warning
    _backup_msg_add "quedaron contenedores sin iniciar de una corrida anterior"
  fi

  if [[ -e "$RESTORE_JOURNAL_FAILED" ]]; then
    # Hay una restauración sin revertir: las fotos se siguen tomando, pero NO se poda
    # ningún repositorio (podría borrar justo las fotos buenas anteriores).
    BK_NO_RETENTION=1
    _backup_worse warning
    _backup_msg_add "retención omitida: hay una restauración sin revertir (restore-swap-journal.failed); resuélvala y borre ese archivo"
  fi

  if ! _backup_preflight; then
    BK_RESULT=error BK_LOCAL=error BK_CLOUD=skipped
    _backup_log "ERROR: $BK_MSG"
    _backup_status_write || true
    BK_ACTIVE=0
    return 1
  fi

  _backup_collect
  _backup_warmup

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
  _backup_warmup_forget

  if backup_r2_load; then
    r2=1
    BK_CLOUD=ok
    _backup_log "Copia externa (R2)"
    _backup_restic_r2 copy --from-repo "$BACKUP_ROOT" --from-password-file "$BACKUP_PASSWORD_FILE" --tag cloud || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      BK_CLOUD=error
      _backup_worse error
      _backup_msg_add "falló la copia externa a R2 (código $rc)"
    else
      copied=1
    fi
  fi
  # Sin foto cloud nueva copiada, no se poda R2 (prune es caro y no hay nada
  # nuevo que justificarlo).
  if [[ "$copied" -eq 1 && -n "$BK_ID_CLOUD" ]]; then _backup_forget r2; fi
  if [[ "$BK_CLOUD" == "error" ]]; then
    _backup_worse warning
    _backup_msg_add "retención local omitida hasta que la copia externa funcione"
  else
    _backup_forget local
  fi

  _backup_check "$r2"

  _backup_status_write
  BK_ACTIVE=0
  _backup_log "Fin del backup: $BK_RESULT (local=$BK_LOCAL, externa=$BK_CLOUD)"
  [[ "$BK_RESULT" != "error" ]]
}

# Clasifica la salida de 'restic cat config' ($2, código $1) cuando NO pudo abrir el
# repositorio de R2 ni dijo "contraseña equivocada". Imprime:
#   missing    positivo y explícito: el repositorio no existe (código 10 de restic >= 0.17,
#              o "specified key does not exist"/NoSuchKey de la clave S3 de 0.16);
#   blocked    hay un marcador de acceso, red o bucket (403, claves inválidas, DNS, timeout...);
#   ambiguous  ninguna de las dos.
# El aviso "Is there a repository at the following location?" lo imprime restic también
# ante un 403 o un fallo de DNS, así que por sí solo no prueba nada. Las URL se quitan del
# texto (no la línea entera): el id de cuenta, hexadecimal al azar, podría contener "403"
# o "401" y confundir la detección sin perder el "Fatal ... does not exist" de esa línea.
_backup_r2_cat_state() {
  local rc="$1" out
  out="$(printf '%s\n' "$2" | sed -E 's#(s3:)?https?://[^[:space:]]*# #g')"
  out="${out,,}"
  case "$out" in
    *403*|*forbidden*|*accessdenied*|*"access denied"*|*invalidaccesskeyid*|*signaturedoesnotmatch*|*unauthorized*|*401*|*"no such host"*|*timeout*|*"timed out"*|*"deadline exceeded"*|*"connection refused"*|*"dial tcp"*|*x509*|*"tls:"*|*nosuchbucket*|*"specified bucket"*|*"temporary failure"*|*"network is unreachable"*)
      echo blocked
      return 0
      ;;
  esac
  if [[ "$rc" -eq 10 ]]; then echo missing; return 0; fi
  case "$out" in
    *"specified key does not exist"*|*nosuchkey*) echo missing; return 0 ;;
  esac
  echo ambiguous
}

# 0 si la salida dice POSITIVAMENTE que el repositorio no existe.
_backup_r2_repo_missing() {
  [[ "$(_backup_r2_cat_state "$1" "$2")" == "missing" ]]
}

# Inicializa los repositorios que falten (idempotente). Como root. Con R2
# configurado se comprueba PRIMERO ('restic cat config'); solo después se crea nada:
#   - la contraseña no abre un repositorio existente -> error, no se inicializa NADA
#     (recuperación ante un desastre con la contraseña equivocada: se reintenta
#     con la correcta);
#   - el repositorio existe -> el local nuevo se crea con los parámetros de troceado
#     de R2 ('init --from-repo <R2> --copy-chunker-params'), así lo que se copie
#     después se deduplica contra lo ya subido;
#   - no existe (señal positiva: "Is there a repository at the following location?"
#     de la clave S3 inexistente) -> se crea el local y, desde él, el de R2;
#   - cualquier otro error (red, claves, bucket, endpoint) -> error, no se inicializa
#     nada: nunca se inicializa ante una señal ambigua.
backup_init() {
  local rc=0 r2="missing" cat_out
  BK_MSG=""
  command -v restic >/dev/null 2>&1 || { echo "ERROR: restic no está instalado." >&2; return 1; }
  _backup_state_dir_ensure || { echo "ERROR: $BK_MSG" >&2; return 1; }
  _backup_password_ok || { echo "ERROR: falta la contraseña de restic o es inválida ($BACKUP_PASSWORD_FILE)." >&2; return 1; }
  if ! _backup_guard_fs; then echo "ERROR: $BK_MSG" >&2; return 1; fi
  install -d -m 0700 "$BACKUP_ROOT"
  _backup_secure_repo_dir

  if backup_r2_load; then
    cat_out="$(_backup_restic_r2 cat config 2>&1 </dev/null)" && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      r2="exists"
    elif [[ "$rc" -eq 12 || "$cat_out" == *"wrong password"* ]]; then
      # El repositorio de R2 ya existe y esta contraseña no lo abre (típico en una
      # recuperación ante un desastre: no es la misma que se usó al crear los backups).
      echo "ERROR: el repositorio de R2 ya existe y la contraseña de restic no lo abre. Use la MISMA contraseña con la que se crearon los backups (Vaultwarden o papel). No se inicializó nada." >&2
      _BK_R2_REPO="" _BK_R2_KEY="" _BK_R2_SECRET="" _BK_R2_REGION=""
      return 1
    else
      case "$(_backup_r2_cat_state "$rc" "$cat_out")" in
        missing) r2="missing" ;;
        ambiguous)
          if [[ "$BK_R2_ASSUME_NEW" == "1" ]]; then
            # El usuario confirmó (en backup-setup, nunca en una recuperación ante un
            # desastre) que el bucket es nuevo y está vacío: restic no dio una señal
            # explícita, pero tampoco ningún marcador de acceso o red.
            _backup_log "R2: respuesta ambigua; se inicializa porque se indicó que el bucket es nuevo y está vacío"
            r2="missing"
          else
            echo "ERROR: no se pudo determinar si el repositorio de R2 existe (respuesta ambigua de restic). No se inicializó nada. Detalle: $(printf '%s' "$cat_out" | tail -n 2 | tr '\n' ' ')" >&2
            _BK_R2_REPO="" _BK_R2_KEY="" _BK_R2_SECRET="" _BK_R2_REGION=""
            return "$BACKUP_INIT_RC_AMBIGUOUS"
          fi
          ;;
        *)
          echo "ERROR: no se pudo comprobar el repositorio de R2 (red, claves, bucket o endpoint). No se inicializó nada. Detalle: $(printf '%s' "$cat_out" | tail -n 2 | tr '\n' ' ')" >&2
          _BK_R2_REPO="" _BK_R2_KEY="" _BK_R2_SECRET="" _BK_R2_REGION=""
          return 1
          ;;
      esac
    fi
  else
    r2="none"
  fi

  if [[ -f "$BACKUP_ROOT/config" ]]; then
    # Repositorio local existente: la contraseña tiene que abrirlo (si no, es otra:
    # no se da por buena ni se sigue).
    cat_out="$(_backup_restic_local cat config 2>&1 </dev/null)" && rc=0 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      if [[ "$rc" -eq 12 || "$cat_out" == *"wrong password"* ]]; then
        echo "ERROR: la contraseña de restic no abre el repositorio local existente ($BACKUP_ROOT). Use la contraseña con la que se creó (Vaultwarden o papel)." >&2
      else
        echo "ERROR: no se pudo comprobar el repositorio local existente. Detalle: $(printf '%s' "$cat_out" | tail -n 2 | tr '\n' ' ')" >&2
      fi
      _BK_R2_REPO="" _BK_R2_KEY="" _BK_R2_SECRET="" _BK_R2_REGION=""
      return 1
    fi
  fi
  if [[ ! -f "$BACKUP_ROOT/config" ]]; then
    if [[ "$r2" == "exists" ]]; then
      _backup_log "Inicializando el repositorio local con los parámetros de R2"
      _backup_restic_local_from_r2 init --from-repo "$_BK_R2_REPO" --from-password-file "$BACKUP_PASSWORD_FILE" --copy-chunker-params \
        || { echo "ERROR: no se pudo inicializar el repositorio local." >&2; return 1; }
    else
      _backup_log "Inicializando el repositorio local"
      _backup_restic_local init || { echo "ERROR: no se pudo inicializar el repositorio local." >&2; return 1; }
    fi
  fi
  if [[ "$r2" == "missing" ]]; then
    rc=0
    _backup_log "Inicializando el repositorio en R2"
    # Mismos parámetros de chunking que el repo local: 'restic copy'
    # deduplica entre repos solo así.
    _backup_restic_r2 init --from-repo "$BACKUP_ROOT" --from-password-file "$BACKUP_PASSWORD_FILE" --copy-chunker-params || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "ERROR: no se pudo inicializar el repositorio en R2 (revise endpoint, bucket y claves)." >&2
      return 1
    fi
  fi
  _BK_R2_REPO="" _BK_R2_KEY="" _BK_R2_SECRET="" _BK_R2_REGION=""
  return 0
}
