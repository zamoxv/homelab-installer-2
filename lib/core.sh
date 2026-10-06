#!/usr/bin/env bash
# Núcleo de HLI 2: configuración, logging, estado, envoltorios de dialog y el
# sistema de plugins (descubrimiento y ejecución de módulos en modules/).
# Es el único archivo que los módulos necesitan sourcear: al final carga el
# resto de la biblioteca (hw.sh, storage.sh, services.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 'HLI2_CONFIG_FILE': permite a los tests apuntar esto a /dev/null (que
# '[[ -f ]]' ve como "no es un archivo regular", así que no se sourcea
# nada) en vez de al config/default.conf real del repo — sin esto, los
# tests que exportan APPDATA_ROOT/MEDIA_ROOT/BACKUP_ROOT/MEDIA_GROUP a un
# scratch dir los verían PISADOS por las asignaciones de config/default.conf
# (que son incondicionales: no usan '${VAR:-...}'), un hallazgo real de la
# ronda 2 de tests (ver tests/lib/harness.sh). En producción, sin override,
# sigue leyendo el config/default.conf real de siempre.
CONFIG_FILE="${HLI2_CONFIG_FILE:-$SCRIPT_DIR/config/default.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

SERVER_USER="${SERVER_USER:-$USER}"
[[ -n "$SERVER_USER" ]] || SERVER_USER="$USER"

MEDIA_GROUP="${MEDIA_GROUP:-media}"
MEDIA_ROOT="${MEDIA_ROOT:-/srv/media}"
APPDATA_ROOT="${APPDATA_ROOT:-/srv/appdata}"
# Repositorio restic local (root 0700, oculto, en el disco de media: lib/backup.sh
# falla cerrado si queda en el mismo disco que el sistema).
BACKUP_ROOT="${BACKUP_ROOT:-$MEDIA_ROOT/.hli2-backups}"

# Si config/default.conf no definió el array (o no existe el archivo), usar
# este valor por defecto.
if [[ -z "${MEDIA_FOLDERS+x}" ]]; then
  MEDIA_FOLDERS=(peliculas series musica libros fotos videos downloads transcode)
fi

# Namespaced con el prefijo 'HLI2_' (nunca 'LOG_DIR'/'STATE_DIR' pelados): un
# nombre genérico como "STATE_DIR" puede existir por casualidad en el
# entorno de quien corre bootstrap.sh (herencia de otra herramienta, de su
# shell, de un 'source' de algún dotfile) y secuestrar en silencio dónde
# vive el estado/los logs REALES de HLI 2 en un servidor de producción —
# hallazgo de una revisión de seguridad posterior a la primera versión de
# v2.3. Un prefijo específico del proyecto ('HLI2_...') no colisiona con
# nada genérico. Los tests (tests/run.sh) apuntan esto a un directorio de
# scratch exportando las variables HLI2_*; sin ellas, quedan las rutas
# reales de siempre. Mismo criterio en DOKPLOY_ENV_FILE/DOKPLOY_STATE_FILE
# (lib/dokploy_api.sh), SECRETS_DIR (lib/secrets.sh) y DNS_PORT_*
# (lib/dns.sh).
LOG_DIR="${HLI2_LOG_DIR:-/var/log/hli2}"
STATE_DIR="${HLI2_STATE_DIR:-/var/lib/hli2}"
STATE_FILE="${HLI2_STATE_FILE:-$STATE_DIR/state}"

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

# apt siempre sin preguntas. 'sudo' descarta las variables de entorno
# (env_reset), así que exportar DEBIAN_FRONTEND en bootstrap.sh NO llega a
# apt: hay que pasarla a través de sudo con 'env'. La entrada se cierra
# (</dev/null) para que ningún prompt pueda quedar esperando teclado en un
# módulo que corre en segundo plano bajo la barra de progreso.
hli_apt() {
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@" </dev/null
}

log() {
  local msg="$1"
  echo "[$(date '+%F %T')] $msg" | sudo tee -a "$LOG_DIR/install.log" >/dev/null
}

