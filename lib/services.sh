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

# IDs de servicios registrados (nombre de archivo sin .conf), orden alfabético.
service_list() {
  local f
  for f in "$SERVICES_DIR"/*.conf; do
    [[ -f "$f" ]] || continue
    basename "$f" .conf
  done | sort
}

# Carga en el shell actual las variables SERVICE_* del servicio $1, después de
# resetearlas, para que no arrastre valores del servicio leído antes.
_service_load() {
  local id="$1"
  local f="$SERVICES_DIR/$id.conf"
  [[ -f "$f" ]] || return 1
  unset SERVICE_NAME SERVICE_KIND SERVICE_UNIT SERVICE_CONTAINER \
        SERVICE_PORT SERVICE_URL_SCHEME SERVICE_BACKUP_KIND 2>/dev/null || true
  SERVICE_DATA=()
  SERVICE_BACKUP_EXCLUDE=()
  SERVICE_BACKUP_LOCAL_ONLY=()
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
