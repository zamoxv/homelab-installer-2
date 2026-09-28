#!/usr/bin/env bash
# Registro declarativo de servicios: fuente única de verdad para el
# dashboard, el healthcheck y (más adelante) el backup/restore. Cada archivo
# services/<id>.conf define variables SERVICE_*; nada de puertos ni rutas de
# servicios se hardcodea fuera de acá.
#
# Campos de un services/<id>.conf:
#   SERVICE_NAME         Nombre para mostrar.
#   SERVICE_KIND         "native" (unidad systemd) o "container" (Docker).
#   SERVICE_UNIT         Unidad systemd (solo si KIND=native).
#   SERVICE_CONTAINER    Nombre del contenedor (solo si KIND=container).
#   SERVICE_PORT         Puerto de acceso, o vacío si no expone uno directo.
#   SERVICE_URL_SCHEME   Esquema de la URL (http, smb...), vacío si no aplica.
#   SERVICE_DATA         Array de rutas de datos persistentes bajo APPDATA_ROOT.
#   SERVICE_BACKUP_KIND  "files" | "sqlite" | "db-dump-dokploy" | "none".
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
  # shellcheck disable=SC1090
  source "$f"
}

# Valor de un campo (NAME, KIND, UNIT, CONTAINER, PORT, URL_SCHEME,
# BACKUP_KIND) del servicio $1. DATA es un array: se imprime una ruta por
# línea.
service_get() {
  local id="$1" field="$2"
  _service_load "$id" || return 1
  if [[ "$field" == "DATA" ]]; then
    printf '%s\n' "${SERVICE_DATA[@]}"
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

# Estado de un contenedor Docker. Si Docker no está instalado (v2.0 no lo
# instala: eso es v2.1), lo informa en vez de fallar.
_service_state_container() {
  local name="$1"
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker no disponible"
    return
  fi
  if ! docker inspect "$name" >/dev/null 2>&1; then
    echo "no instalado"
    return
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
    echo "activo"
  else
    echo "detenido"
  fi
}

# Estado del servicio $1: activo | inactivo | detenido | no instalado |
# docker no disponible | desconocido.
service_state() {
  local id="$1"
  _service_load "$id" || { echo "desconocido"; return; }
  case "$SERVICE_KIND" in
    native) _service_state_systemd "$SERVICE_UNIT" ;;
    container) _service_state_container "$SERVICE_CONTAINER" ;;
    *) echo "desconocido" ;;
  esac
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