# Línea con fecha en install.log y, si el proceso es un módulo (ver
# HLI2_MODULE_NAME más abajo), también en $LOG_DIR/<módulo>.log. Nunca falla:
# un log que no se puede escribir no debe tumbar al módulo (ni disparar el
# trap ERR dentro de su propio manejador).
hli_module_log() {
  local line="[$(date '+%F %T')] $1" mod="${HLI2_MODULE_NAME:-}"
  if [[ -n "$mod" ]]; then
    printf '%s\n' "$line" | sudo tee -a "$LOG_DIR/install.log" "$LOG_DIR/$mod.log" >/dev/null 2>&1 || true
  else
    printf '%s\n' "$line" | sudo tee -a "$LOG_DIR/install.log" >/dev/null 2>&1 || true
  fi
}

# Error visible Y con rastro: escribe "ERROR: <mensaje>" a stderr y al log del
# módulo. Los módulos TUI no pueden mandar su stderr por una tubería
# (dialog dibuja los cuadros de entrada/contraseña por stderr y la tubería
# rompe la detección del tamaño de la terminal), así que el rastro se deja
# explícitamente acá. No pasar secretos en el mensaje.
hli_error() {
  printf 'ERROR: %s\n' "$1" >&2
  hli_module_log "ERROR: $1"
  return 0
}

# Manejador del trap ERR de los módulos. Registra módulo, línea y SOLO el
# nombre del comando que falló (primera palabra, sin argumentos ni valores
# de asignación): BASH_COMMAND es el texto sin expandir, pero igual se
# recorta para no arrastrar nada sensible a un log legible por otros.
_hli_on_err() {
  local rc="$1" line="$2" src="$3" cmd="$4" mod="${HLI2_MODULE_NAME:-?}" where=""
  [[ -z "${_HLI_IN_ERR:-}" ]] || return 0
  _HLI_IN_ERR=1
  cmd="${cmd%%[[:space:]]*}"
  cmd="${cmd%%=*}"
  cmd="${cmd:0:40}"
  [[ "$(basename "$src")" == "$mod.sh" ]] || where=" [$(basename "$src")]"
  hli_module_log "Error en $mod línea $line$where: $cmd (código $rc)"
  _HLI_IN_ERR=""
  return 0
}

mark_done() {
  local module="$1"
  grep -qxF "$module" "$STATE_FILE" 2>/dev/null || echo "$module" >> "$STATE_FILE"
}

is_done() {
  local module="$1"
  grep -qxF "$module" "$STATE_FILE" 2>/dev/null
}

# Aviso de "trabajando" para esperas largas (despliegues, validación
# canaria): sin esto la pantalla queda quieta varios minutos, parece colgada
# y las teclas que se presionan se imprimen como basura (^[[A...). Muestra un
# cuadro sin botones y apaga el eco del teclado hasta la próxima
# interacción (msg/confirm/input_box/password_box lo reactivan). Escribe
# directo a /dev/tty: funciona aunque se llame dentro de $(...). Sin
# terminal (tests, ejecución en segundo plano) no hace nada.
hli_busy() {
  { : >/dev/tty; } 2>/dev/null || return 0
  stty -echo </dev/tty 2>/dev/null || true
  dialog --title "HLI 2" --infobox "$1\n\nPuede tardar unos minutos. No es necesario presionar teclas." 9 70 >/dev/tty 2>/dev/null || true
}

hli_busy_end() {
  { : >/dev/tty; } 2>/dev/null || return 0
  stty echo </dev/tty 2>/dev/null || true
}

