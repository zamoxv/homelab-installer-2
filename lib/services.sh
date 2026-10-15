#!/usr/bin/env bash
# Registro declarativo de servicios: fuente única de verdad para el
# dashboard, el healthcheck y (más adelante) el backup/restore. Cada archivo
# services/<id>.conf define variables SERVICE_*; nada de puertos ni rutas de
# servicios se hardcodea fuera de acá.
#
# Campos de un services/<id>.conf:
#   SERVICE_NAME         Nombre para mostrar.
#   SERVICE_KIND         "native" (unidad systemd), "container" (Docker) o
#                        "swarm" (servicio de Docker Swarm).
#   SERVICE_UNIT         Unidad systemd (solo si KIND=native).
#   SERVICE_CONTAINER    Nombre del contenedor (KIND=container) o del
#                        servicio de swarm (KIND=swarm).
#   SERVICE_PORT         Puerto de acceso, o vacío si no expone uno directo.
#   SERVICE_URL_SCHEME   Esquema de la URL (http, smb...), vacío si no aplica.
#   SERVICE_DATA         Array de rutas de datos persistentes bajo APPDATA_ROOT.
#   SERVICE_BACKUP_KIND  "files" | "sqlite" | "db-dump-dokploy" | "none".
#                        "sqlite" cubre cualquier base embebida (SQLite,
#                        bbolt...): el backup detiene el contenedor durante
#                        la foto local (lib/backup.sh).
#   SERVICE_BACKUP_EXCLUDE     Array de rutas de SERVICE_DATA que NUNCA se
#                        respaldan (cachés regenerables).
#   SERVICE_BACKUP_LOCAL_ONLY  Array de rutas de SERVICE_DATA que solo van a
#                        la copia local, no a la externa (R2).
set -euo pipefail

SERVICES_DIR="$SCRIPT_DIR/services"

# Registro LOCAL: servicios propios del usuario (no incluidos en el repositorio
# público), con el mismo formato que services/*.conf. Viven en un directorio
# root-owned FUERA de /etc/hli2 (que es root 0700 y guarda secretos): el usuario
# y el dashboard necesitan poder LEERLOS. Se hace 'source' de estos archivos,
# así que solo se cargan si cumplen todas las condiciones de
# _service_local_file_ok y _service_local_fields_ok (ver más abajo). El id de
# un servicio local nunca puede coincidir con el de uno incluido: gana el
# incluido y el archivo local se ignora (service_local_report lo informa).
# 'HLI2_LOCAL_SERVICES_EXPECT_UID' existe solo para los tests (corren como un
# usuario normal; en producción es siempre 0 = root).
LOCAL_SERVICES_DIR="${HLI2_LOCAL_SERVICES_DIR:-/etc/hli2.d/services}"
LOCAL_SERVICES_EXPECT_UID="${HLI2_LOCAL_SERVICES_EXPECT_UID:-0}"

