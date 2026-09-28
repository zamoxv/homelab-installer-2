#!/usr/bin/env bash
# Núcleo de HLI 2: configuración, logging, estado, envoltorios de dialog y el
# sistema de plugins (descubrimiento y ejecución de módulos en modules/).
# Es el único archivo que los módulos necesitan sourcear: al final carga el
# resto de la biblioteca (hw.sh, storage.sh, services.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CONFIG_FILE="$SCRIPT_DIR/config/default.conf"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

SERVER_USER="${SERVER_USER:-$USER}"
[[ -n "$SERVER_USER" ]] || SERVER_USER="$USER"

MEDIA_GROUP="${MEDIA_GROUP:-media}"
MEDIA_ROOT="${MEDIA_ROOT:-/srv/media}"
APPDATA_ROOT="${APPDATA_ROOT:-/srv/appdata}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/backups}"

# Si config/default.conf no definió el array (o no existe el archivo), usar
# este valor por defecto.
if [[ -z "${MEDIA_FOLDERS+x}" ]]; then
  MEDIA_FOLDERS=(peliculas series musica libros fotos videos downloads transcode)
fi

LOG_DIR="/var/log/hli2"
STATE_DIR="/var/lib/hli2"
STATE_FILE="$STATE_DIR/state"

# Crea los directorios de runtime (log/estado) y deja apt/needrestart en modo
# no interactivo, imprescindible para módulos que corren en segundo plano bajo
# la barra de progreso (un prompt invisible colgaría la instalación).
ensure_runtime() {
  sudo mkdir -p "$LOG_DIR" "$STATE_DIR"
  sudo touch "$STATE_FILE"
  sudo chown -R "$USER:$USER" "$STATE_DIR" || true

  echo 'Dpkg::Options { "--force-confdef"; "--force-confold"; };' \
    | sudo tee /etc/apt/apt.conf.d/99hli2 >/dev/null
  if [[ -d /etc/needrestart ]]; then
    sudo mkdir -p /etc/needrestart/conf.d
    echo "\$nrconf{restart} = 'a';" \
      | sudo tee /etc/needrestart/conf.d/99hli2.conf >/dev/null
  fi
}

log() {
  local msg="$1"
  echo "[$(date '+%F %T')] $msg" | sudo tee -a "$LOG_DIR/install.log" >/dev/null
}

mark_done() {
  local module="$1"
  grep -qxF "$module" "$STATE_FILE" 2>/dev/null || echo "$module" >> "$STATE_FILE"
}

is_done() {
  local module="$1"
  grep -qxF "$module" "$STATE_FILE" 2>/dev/null
}

msg() {
  # Puramente informativo (un botón "Aceptar"): ESC o un fallo de dialog no
  # deben abortar el módulo que llamó a msg(), así que nunca propaga error.
  dialog --title "HLI 2" --msgbox "$1" 12 76 || true
}

confirm() {
  dialog --title "Confirmar" --yesno "$1" 12 76
}

input_box() {
  local title="$1"
  local prompt="$2"
  local default="${3:-}"
  dialog --title "$title" --inputbox "$prompt" 10 76 "$default" 3>&1 1>&2 2>&3
}

# --- Plugin system: descubrimiento y ejecución de módulos ---

# Valor de una clave de metadata (# HLI-<KEY>: valor) del módulo $1.
module_meta() {
  local module="$1" key="$2"
  sed -n "s/^# HLI-${key}:[[:space:]]*//p" "$SCRIPT_DIR/modules/$module.sh" | head -n1
}

# IDs de los módulos registrados en modules/, ordenados por HLI-ORDER.
# Agregar modules/x.sh con la metadata HLI-MODULE lo hace aparecer solo.
list_modules() {
  local f id order
  for f in "$SCRIPT_DIR"/modules/*.sh; do
    [[ -f "$f" ]] || continue
    grep -q '^# HLI-MODULE:' "$f" || continue
    id="$(basename "$f" .sh)"
    order="$(module_meta "$id" ORDER)"
    printf '%s\t%s\n' "${order:-999}" "$id"
  done | sort -n | cut -f2
}

# Ejecuta un módulo heredando la terminal (módulos TUI=yes: dialog/prompts) o
# volcando su salida al log (módulos batch). SIEMPRE captura el código de
# salida del módulo (con 'pipefail' activo un módulo que falla puede matar
# esta función bajo 'set -e' si el resultado no se guarda explícitamente) y
# lo devuelve, para que el llamador (install_full/install_custom) decida si
# sigue con el resto en vez de abortarse entero en el primer módulo que falle.
run_module() {
  local module="$1"
  local path="$SCRIPT_DIR/modules/$module.sh"
  local rc=0

  if [[ ! -f "$path" ]]; then
    msg "Módulo no encontrado:\n$path"
    return 1
  fi

  log "Iniciando módulo: $module"
  if [[ "$(module_meta "$module" TUI)" == "yes" ]]; then
    bash "$path" || rc=$?
  else
    bash "$path" 2>&1 | sudo tee -a "$LOG_DIR/$module.log" || rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    log "Falló módulo $module (código $rc)"
  else
    log "Finalizado módulo: $module"
  fi
  return "$rc"
}

# Ejecuta un módulo volcando TODA su salida al log, sin terminal. La usa la
# barra de progreso para correr módulos batch en segundo plano. Devuelve el
# código de salida del módulo (mismo motivo que run_module).
run_module_quiet() {
  local module="$1"
  local path="$SCRIPT_DIR/modules/$module.sh"
  local rc=0
  [[ -f "$path" ]] || return 1
  log "Iniciando módulo (silencioso): $module"
  bash "$path" 2>&1 | sudo tee -a "$LOG_DIR/$module.log" >/dev/null || rc=$?
  if [[ $rc -ne 0 ]]; then
    log "Falló módulo (silencioso) $module (código $rc)"
  fi
  return "$rc"
}

# Resto de la biblioteca. El orden importa poco: las funciones se resuelven
# recién al invocarlas, y para entonces ya está todo sourceado.
source "$SCRIPT_DIR/lib/storage.sh"
source "$SCRIPT_DIR/lib/hw.sh"
source "$SCRIPT_DIR/lib/services.sh"