# Altura para msgbox/yesno según el texto. Con altura 0 (automática) dialog
# deja estos cuadros sin espacio para el texto (validado en la X230: aviso
# vacío); con una altura fija, los textos largos no entran. Se calcula:
# líneas del texto (los '\n' de dialog separan líneas; cada línea ocupa
# ceil(largo/ancho_útil)) + bordes y botones, limitado al alto de la
# terminal.
_dlg_height() {
  local text="$1" width="${2:-76}" extra="${3:-6}"
  local usable=$(( width - 8 )) lines=0 seg rows max len
  # dialog interpreta la secuencia literal '\n' como salto de línea.
  while IFS= read -r seg; do
    len=${#seg}
    if (( len == 0 )); then
      lines=$(( lines + 1 ))
    else
      lines=$(( lines + (len + usable - 1) / usable ))
    fi
  done <<<"${text//\\n/$'\n'}"
  rows=$(( lines + extra ))
  (( rows < 7 )) && rows=7
  max="$(tput lines 2>/dev/null)" || max=24
  [[ "$max" =~ ^[0-9]+$ ]] || max=24
  (( rows > max - 2 )) && rows=$(( max - 2 ))
  printf '%s' "$rows"
}

# Filas extra de un inputbox/passwordbox sobre las líneas del texto: bordes,
# caja del campo (3 filas), separador y botones. Medido en dialog real
# (Ubuntu 24.04), ver tests/test_core_dialogs.sh.
_DLG_INPUT_EXTRA=8

msg() {
  hli_busy_end
  # Puramente informativo (un botón "Aceptar"): ESC o un fallo de dialog no
  # deben abortar el módulo que llamó a msg(), así que nunca propaga error.
  dialog --title "HLI 2" --msgbox "$1" "$(_dlg_height "$1")" 76 || true
}

confirm() {
  hli_busy_end
  dialog --title "Confirmar" --yesno "$1" "$(_dlg_height "$1")" 76
}

input_box() {
  local title="$1"
  local prompt="$2"
  local default="${3:-}"
  hli_busy_end
  # Altura explícita (_dlg_height) en vez de 0: con altura 0 y un texto largo
  # dialog pega el campo de entrada encima de los botones y recorta el texto
  # a la derecha (validado en el servidor real, Ubuntu 24.04). Un inputbox
  # necesita las filas extra del campo (3: caja del campo) además de bordes y
  # botones: ver _DLG_INPUT_EXTRA. Si la altura no entra, dialog falla
  # ("Can't make sub-window") y el módulo lo tomaría como "cancelar".
  dialog --title "$title" --inputbox "$prompt" "$(_dlg_height "$prompt" 76 "$_DLG_INPUT_EXTRA")" 76 "$default" 3>&1 1>&2 2>&3
}

# Como input_box(), pero con entrada oculta (--passwordbox, sin eco en
# pantalla): usarla para tokens/contraseñas (ej. token de la API de
# Dokploy). '--insecure' hace que dialog muestre '*' mientras se tipea, en
# vez de nada — más usable, no reduce la ocultación real del valor final.
password_box() {
  local title="$1"
  local prompt="$2"
  hli_busy_end
  dialog --title "$title" --insecure --passwordbox "$prompt" "$(_dlg_height "$prompt" 76 "$_DLG_INPUT_EXTRA")" 76 3>&1 1>&2 2>&3
}

# Valida la FORMA de un nombre de dominio (nunca su resolución real):
# etiquetas separadas por '.', cada una con caracteres [A-Za-z0-9-], sin
# guion al principio ni al final, 1-63 caracteres por etiqueta, al menos dos
# etiquetas (un FQDN de verdad, no "localhost" ni una palabra suelta) y
# largo total <=253. La usan los módulos que piden un dominio por TUI
# (vaultwarden, opencloud) para rechazar de entrada algo que claramente no
# es un nombre de dominio, antes de mandarlo a Traefik/Dokploy.
hli2_valid_hostname() {
  local host="$1"
  [[ -n "$host" && "${#host}" -le 253 ]] || return 1
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# --- Docker con privilegios (única puerta de entrada) ---

# Corre 'docker' con privilegios, SIN pedir contraseña. bootstrap.sh cachea
# sudo con un keepalive de fondo, así que '-n' (non-interactive) alcanza: si
# por lo que sea sudo no tiene la contraseña cacheada, esto falla rápido en
# vez de colgarse pidiéndola en medio de un diálogo.
#
# Por qué existe: el usuario que corre el bootstrap normalmente NO está en
# el grupo 'docker' (nada lo agrega ahí), así que un 'docker info' sin sudo
# devuelve "permission denied" -> salida vacía -> un chequeo de seguridad
# descuidado puede leer eso como "no hay nada corriendo" y dejar pasar una
# operación destructiva (ver modules/dokploy.sh: el instalador oficial de
# Dokploy hace 'docker swarm leave --force' sin preguntar). TODA decisión de
# seguridad basada en el estado real de Docker (¿hay un swarm ajeno?, ¿está
# Dokploy corriendo?) tiene que pasar por acá, nunca por un 'docker' pelado.
hli_docker() {
  sudo -n docker "$@"
}

# Rutas/unidad que delatan una instalación de Docker aunque no se pueda
# resolver el binario. Variable (no constante): así un test puede apuntarla
# a un archivo de prueba en vez de tocar rutas reales del sistema.
HLI_DOCKER_FOOTPRINT_PATHS=(/var/run/docker.sock /run/docker.sock /var/lib/docker /etc/docker /snap/bin/docker)

_hli_docker_footprint_exists() {
  local f
  for f in "${HLI_DOCKER_FOOTPRINT_PATHS[@]}"; do
    [[ -e "$f" ]] && return 0
  done
  systemctl cat docker.service >/dev/null 2>&1
}

# Presencia del binario 'docker', vista CON privilegios. Por qué hace falta
# además de hli_docker(): el usuario que corre el bootstrap puede tener un
# PATH sin docker mientras que root sí lo ve (instalado vía snap, con
# secure_path distinto, etc.) — un 'command -v docker' sin privilegios daría
# "ausente" en ese caso, aunque Docker esté instalado y corriendo. Tres
# valores por stdout:
#   present  sudo puede resolver el binario 'docker'.
#   absent   Ni el binario (con privilegios) ni ningún rastro de Docker
#            (socket, /var/lib/docker, /etc/docker, unidad systemd...).
#   unknown  No se pudo confirmar ni lo uno ni lo otro con certeza: sudo -n
#            no funciona (sin sesión cacheada, "sudo -v" no corrió o
#            expiró), o hay ALGÚN rastro de Docker pero no se pudo resolver
#            el binario. NUNCA tratar esto como "absent": una máquina con
#            restos de Docker (o cuyo estado no se puede confirmar) no es
#            una máquina limpia, y asumir que sí fue justamente el bug que
#            dejaba correr el instalador destructivo de Dokploy sobre un
#            swarm ajeno sin detectarlo.
hli_docker_presence() {
  sudo -n true 2>/dev/null || { echo "unknown"; return; }

  if sudo -n sh -c 'command -v docker' >/dev/null 2>&1; then
    echo "present"
    return
  fi

  if _hli_docker_footprint_exists; then
    echo "unknown"
  else
    echo "absent"
  fi
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
    hli_busy_end   # red de seguridad: eco del teclado siempre de vuelta
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

# Un módulo ejecutado directamente (fuera de bootstrap.sh, que mantiene sudo
# cacheado con un keepalive) pide sudo una vez al inicio si no está en caché.
# Sin esto, toda consulta de estado de Docker (sudo -n) da "desconocido".
# Solo con terminal interactiva: en segundo plano/tests nunca pregunta nada.
hli_require_sudo() {
  [[ -t 0 ]] || return 0
  sudo -n true 2>/dev/null && return 0
  sudo -v -p 'HLI 2 necesita permisos de administrador. Contraseña de %p: ' || true
}

# Procesos de módulo (bash modules/<id>.sh): nombre para los logs y trap ERR
# que deja rastro de las fallas (línea + comando) en el log del módulo. 'set
# -E' hace que el trap valga también dentro de funciones y subshells. Sigue
# la semántica de 'set -e': no dispara en condicionales ni en listas
# '&&'/'||'.
if [[ "$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" == "$(cd "$SCRIPT_DIR/modules" 2>/dev/null && pwd -P)" && "$0" == *.sh ]]; then
  HLI2_MODULE_NAME="$(basename "$0" .sh)"
  set -E
  trap '_hli_on_err "$?" "$LINENO" "${BASH_SOURCE[0]}" "$BASH_COMMAND"' ERR
fi

# Resto de la biblioteca. El orden importa poco: las funciones se resuelven
# recién al invocarlas, y para entonces ya está todo sourceado.
source "$SCRIPT_DIR/lib/storage.sh"
source "$SCRIPT_DIR/lib/hw.sh"
source "$SCRIPT_DIR/lib/services.sh"
source "$SCRIPT_DIR/lib/dns.sh"
source "$SCRIPT_DIR/lib/secrets.sh"
source "$SCRIPT_DIR/lib/dokploy_api.sh"
source "$SCRIPT_DIR/lib/compose.sh"
source "$SCRIPT_DIR/lib/importer.sh"
source "$SCRIPT_DIR/lib/canary.sh"
source "$SCRIPT_DIR/lib/backup.sh"

hli_require_sudo