# Ruta de dato apta para tocar como root: absoluta, sin '..', sin caracteres de
# patrón de restic ni espacios, y nunca '/' ni una carpeta de primer nivel.
# (Única definición: la usa también _restore_path_ok en lib/restore.sh.)
_service_path_ok() {
  local p="$1"
  [[ "$p" =~ ^/[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || return 1
  # Ningún segmento puede ser '.' ni '..' (tampoco al final: '/x/.').
  [[ "/$p/" != *"/../"* && "/$p/" != *"/./"* ]] || return 1
  # Forma canónica (sin '//' ni barra final); -s: sin resolver enlaces.
  [[ "$(realpath -m -s -- "$p" 2>/dev/null)" == "$p" ]]
}

# Revisión de un .conf local ANTES de hacer 'source' (solo estos archivos los
# lee root, así que se acepta únicamente un subconjunto inofensivo): líneas en
# blanco, comentarios y asignaciones 'SERVICE_X="texto"' o
# 'SERVICE_X=("texto" "texto")' de una sola línea. Se rechaza todo lo que
# ejecute o redirija ($(, comillas invertidas, ; & | < >, barra invertida) y
# cualquier '$' que no sea $APPDATA_ROOT / ${APPDATA_ROOT}. Imprime el motivo.
_service_conf_lint() {
  local f="$1" line t n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$(( n + 1 ))
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ ! "$line" =~ ^SERVICE_[A-Z_]+=(\"[^\"]*\"|\(([[:space:]]*\"[^\"]*\")*[[:space:]]*\))$ ]]; then
      echo "línea $n no permitida (solo SERVICE_X=\"valor\" o SERVICE_X=(\"a\" \"b\"))"; return 1
    fi
    if [[ "$line" == *'$('* || "$line" == *'`'* || "$line" == *';'* || "$line" == *'&'* \
          || "$line" == *'|'* || "$line" == *'<'* || "$line" == *'>'* || "$line" == *'\'* ]]; then
      echo "línea $n con caracteres no permitidos"; return 1
    fi
    if [[ "$line" =~ \$APPDATA_ROOT[A-Za-z0-9_] ]]; then echo "línea $n con una variable no permitida"; return 1; fi
    t="${line//'${APPDATA_ROOT}'/}"
    t="${t//'$APPDATA_ROOT'/}"
    if [[ "$t" == *'$'* ]]; then echo "línea $n usa una variable distinta de APPDATA_ROOT"; return 1; fi
  done < "$f"
  return 0
}

# ¿Se solapan las rutas $1 y $2 (iguales, o una dentro de la otra)?
_service_paths_overlap() {
  [[ "$1" == "$2" || "$1" == "$2/"* || "$2" == "$1/"* ]]
}

# Rutas de datos de los servicios incluidos (una por línea).
_service_shipped_data() {
  local f
  for f in "$SERVICES_DIR"/*.conf; do
    [[ -f "$f" ]] || continue
    ( _service_reset; source "$f" 2>/dev/null; [[ ${#SERVICE_DATA[@]} -eq 0 ]] || printf '%s\n' "${SERVICE_DATA[@]}" ) || true
  done
}

# ¿$1 es de root (o del uid esperado en tests) y no escribible por grupo/otros?
_service_local_owner_ok() {
  local uid mode
  read -r uid mode < <(stat -c '%u %a' -- "$1" 2>/dev/null) || return 1
  [[ "$uid" == "$LOCAL_SERVICES_EXPECT_UID" ]] || return 1
  (( 8#$mode & 8#022 )) && return 1
  return 0
}

# El directorio del registro local es usable: existe, no es un enlace simbólico
# y ni él ni su padre (/etc/hli2.d) son escribibles por otros.
_service_local_dir_ok() {
  local d="$LOCAL_SERVICES_DIR"
  [[ -d "$d" && ! -L "$d" ]] || return 1
  _service_local_owner_ok "$d" || return 1
  _service_local_owner_ok "$(dirname -- "$d")"
}

# Archivo local $1 (id) aceptable para 'source': nombre válido, archivo regular
# (no enlace), de root, sin escritura para grupo/otros. Imprime el motivo si no.
_service_local_file_ok() {
  local id="$1" f="$LOCAL_SERVICES_DIR/$1.conf"
  if [[ ! "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then echo "nombre de archivo inválido (use minúsculas, números y guiones)"; return 1; fi
  if ! _service_local_dir_ok; then echo "el directorio $LOCAL_SERVICES_DIR (o su padre) no es de root o es escribible por otros"; return 1; fi
  if [[ -L "$f" || ! -f "$f" ]]; then echo "no es un archivo regular (los enlaces simbólicos se rechazan)"; return 1; fi
  if ! _service_local_owner_ok "$f"; then echo "no es de root o es escribible por grupo/otros"; return 1; fi
  if [[ -f "$SERVICES_DIR/$id.conf" ]]; then echo "el id coincide con un servicio incluido: se usa el incluido y se ignora este archivo"; return 1; fi
  return 0
}

# Valida las variables SERVICE_* ya cargadas de un servicio local. Imprime el
# motivo si no es válido. Solo contenedores Docker; las rutas de datos tienen
# que quedar bajo $APPDATA_ROOT y las exclusiones, ser rutas de sus propios datos.
_service_local_fields_ok() {
  local p q found
  if [[ -z "${SERVICE_NAME:-}" || "$SERVICE_NAME" == *$'\n'* || ${#SERVICE_NAME} -gt 60 ]]; then echo "SERVICE_NAME vacío o inválido"; return 1; fi
  if [[ "${SERVICE_KIND:-}" != "container" ]]; then echo "SERVICE_KIND debe ser \"container\""; return 1; fi
  if [[ ! "${SERVICE_CONTAINER:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; then echo "SERVICE_CONTAINER inválido"; return 1; fi
  if [[ ! "${SERVICE_PORT:-}" =~ ^[0-9]{0,5}$ ]]; then echo "SERVICE_PORT inválido"; return 1; fi
  if [[ ! "${SERVICE_URL_SCHEME:-}" =~ ^[a-z]{0,10}$ ]]; then echo "SERVICE_URL_SCHEME inválido"; return 1; fi
  case "${SERVICE_BACKUP_KIND:-}" in
    files|sqlite|none) ;;
    *) echo "SERVICE_BACKUP_KIND debe ser files, sqlite o none"; return 1 ;;
  esac
  for p in "${SERVICE_DATA[@]}"; do
    if ! _service_path_ok "$p" || [[ "$p" != "$APPDATA_ROOT/"* || -z "${p#"$APPDATA_ROOT"/}" ]]; then
      echo "SERVICE_DATA debe ser una ruta absoluta válida bajo $APPDATA_ROOT: $p"; return 1
    fi
  done
  local shipped sys
  shipped="$(_service_shipped_data)"
  for p in "${SERVICE_DATA[@]}"; do
    while IFS= read -r q; do
      if [[ -n "$q" ]] && _service_paths_overlap "$p" "$q"; then echo "SERVICE_DATA coincide o se anida con los datos de un servicio incluido: $p"; return 1; fi
    done <<< "$shipped"
    for sys in "${SECRETS_DIR:-}" "${STATE_DIR:-}" "${BACKUP_ROOT:-}"; do
      if [[ -n "$sys" ]] && _service_paths_overlap "$p" "$sys"; then echo "SERVICE_DATA coincide o se anida con una ruta del sistema ($sys): $p"; return 1; fi
    done
  done
  for p in "${SERVICE_BACKUP_EXCLUDE[@]}" "${SERVICE_BACKUP_LOCAL_ONLY[@]}"; do
    found=0
    for q in "${SERVICE_DATA[@]}"; do [[ "$p" == "$q" ]] && found=1; done
    if [[ "$found" -eq 0 ]]; then echo "las exclusiones deben ser rutas de SERVICE_DATA: $p"; return 1; fi
  done
  return 0
}

# Resetea las variables SERVICE_* (para que no arrastre las del servicio anterior).
_service_reset() {
  unset SERVICE_NAME SERVICE_KIND SERVICE_UNIT SERVICE_CONTAINER \
        SERVICE_PORT SERVICE_URL_SCHEME SERVICE_BACKUP_KIND 2>/dev/null || true
  SERVICE_DATA=()
  SERVICE_BACKUP_EXCLUDE=()
  SERVICE_BACKUP_LOCAL_ONLY=()
}

# Carga un servicio local ya aceptado por _service_local_file_ok y valida sus
# campos. Imprime el motivo si no es válido.
_service_local_load() {
  local id="$1" why
  _service_reset
  why="$(_service_local_file_ok "$id")" || { echo "$why"; return 1; }
  why="$(_service_conf_lint "$LOCAL_SERVICES_DIR/$id.conf")" || { echo "$why"; return 1; }
  # shellcheck disable=SC1090
  source "$LOCAL_SERVICES_DIR/$id.conf" || { _service_reset; echo "el archivo tiene errores de sintaxis"; return 1; }
  why="$(_service_local_fields_ok)" || { _service_reset; echo "$why"; return 1; }
  return 0
}

# Ids locales válidos (uno por línea). Cada archivo se evalúa en un subshell:
# nada de lo que haga un .conf contamina al llamador.
_service_local_list() {
  local f id
  _service_local_dir_ok || return 0
  for f in "$LOCAL_SERVICES_DIR"/*.conf; do
    [[ -e "$f" || -L "$f" ]] || continue
    id="$(basename "$f" .conf)"
    if ( _service_local_load "$id" >/dev/null 2>&1 ); then printf '%s\n' "$id"; fi
  done
}

# Imprime una línea 'id<TAB>motivo' por cada archivo local rechazado. La usa el
# backup para dejar constancia en el log (service_list se mantiene en silencio).
service_local_report() {
  local f id why
  [[ -d "$LOCAL_SERVICES_DIR" ]] || return 0
  for f in "$LOCAL_SERVICES_DIR"/*; do
    [[ -e "$f" || -L "$f" ]] || continue
    id="$(basename "$f")"
    if [[ "$id" != *.conf ]]; then
      printf '%s\t%s\n' "$id" "no termina en .conf: se ignora"
      continue
    fi
    id="${id%.conf}"
    if why="$( ( _service_local_load "$id" ) 2>&1 )"; then continue; fi
    printf '%s\t%s\n' "$id" "${why//$'\n'/ }"
  done
  return 0
}

# ¿El servicio $1 es local (definido en el registro local)?
service_is_local() {
  [[ ! -f "$SERVICES_DIR/$1.conf" ]]
}

# Nombre para mostrar de $1: los locales llevan la marca "(local)".
service_display_name() {
  local name
  name="$(service_get "$1" NAME 2>/dev/null)" || name="$1"
  [[ -n "$name" ]] || name="$1"
  if service_is_local "$1"; then name="$name (local)"; fi
  printf '%s\n' "$name"
}

# IDs de servicios registrados (nombre de archivo sin .conf) más los locales
# válidos, orden alfabético.
service_list() {
  local f
  {
    for f in "$SERVICES_DIR"/*.conf; do
      [[ -f "$f" ]] || continue
      basename "$f" .conf
    done
    _service_local_list
  } | sort
}

# Carga en el shell actual las variables SERVICE_* del servicio $1, después de
# resetearlas, para que no arrastre valores del servicio leído antes. Un id que
# no es de los incluidos se busca en el registro local (con su validación).
_service_load() {
  local id="$1"
  local f="$SERVICES_DIR/$id.conf"
  if [[ ! -f "$f" ]]; then
    _service_local_load "$id" >/dev/null 2>&1
    return
  fi
  _service_reset
  # shellcheck disable=SC1090
  source "$f"
}

# Valor de un campo (NAME, KIND, UNIT, CONTAINER, PORT, URL_SCHEME,
# BACKUP_KIND) del servicio $1. DATA, BACKUP_EXCLUDE y BACKUP_LOCAL_ONLY son
# arrays: se imprime una ruta por línea (nada si el array está vacío; DATA
# conserva su comportamiento histórico).
service_get() {
  local id="$1" field="$2"
  _service_load "$id" || return 1
  if [[ "$field" == "DATA" ]]; then
    printf '%s\n' "${SERVICE_DATA[@]}"
  elif [[ "$field" == "BACKUP_EXCLUDE" ]]; then
    [[ ${#SERVICE_BACKUP_EXCLUDE[@]} -eq 0 ]] || printf '%s\n' "${SERVICE_BACKUP_EXCLUDE[@]}"
  elif [[ "$field" == "BACKUP_LOCAL_ONLY" ]]; then
    [[ ${#SERVICE_BACKUP_LOCAL_ONLY[@]} -eq 0 ]] || printf '%s\n' "${SERVICE_BACKUP_LOCAL_ONLY[@]}"
  else
    local var="SERVICE_${field}"
    printf '%s\n' "${!var:-}"
  fi
}

# Estado de una unidad systemd. 'systemctl cat' (sin tubería) evita el bug de
# 'grep -q' cerrando el pipe y disparando SIGPIPE en systemctl, que con
# 'pipefail' daba falso "no instalado".
_service_state_systemd() {
  local unit="$1" st
  [[ -n "$unit" ]] || { echo "no instalado"; return; }
  if systemctl cat "$unit" >/dev/null 2>&1; then
    st="$(systemctl is-active "$unit" 2>/dev/null || true)"
    case "$st" in
      active) echo "activo" ;;
      "") echo "inactivo" ;;
      *) echo "$st" ;;
    esac
  else
    echo "no instalado"
  fi
}

# Estado de un contenedor Docker. Usa hli_docker_presence/hli_docker (sudo -n
# docker), nunca 'command -v docker' pelado: root puede ver el binario
# aunque el usuario que corre HLI 2 no lo tenga en su PATH (snap,
# secure_path distinto...), y un 'docker' sin privilegios devuelve
# "permission denied" cuando el usuario no está en el grupo docker (el caso
# normal acá) — ninguna de las dos cosas es lo mismo que "no instalado", así
# que se informan como "desconocido" para no mentirle al dashboard. Si
# Docker está genuinamente ausente, se informa aparte.
_service_state_container() {
  local name="$1" presence
  presence="$(hli_docker_presence)"
  case "$presence" in
    absent) echo "docker no disponible"; return ;;
    unknown) echo "desconocido"; return ;;
  esac
  if ! hli_docker info >/dev/null 2>&1; then
    echo "desconocido"
    return
  fi
  if ! hli_docker inspect "$name" >/dev/null 2>&1; then
    echo "no instalado"
    return
  fi
  if [[ "$(hli_docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
    echo "activo"
  else
    echo "detenido"
  fi
}

# Estado de un servicio de Docker Swarm. A diferencia de un contenedor
# suelto, 'docker inspect <nombre>' no sirve acá: con swarm el contenedor
# real se llama "<servicio>.<slot>.<id>" (nombre generado, distinto en cada
# tarea). Se consulta el SERVICIO con 'docker service ls', que ya da
# directamente las réplicas listas (ej. "1/1"). Usa hli_docker_presence/
# hli_docker (sudo -n docker), nunca 'command -v docker' pelado (ver
# _service_state_container: mismo motivo, PATH del usuario vs. de root).
_service_state_swarm() {
  local name="$1" replicas presence
  presence="$(hli_docker_presence)"
  case "$presence" in
    absent) echo "docker no disponible"; return ;;
    unknown) echo "desconocido"; return ;;
  esac
  if ! hli_docker info >/dev/null 2>&1; then
    echo "desconocido"
    return
  fi
  replicas="$(hli_docker service ls --filter "name=$name" --format '{{.Replicas}}' 2>/dev/null | head -n1)" || true
  if [[ -z "$replicas" ]]; then
    echo "no instalado"
    return
  fi
  if [[ "$replicas" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    if [[ "${BASH_REMATCH[1]}" == "0" ]]; then
      echo "detenido"
    elif [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
      echo "activo"
    else
      echo "parcial ($replicas)"
    fi
  else
    echo "desconocido"
  fi
}

# Estado del servicio $1: activo | inactivo | detenido | parcial (N/M) |
# no instalado | docker no disponible | desconocido.
service_state() {
  local id="$1"
  _service_load "$id" || { echo "desconocido"; return; }
  case "$SERVICE_KIND" in
    native) _service_state_systemd "$SERVICE_UNIT" ;;
    container) _service_state_container "$SERVICE_CONTAINER" ;;
    swarm) _service_state_swarm "$SERVICE_CONTAINER" ;;
    *) echo "desconocido" ;;
  esac
}

# Espera hasta $2 segundos (default 120) a que service_state($1) devuelva
# "activo". Usada tras un despliegue (compose.deploy vía la API de Dokploy)
# para confirmar que el contenedor arrancó antes de mostrar la URL final.
# Best-effort: si se agota el tiempo, devuelve 1 pero no es un error fatal
# para el módulo llamador (el contenedor puede seguir iniciando).
service_wait_active() {
  local id="$1" timeout="${2:-120}" waited=0
  hli_busy "Esperando que $(service_get "$id" NAME 2>/dev/null || echo "$id") quede activo..."
  while [[ "$waited" -lt "$timeout" ]]; do
    [[ "$(service_state "$id")" == "activo" ]] && return 0
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# URL de acceso del servicio $1 (vacío si no expone una). Única fuente de
# puertos/URLs: la usan el dashboard, status y healthcheck.
service_url() {
  local id="$1" ip="${2:-$(get_ip)}"
  _service_load "$id" || return 1
  [[ -n "${SERVICE_URL_SCHEME:-}" ]] || { echo ""; return; }
  if [[ -n "${SERVICE_PORT:-}" ]]; then
    echo "${SERVICE_URL_SCHEME}://${ip}:${SERVICE_PORT}"
  else
    echo "${SERVICE_URL_SCHEME}://${ip}"
  fi
}
