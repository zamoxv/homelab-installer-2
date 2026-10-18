#!/usr/bin/env bash
# HLI-MODULE: hermes
# HLI-DESC: Hermes Agent (agente IA 24/7, LAN/Tailscale, vía API de Dokploy)
# HLI-ORDER: 68
# HLI-DEFAULT: no
# HLI-TUI: yes
# HLI-REQUIERE: dokploy-api
#
# v2.6a: despliega Hermes Agent (Nous Research) como compose de Dokploy
# (compose/hermes/docker-compose.yml). El agente es el cuerpo; el cerebro es
# un modelo abierto barato vía OpenRouter, con un límite de gasto puesto por
# el usuario en la propia clave.
#
# HLI-DEFAULT: no, a propósito: necesita una clave de OpenRouter creada por el
# usuario y no debe dispararse dentro de "instalar todo".
#
# Hechos verificados el 2026-10-16 (documentación oficial y código v0.22.2):
# - Imagen nousresearch/hermes-agent, etiqueta de versión fijada v0.22.2
#   (Docker Hub, 2026-10-15), 'command: gateway run', datos en /opt/data,
#   HERMES_UID/HERMES_GID, shm_size 1g para el navegador.
#   https://hermes-agent.nousresearch.com/docs/user-guide/docker
#   https://dokploy.com/templates/hermes
# - API (8642): API_SERVER_ENABLED/HOST/PORT/KEY; la clave es obligatoria y
#   da acceso a TODAS las herramientas, incluida la terminal; /health y
#   /v1/models; autenticación 'Authorization: Bearer <clave>'.
#   https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server
# - Dashboard (9119): con bind no-loopback exige autenticación
#   (HERMES_DASHBOARD_BASIC_AUTH_USERNAME/PASSWORD/SECRET); sin ella se
#   niega a arrancar. El proveedor basic es solo para redes de confianza/VPN.
#   https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
# - config.yaml (DEFAULT_CONFIG en hermes_cli/config_defaults.py, v0.22.2):
#   approvals.mode por defecto es "smart" (se fija "manual");
#   security.website_blocklist viene DESACTIVADA (se activa);
#   terminal.backend "local"; fallback_providers; provider_routing de
#   OpenRouter con data_collection "deny"; cada tarea auxiliar con su
#   propio provider/model (lista en HERMES_AUX_TASKS).
#   https://hermes-agent.nousresearch.com/docs/user-guide/configuration
#   https://hermes-agent.nousresearch.com/docs/user-guide/security
#   https://hermes-agent.nousresearch.com/docs/user-guide/features/fallback-providers
#   https://openrouter.ai/docs/cookbook/coding-agents/hermes-integration
#
# Aislamiento de salida: el contenedor vive en su propia red (subred /24 fija,
# HLI2_HERMES_SUBNET, por defecto 10.213.144.0/24) y el módulo instala reglas
# de iptables para que el agente NO pueda iniciar conexiones hacia la LAN,
# Tailscale, la propia máquina ni otras redes privadas (el agente tiene una
# terminal: sin esto alcanzaría el panel de Dokploy, AdGuard, Home Assistant,
# el router). Ver _hermes_render_egress_script.
#
# Secretos (OPENROUTER_API_KEY, API_SERVER_KEY, clave y secreto del
# dashboard): root-only en /etc/hli2/hermes.env (lib/secrets.sh), al compose
# solo por el canal "env" de Dokploy entre comillas simples; nunca por argv
# ni logs (la clave de la API viaja a curl por stdin, '-K -').
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

# Modelos propuestos por defecto (precios de OpenRouter, 2026-10-16, por
# millón de tokens): deepseek/deepseek-v4.1-flash 0,032 USD entrada / 0,144
# salida, contexto 1M, herramientas, texto+imagen; qwen/qwen3.7-flash 0,03 /
# 0,13 (0,10 / 0,40 sobre 32k de prompt), herramientas, texto+imagen+video.
# El usuario puede cambiarlos en el cuadro de entrada.
HERMES_DEFAULT_MODEL="deepseek/deepseek-v4.1-flash"
# Subred de la red del contenedor: una /24 privada que no choca con el pool
# de Swarm de Dokploy (172.20-31), las redes por defecto de Docker (172.17-31
# y 192.168.0.0/16 en trozos /20) ni con LAN típicas. Configurable.
HERMES_SUBNET="${HLI2_HERMES_SUBNET:-10.213.144.0/24}"
# Dónde se instalan el script/unidad de aislamiento y el drop-in de Docker
# (variables HLI2_* para los tests, mismo criterio que el resto del proyecto).
HERMES_SBIN_DIR="${HLI2_HERMES_SBIN_DIR:-/usr/local/sbin}"
HERMES_SYSTEMD_DIR="${HLI2_SYSTEMD_DIR:-/etc/systemd/system}"
HERMES_DOCKER_DROPIN_DIR="${HLI2_DOCKER_DROPIN_DIR:-/etc/systemd/system/docker.service.d}"
HERMES_SYSCTL_DIR="${HLI2_SYSCTL_DIR:-/etc/sysctl.d}"
HERMES_DEFAULT_AUX_MODEL="qwen/qwen3.7-flash"

# Tareas auxiliares de Hermes v0.22.2 que usan un LLM
# (DEFAULT_CONFIG["auxiliary"]); web_extract y session_search ya no lo usan.
# Cada una se fija a mano a OpenRouter + el modelo barato: no se depende del
# valor "auto" (que cae en el modelo principal o en uno de pago).
HERMES_AUX_TASKS=(
  vision compression skills_hub approval review mcp title_generation
  memory_query_rewrite tts_audio_tags voice_chat triage_specifier
  kanban_decomposer profile_describer goal_judge curator monitor
  background_review moa_reference moa_aggregator
)

HERMES_CREDS_TMP=""
_hermes_creds_cleanup() {
  [[ -z "$HERMES_CREDS_TMP" ]] || rm -f -- "$HERMES_CREDS_TMP"
  HERMES_CREDS_TMP=""
}

# --- Validaciones de forma (nunca de red) -----------------------------------

# Claves de OpenRouter: prefijo 'sk-or-' (la guía de integración de Hermes
# solo garantiza ese prefijo; las actuales son 'sk-or-v1-<hex>'). Charset
# seguro: nada que rompa el dotenv ni el compose.
_hermes_valid_openrouter_key() {
  [[ "$1" =~ ^sk-or-[A-Za-z0-9_-]{16,200}$ ]]
}

# <autor>/<slug>, con '~' opcional al inicio y ':variante' opcional; sin
# espacios ni comillas (se escribe tal cual en config.yaml).
_hermes_valid_model() {
  [[ "$1" =~ ^~?[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]
}

_hermes_valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 && BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255 )) || return 1
  [[ "$1" != "0.0.0.0" ]]
}

# IPv4 privada de LAN (RFC 1918). Rechaza públicas, 127/8, 169.254/16, etc.
_hermes_private_lan_ip() {
  _hermes_valid_ipv4 "$1" || return 1
  local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
  (( a == 10 )) && return 0
  (( a == 172 && b >= 16 && b <= 31 )) && return 0
  (( a == 192 && b == 168 )) && return 0
  return 1
}

# IPv4 del rango CGNAT de Tailscale (100.64.0.0/10).
_hermes_tailscale_range_ip() {
  _hermes_valid_ipv4 "$1" || return 1
  (( BASH_REMATCH[1] == 100 && BASH_REMATCH[2] >= 64 && BASH_REMATCH[2] <= 127 ))
}

# --- Generación de secretos -------------------------------------------------

_hermes_rand_hex32() {
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# 24 caracteres alfanuméricos (sin símbolos: se teclea en el teléfono).
_hermes_rand_pass() {
  local raw
  raw="$(head -c 64 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9')"
  printf '%s' "${raw:0:24}"
}

# --- Secretos ----------------------------------------------------------------

# Variables del módulo (se llenan en _hermes_ensure_secrets).
H_OR_KEY="" H_API_KEY="" H_DASH_PASS="" H_DASH_SECRET="" H_PENDING="1"

_hermes_write_secrets() {
  secret_file_write hermes "OPENROUTER_API_KEY=${H_OR_KEY}
API_SERVER_KEY=${H_API_KEY}
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${H_DASH_PASS}
HERMES_DASHBOARD_BASIC_AUTH_SECRET=${H_DASH_SECRET}
HLI_CREDENTIALS_PENDING=${H_PENDING}"
}

# Valor de CLAVE en el contenido ($1) de un archivo CLAVE=valor ('' si no
# está). Parseo explícito, nunca 'source' (mismo criterio que secret_get).
_hermes_env_value() {
  local content="$1" key="$2" line
  while IFS= read -r line; do
    case "$line" in
      "${key}="*) printf '%s' "${line#"${key}="}"; return 0 ;;
    esac
  done <<<"$content"
  return 0
}

_hermes_ask_openrouter_key() {
  msg "Antes de continuar, cree la clave de OpenRouter CON UN LÍMITE DE GASTO:\n\n1. Entre a openrouter.ai -> Keys -> 'Create key'.\n2. Ponga un nombre (por ejemplo 'hermes') y fije un límite de crédito de 5 USD (si el panel ofrece reinicio mensual, elíjalo).\n3. Copie la clave (empieza con 'sk-or-').\n\nEl límite en la clave es el tope DURO de gasto: si el agente se descontrola o la clave se filtra, OpenRouter deja de cobrar al llegar a ese monto. Se recomienda mucho no omitirlo.\n\nEn el siguiente paso se le pedirá la clave; no se muestra en pantalla ni se registra en logs."
  local key
  key=$(password_box "Hermes — clave de OpenRouter" "Pegue la clave de OpenRouter (empieza con 'sk-or-').") \
    || { msg "Se cancela el despliegue de Hermes: no se ingresó ninguna clave de OpenRouter."; return 1; }
  key="${key#"${key%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"
  if ! _hermes_valid_openrouter_key "$key"; then
    key=""
    msg "El valor ingresado no tiene la forma de una clave de OpenRouter (empieza con 'sk-or-' y solo lleva letras, números, '-' y '_'). Se cancela el despliegue: copie de nuevo la clave desde openrouter.ai/keys y vuelva a correr este módulo."
    return 1
  fi
  H_OR_KEY="$key"
  key=""
}

# Deja H_* completos y guardados en /etc/hli2/hermes.env.
# - Si el archivo existe se cargan TODOS sus secretos tal cual; solo se pide
#   (clave de OpenRouter) o se genera (el resto) lo que falte. Nunca se rota
#   nada sin que el usuario lo pida en las preguntas de más abajo.
# - Si el archivo existe pero no se puede leer (sudo sin caché, etc.) se
#   aborta: regenerar en ese caso rotaría en silencio claves que sí existen.
_hermes_ensure_secrets() {
  local existing=0 changed=0 f content
  f="$(secret_file_path hermes)"
  if ! sudo -n true 2>/dev/null; then
    msg "No se pudo verificar /etc/hli2/hermes.env porque 'sudo' no está disponible sin contraseña (¿expiró la sesión de sudo?). Se cancela el despliegue de Hermes para no regenerar claves que podrían existir. Vuelva a correr el módulo desde una sesión con sudo activo."
    return 1
  fi
  if priv_file_exists "$f"; then
    content="$(priv_file_read "$f")" || {
      msg "Existe /etc/hli2/hermes.env pero no se pudo leer. Se cancela el despliegue de Hermes para no regenerar claves que ya existen."
      return 1
    }
    existing=1
    H_OR_KEY="$(_hermes_env_value "$content" OPENROUTER_API_KEY)"
    H_API_KEY="$(_hermes_env_value "$content" API_SERVER_KEY)"
    H_DASH_PASS="$(_hermes_env_value "$content" HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)"
    H_DASH_SECRET="$(_hermes_env_value "$content" HERMES_DASHBOARD_BASIC_AUTH_SECRET)"
    H_PENDING="$(_hermes_env_value "$content" HLI_CREDENTIALS_PENDING)"
    [[ "$H_PENDING" == "0" ]] || H_PENDING="1"
    content=""
    # Valores presentes pero con forma inesperada: no se reemplazan solos.
    if [[ -n "$H_OR_KEY" ]] && ! _hermes_valid_openrouter_key "$H_OR_KEY"; then
      msg "La clave de OpenRouter guardada en /etc/hli2/hermes.env tiene una forma inesperada. Corríjala a mano (o bórrela del archivo para que se vuelva a pedir) y vuelva a correr el módulo."
      return 1
    fi
    if { [[ -n "$H_API_KEY" && ! "$H_API_KEY" =~ ^[A-Za-z0-9]{8,128}$ ]]; } \
       || { [[ -n "$H_DASH_PASS" && ! "$H_DASH_PASS" =~ ^[A-Za-z0-9]{8,128}$ ]]; } \
       || { [[ -n "$H_DASH_SECRET" && ! "$H_DASH_SECRET" =~ ^[A-Za-z0-9]{8,128}$ ]]; }; then
      msg "Alguno de los secretos guardados en /etc/hli2/hermes.env (clave de API, contraseña o secreto del dashboard) tiene una forma inesperada (solo letras y números, 8 a 128). Corríjalo a mano y vuelva a correr el módulo; no se reemplaza solo."
      return 1
    fi
  fi

  if [[ "$existing" -eq 1 ]]; then
    if confirm "Ya hay secretos guardados para Hermes.\n\n¿Generar una clave de API nueva? (rota API_SERVER_KEY: habrá que cargar la nueva en hermes-android.)" "no"; then
      H_API_KEY=""
    fi
    if [[ -n "$H_OR_KEY" ]]; then
      if confirm "¿Reemplazar la clave de OpenRouter guardada por otra?" "no"; then
        _hermes_ask_openrouter_key || return 1
        changed=1
      fi
    fi
  fi
  if [[ -z "$H_OR_KEY" ]]; then
    _hermes_ask_openrouter_key || return 1
    changed=1
  fi

  if [[ -z "$H_API_KEY" ]]; then
    H_API_KEY="$(_hermes_rand_hex32)"; H_PENDING="1"; changed=1
  fi
  if [[ -z "$H_DASH_PASS" ]]; then
    H_DASH_PASS="$(_hermes_rand_pass)"; H_PENDING="1"; changed=1
  fi
  if [[ -z "$H_DASH_SECRET" ]]; then
    H_DASH_SECRET="$(_hermes_rand_hex32)"; changed=1
  fi
  if [[ ! "$H_API_KEY" =~ ^[A-Za-z0-9]{8,128}$ || ! "$H_DASH_PASS" =~ ^[A-Za-z0-9]{8,128}$ || ! "$H_DASH_SECRET" =~ ^[A-Za-z0-9]{8,128}$ ]]; then
    msg "No se pudieron generar los secretos aleatorios de Hermes (¿falla /dev/urandom?). Se cancela el despliegue."
    return 1
  fi

  if [[ "$changed" -eq 1 || "$existing" -eq 0 ]]; then
    _hermes_write_secrets || { msg "No se pudieron guardar los secretos en /etc/hli2/hermes.env. Se cancela el despliegue de Hermes."; return 1; }
    log "Secretos de Hermes guardados en /etc/hli2/hermes.env (no se loguean los valores)."
  fi
  return 0
}

# --- Directorio de datos y config.yaml ----------------------------------------

H_UID="" H_GID=""

_hermes_prepare_dirs() {
  H_UID="$(id -u "$SERVER_USER")" || { msg "No existe el usuario '$SERVER_USER'."; return 1; }
  H_GID="$(id -g "$SERVER_USER")" || { msg "No se pudo resolver el grupo primario de '$SERVER_USER'."; return 1; }
  # uid/gid de SERVER_USER (los mismos que HERMES_UID/HERMES_GID del
  # compose): así el vault de Obsidian podrá compartirse más adelante.
  sudo install -d -m 0750 -o "$H_UID" -g "$H_GID" "$APPDATA_ROOT/hermes"
}

_hermes_config_path() {
  printf '%s/hermes/config.yaml' "$APPDATA_ROOT"
}

_hermes_render_config() {
  local model="$1" aux="$2" task
  cat <<EOF
# Sembrado por el HLI 2 (modules/hermes.sh) solo si este archivo no existía.
# Hermes y usted pueden editarlo: el HLI no lo vuelve a escribir.
model:
  provider: openrouter
  default: ${model}

# Si el modelo principal falla (429, 5xx, 401/403), se prueba este, también
# barato. Nunca un modelo caro como respaldo automático.
fallback_providers:
  - provider: openrouter
    model: ${aux}

# OpenRouter: excluir proveedores que puedan guardar o entrenar con los datos.
provider_routing:
  data_collection: deny

# Cada tarea auxiliar con proveedor y modelo explícitos (no "auto").
auxiliary:
EOF
  for task in "${HERMES_AUX_TASKS[@]}"; do
    printf '  %s:\n    provider: openrouter\n    model: %s\n' "$task" "$aux"
  done
  cat <<'EOF'

# Aprobación manual de cada comando peligroso (el valor por defecto de
# Hermes es "smart"). Pasar a "smart" cuando haya confianza.
approvals:
  mode: manual

security:
  # La protección SSRF (redes privadas, CGNAT, metadatos de nube) está activa
  # por defecto; la lista de sitios bloqueados no, por eso se activa acá.
  website_blocklist:
    enabled: true
    domains:
      - "*.local"
      - "*.lan"
      - "*.internal"
      - "*.home.arpa"

# La frontera de seguridad es el contenedor: sin socket de Docker, sin
# montajes del host. No cambiar a "docker" (equivale a root en el host).
terminal:
  backend: local
EOF
}

# ¿Hay un config.yaml utilizable? Un archivo vacío, ilegible o sin la clave
# 'model:' (restos de una escritura interrumpida) cuenta como ausente.
_hermes_config_valid() {
  local cfg content
  cfg="$(_hermes_config_path)"
  sudo -n test -f "$cfg" 2>/dev/null || return 1
  content="$(sudo -n cat -- "$cfg" 2>/dev/null)" || return 1
  [[ -n "$content" ]] || return 1
  grep -Eq '^model:' <<<"$content"
}

# Siembra config.yaml SOLO si no hay uno utilizable (nunca pisa ediciones del
# usuario o del agente). Escritura atómica: se renderiza a un archivo
# temporal en la MISMA carpeta (creado con 'install': modo y dueño finales
# desde el inicio, escrito con 'tee' sobre ese archivo ya existente; sin
# mktemp del usuario + 'sudo tee', fs.protected_regular) y se mueve con 'mv'
# (rename atómico). Un config.yaml inválido no vacío se conserva como
# 'config.yaml.invalido-<fecha>' antes de reemplazarlo.
_hermes_seed_config() {
  local model="$1" aux="$2" cfg stage
  cfg="$(_hermes_config_path)"
  _hermes_config_valid && return 0
  stage="${cfg}.tmp.$$"
  if ! sudo install -m 0640 -o "$H_UID" -g "$H_GID" /dev/null "$stage"; then
    return 1
  fi
  if ! _hermes_render_config "$model" "$aux" | sudo tee "$stage" >/dev/null; then
    sudo rm -f "$stage"
    return 1
  fi
  if sudo -n test -s "$cfg" 2>/dev/null; then
    sudo cp -f "$cfg" "${cfg}.invalido-$(date +%Y%m%d%H%M%S)" || true
  fi
  if ! sudo mv -f "$stage" "$cfg"; then
    sudo rm -f "$stage"
    return 1
  fi
  log "config.yaml de Hermes sembrado en $cfg"
}

H_MODEL="$HERMES_DEFAULT_MODEL" H_AUX_MODEL="$HERMES_DEFAULT_AUX_MODEL"
_hermes_ask_models() {
  local m a
  m=$(input_box "Hermes — modelo principal" "Modelo principal en OpenRouter (formato autor/modelo).\n\nPor defecto se propone un modelo abierto barato con herramientas y contexto de 1M tokens (deepseek-v4.1-flash, unos 0,03 USD por millón de tokens de entrada y 0,14 de salida al 2026-10-16). Puede cambiarlo; los precios actuales están en openrouter.ai/models." "$HERMES_DEFAULT_MODEL") \
    || { msg "Se cancela el despliegue de Hermes."; return 1; }
  a=$(input_box "Hermes — modelo auxiliar" "Modelo para las tareas auxiliares (títulos, compresión de contexto, visión, aprobaciones, etc.). Debe ser barato y aceptar imágenes si quiere que Hermes analice fotos.\n\nPor defecto: qwen3.7-flash (unos 0,03 USD por millón de tokens de entrada y 0,13 de salida al 2026-10-16)." "$HERMES_DEFAULT_AUX_MODEL") \
    || { msg "Se cancela el despliegue de Hermes."; return 1; }
  if ! _hermes_valid_model "$m" || ! _hermes_valid_model "$a"; then
    msg "Un id de modelo no tiene la forma autor/modelo de OpenRouter (por ejemplo deepseek/deepseek-v4.1-flash). Se cancela: vuelva a correr el módulo."
    return 1
  fi
  H_MODEL="$m"; H_AUX_MODEL="$a"
}

# En una re-ejecución, con config.yaml ya existente: cambia SOLO las claves de
# modelo, con la propia CLI de Hermes dentro del contenedor ya desplegado
# (no se edita YAML a mano: el archivo puede haber sido reescrito por el
# agente). Se ejecuta con el uid/gid del agente ('-u'): 'docker exec' como
# root dejaría archivos de root dentro de /opt/data. INCERTIDUMBRE: 'hermes
# config set' con rutas anidadas de tres niveles (auxiliary.<tarea>.model) no
# está documentado explícitamente.
_hermes_apply_model_change() {
  local hermes_bin="/opt/hermes/.venv/bin/hermes" task failed=0
  local -a run=(exec -u "${H_UID}:${H_GID}" hermes "$hermes_bin" config set)
  hli_docker "${run[@]}" model.default "$H_MODEL" >/dev/null 2>&1 || failed=1
  for task in "${HERMES_AUX_TASKS[@]}"; do
    hli_docker "${run[@]}" "auxiliary.${task}.model" "$H_AUX_MODEL" >/dev/null 2>&1 || failed=1
  done
  if [[ "$failed" -eq 1 ]]; then
    msg "No se pudieron cambiar todos los modelos con la CLI de Hermes. Edite a mano ${APPDATA_ROOT}/hermes/config.yaml (claves model.default y auxiliary.<tarea>.model) y reinicie el contenedor 'hermes'."
    return 1
  fi
  hli_docker restart hermes >/dev/null 2>&1 || true
}

# --- Red ---------------------------------------------------------------------

# IPv4 de Tailscale (vacío si no está instalado o sin sesión).
_hermes_tailscale_ip() {
  local ip
  ip="$(sudo -n tailscale ip -4 2>/dev/null | head -n1)" || ip=""
  if _hermes_tailscale_range_ip "$ip"; then
    printf '%s' "$ip"
  fi
}

# IP de LAN del servidor: la de la interfaz de la ruta por defecto ('ip -4
# route get', campo 'src'); si 'ip' no la da, la primera de 'hostname -I'
# (get_ip). Se exige una IPv4 privada (RFC 1918): nunca una pública, 127/8,
# 169.254/16 ni nada que no sea de la LAN.
_hermes_lan_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')" || ip=""
  [[ -n "$ip" ]] || ip="$(get_ip 2>/dev/null || true)"
  printf '%s' "$ip"
}

# --- Validación de la subred del contenedor ---------------------------------------

_hermes_ip2int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%s' $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# ¿Se solapan los prefijos $1 y $2 (a.b.c.d o a.b.c.d/n)?
_hermes_prefix_overlap() {
  local p1="$1" p2="$2" l1=32 l2=32 s1 s2 e1 e2 m1 m2
  [[ "$p1" == */* ]] && l1="${p1#*/}"
  [[ "$p2" == */* ]] && l2="${p2#*/}"
  s1="$(_hermes_ip2int "${p1%/*}")"; s2="$(_hermes_ip2int "${p2%/*}")"
  m1=$(( (0xFFFFFFFF << (32 - l1)) & 0xFFFFFFFF ))
  m2=$(( (0xFFFFFFFF << (32 - l2)) & 0xFFFFFFFF ))
  s1=$(( s1 & m1 )); s2=$(( s2 & m2 ))
  e1=$(( s1 | (~m1 & 0xFFFFFFFF) )); e2=$(( s2 | (~m2 & 0xFFFFFFFF) ))
  (( s1 <= e2 && s2 <= e1 ))
}

# Valida la subred $1 de la red del contenedor ANTES de instalar nada:
# a.b.c.0/24 con octetos numéricos, solo RFC 1918 (queda fuera 127/8,
# 100.64/10, 169.254/16 y todo lo público), sin contener la IP de la LAN $2 y
# sin solaparse con ninguna ruta del servidor ('ip -4 route show') ni con la
# subred de ninguna red de Docker existente. La red 'hermes-net' ya creada en
# una ejecución anterior con ESTA misma subred no cuenta como choque.
_hermes_validate_subnet() {
  local subnet="$1" lan_ip="$2" a b c prefix name line own=0 conflicts=""
  if [[ ! "$subnet" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/24$ ]]; then
    msg "La subred de la red de Hermes ('${subnet}') no tiene la forma a.b.c.0/24. Defina una /24 privada sin uso con la variable HLI2_HERMES_SUBNET y vuelva a correr el módulo."
    return 1
  fi
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"
  if (( a > 255 || b > 255 || c > 255 )) \
     || ! { (( a == 10 )) || (( a == 172 && b >= 16 && b <= 31 )) || (( a == 192 && b == 168 )); }; then
    msg "La subred de la red de Hermes ('${subnet}') debe ser privada (10.x.y.0/24, 172.16-31.x.0/24 o 192.168.x.0/24); se rechazan 127/8, 100.64/10, 169.254/16 y las públicas. Defina otra con HLI2_HERMES_SUBNET."
    return 1
  fi
  if _hermes_prefix_overlap "$subnet" "$lan_ip"; then
    msg "La subred de la red de Hermes ('${subnet}') contiene la IP de la LAN del servidor (${lan_ip}). Defina otra con HLI2_HERMES_SUBNET."
    return 1
  fi

  # Redes de Docker existentes: "<nombre> <subred> [<subred>...]" por línea.
  local -a dnets=()
  local ids
  ids="$(hli_docker network ls -q 2>/dev/null | tr '\n' ' ')" || ids=""
  if [[ -n "${ids// /}" ]]; then
    # shellcheck disable=SC2086
    while IFS= read -r line; do
      [[ -n "$line" ]] && dnets+=("$line")
    done < <(hli_docker network inspect $ids --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)
  fi
  for line in "${dnets[@]}"; do
    name="${line%% *}"
    if [[ "$name" == *hermes-net ]]; then
      for prefix in ${line#* }; do [[ "$prefix" == "$subnet" ]] && own=1; done
    fi
  done
  for line in "${dnets[@]}"; do
    name="${line%% *}"
    for prefix in ${line#* }; do
      [[ "$prefix" =~ ^[0-9.]+/[0-9]+$ ]] || continue
      [[ "$prefix" == "$subnet" && "$own" -eq 1 && "$name" == *hermes-net ]] && continue
      _hermes_prefix_overlap "$subnet" "$prefix" && conflicts+="red de Docker ${name} (${prefix}) "
    done
  done
  while IFS= read -r line; do
    prefix="${line%% *}"
    [[ "$prefix" =~ ^[0-9.]+(/[0-9]+)?$ ]] || continue
    [[ "$prefix" == "$subnet" && "$own" -eq 1 ]] && continue
    _hermes_prefix_overlap "$subnet" "$prefix" && conflicts+="ruta ${prefix} "
  done < <(ip -4 route show 2>/dev/null || true)
  if [[ -n "$conflicts" ]]; then
    msg "La subred de la red de Hermes ('${subnet}') se solapa con: ${conflicts}. Defina otra /24 privada sin uso con HLI2_HERMES_SUBNET y vuelva a correr el módulo. No se instaló nada."
    return 1
  fi
  return 0
}

# --- Aislamiento de salida (iptables) -------------------------------------------

# Script que aplica/quita las reglas (se instala en $HERMES_SBIN_DIR; lo
# ejecutan la unidad de systemd antes de que arranque Docker y un drop-in de
# docker.service después de cada (re)inicio). Argumentos de generación:
# $1 = subred del contenedor, $2 = IPs de DNS permitidas en el host.
#
# Diseño (las dos rutas que puede tomar un paquete del agente):
# - Hacia OTRAS máquinas o contenedores (FORWARD): se engancha en DOCKER-USER
#   (se evalúa antes que las reglas de Docker). Cadena HLI2-HERMES-FWD:
#   ESTABLISHED/RELATED aceptado; hook HLI2-HERMES-ALLOW; DNS permitido; DROP
#   hacia rangos privados, CGNAT, link-local, loopback, multicast, reservados y
#   de pruebas; el resto (Internet) RETURN, o sea sigue a las reglas normales de
#   Docker. Los puertos publicados (8642/9119) no se ven afectados: la
#   conexión entrante LAN -> contenedor tiene origen en la LAN (no en la
#   subred), y las respuestas contenedor -> LAN son ESTABLISHED, aceptadas por
#   la primera regla. Solo las conexiones NUEVAS iniciadas desde la subred se
#   filtran.
# - Hacia la PROPIA máquina (INPUT): servicios en la red del host (AdGuard,
#   Home Assistant, SSH, etc.) no pasan por FORWARD ni DOCKER-USER, así que
#   hace falta además HLI2-HERMES-IN en INPUT: ESTABLISHED/RELATED, hook, DNS
#   y DROP de todo lo demás.
# - Aplicación atómica: las cadenas nuevas se arman completas bajo otro
#   nombre (-new), se inserta el salto a la nueva, se borran TODOS los saltos
#   a la anterior (sea cual sea su subred de origen, así se limpian restos de
#   una subred vieja), se elimina la anterior y la nueva se renombra (-E). Nunca
#   hay un salto a una cadena vacía o a medio armar.
# - DOCKER-USER: el script la crea si falta. Es el comportamiento que Docker
#   tolera y conserva: en moby (libnetwork/firewall_linux.go, v27.3.1)
#   setupUserChain llama a NewChain, que solo crea la cadena si no existe, agrega
#   un RETURN al final solo si falta y asegura el salto desde FORWARD; el comentario
#   del código dice que el demonio "does not delete or modify any pre-existing
#   rules from the DOCKER-USER filter chain". La documentación publicada de
#   Docker no lo afirma de forma explícita (no verificado en la doc).
# - Hook para permitir un destino local concreto (por ejemplo Ollama en
#   v2.6c): agregar reglas ACCEPT a la cadena HLI2-HERMES-ALLOW, que 'apply' no
#   reconstruye (pero 'remove' SÍ la vacía y la borra), p. ej.
#   iptables -A HLI2-HERMES-ALLOW -d <ip> -p tcp --dport 11434 -j ACCEPT
#   (persistir con un script propio After= de esta unidad).
# - DNS: el contenedor usa los servidores de 'dns:' del compose (el DNS de la
#   LAN solo si AdGuard está instalado, o resolvers públicos); el DNS interno
#   de Docker (127.0.0.11) vive dentro del contenedor y reenvía a esos.
# - Backend: se usa la ruta absoluta de iptables y se registra '-V' (iptables
#   legacy o nf_tables) en el journal; debe coincidir con el que usa Docker.
# - IPv6: la red no lo habilita (Docker por defecto no lo hace).
_hermes_render_egress_script() {
  local subnet="$1" dns_hosts="$2"
  cat <<EOF
#!/usr/bin/env bash
# Generado por el HLI 2 (modules/hermes.sh). Aislamiento de salida del
# contenedor de Hermes: ver el comentario de _hermes_render_egress_script.
# Uso: hli2-hermes-egress apply | remove
set -euo pipefail
IPT="\${HLI2_IPTABLES:-/usr/sbin/iptables}"
SUBNET="${subnet}"
DNS_HOSTS="${dns_hosts}"
BLOCKED="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4"

ipt() { "\$IPT" -w "\$@"; }

# Borra TODOS los saltos de la cadena \$1 hacia la cadena \$2, sea cual sea su
# origen (restos de una subred anterior incluidos).
delete_jumps() {
  local line
  local -a parts
  while IFS= read -r line; do
    [[ "\$line" == "-A "* && "\$line" == *" -j \$2" ]] || continue
    read -ra parts <<<"\$line"
    ipt -D "\${parts[@]:1}" 2>/dev/null || true
  done < <(ipt -S "\$1" 2>/dev/null || true)
}

fill_chain() {
  local chain="\$1" kind="\$2" d r
  ipt -N "\$chain"
  ipt -A "\$chain" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ipt -A "\$chain" -j HLI2-HERMES-ALLOW
  for d in \$DNS_HOSTS; do
    ipt -A "\$chain" -d "\$d" -p udp --dport 53 -j ACCEPT
    ipt -A "\$chain" -d "\$d" -p tcp --dport 53 -j ACCEPT
  done
  if [[ "\$kind" == "fwd" ]]; then
    for r in \$BLOCKED; do
      ipt -A "\$chain" -d "\$r" -j DROP
    done
    ipt -A "\$chain" -j RETURN
  else
    ipt -A "\$chain" -j DROP
  fi
}

# Reemplazo atómico de la cadena \$2 enganchada en \$1 (ver el diseño en
# modules/hermes.sh).
swap_chain() {
  local parent="\$1" live="\$2" kind="\$3" new="\$2-new"
  delete_jumps "\$parent" "\$new"
  ipt -F "\$new" 2>/dev/null || true
  ipt -X "\$new" 2>/dev/null || true
  fill_chain "\$new" "\$kind"
  ipt -I "\$parent" 1 -s "\$SUBNET" -j "\$new"
  delete_jumps "\$parent" "\$live"
  ipt -F "\$live" 2>/dev/null || true
  ipt -X "\$live" 2>/dev/null || true
  ipt -E "\$new" "\$live"
}

case "\${1:-apply}" in
  apply)
    echo "hli2-hermes-egress: backend \$("\$IPT" -V)" >&2
    ipt -N DOCKER-USER 2>/dev/null || true
    ipt -N HLI2-HERMES-ALLOW 2>/dev/null || true
    swap_chain DOCKER-USER HLI2-HERMES-FWD fwd
    swap_chain INPUT HLI2-HERMES-IN in
    ;;
  remove)
    for c in HLI2-HERMES-FWD HLI2-HERMES-FWD-new; do delete_jumps DOCKER-USER "\$c"; done
    for c in HLI2-HERMES-IN HLI2-HERMES-IN-new; do delete_jumps INPUT "\$c"; done
    # Las cadenas FWD e IN referencian a ALLOW: se borran primero.
    for c in HLI2-HERMES-FWD HLI2-HERMES-FWD-new HLI2-HERMES-IN HLI2-HERMES-IN-new HLI2-HERMES-ALLOW; do
      ipt -F "\$c" 2>/dev/null || true
      ipt -X "\$c" 2>/dev/null || true
    done
    ;;
  *)
    echo "uso: \$0 apply|remove" >&2
    exit 2
    ;;
esac
EOF
}

# Se ejecuta ANTES de docker.service (Before=): las reglas ya están cuando el
# demonio levanta los contenedores con 'restart: unless-stopped'. WantedBy de
# docker.service hace que Docker la arrastre al arrancar; sin PartOf, así que
# reiniciar Docker no la detiene (eso lo cubre el drop-in de ExecStartPost).
_hermes_render_egress_unit() {
  cat <<EOF
[Unit]
Description=HLI 2: aislamiento de salida del contenedor de Hermes
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${HERMES_SBIN_DIR}/hli2-hermes-egress apply

[Install]
WantedBy=multi-user.target docker.service
EOF
}

# Drop-in de docker.service: vuelve a aplicar las reglas tras cada
# (re)inicio de Docker ('-' = un fallo no impide que Docker quede activo;
# rápido, sin esperas).
_hermes_render_egress_dropin() {
  cat <<EOF
# Generado por el HLI 2 (modules/hermes.sh).
[Service]
ExecStartPost=-${HERMES_SBIN_DIR}/hli2-hermes-egress apply
EOF
}

# Escribe el archivo root:root \$1 con el contenido \$2 y modo \$3 solo si es
# distinto del actual. Deja H_FILE_CHANGED en 1/0. Creado con 'install' (modo
# final desde el inicio) y escrito con 'tee'.
H_FILE_CHANGED=0
_hermes_install_root_file() {
  local file="$1" content="$2" mode="$3" have
  have="$(sudo -n cat -- "$file" 2>/dev/null || true)"
  if [[ "$have" == "$content" ]]; then
    H_FILE_CHANGED=0
    return 0
  fi
  sudo install -d -m 0755 -o root -g root "$(dirname "$file")" || return 1
  sudo install -m "$mode" -o root -g root /dev/null "$file" || return 1
  printf '%s\n' "$content" | sudo tee "$file" >/dev/null || return 1
  H_FILE_CHANGED=1
}

# Instala (root:root) el script, la unidad y el drop-in de Docker, habilita y
# arranca la unidad y aplica las reglas YA, antes de desplegar el contenedor
# (sin ventana sin protección). Para quitarlo: systemctl disable --now
# hli2-hermes-egress.service; <sbin>/hli2-hermes-egress remove; y borrar el
# script, la unidad y docker.service.d/hli2-hermes-egress.conf.
_hermes_install_egress() {
  local subnet="$1" dns_hosts="$2" script unit dropin changed=0
  script="${HERMES_SBIN_DIR}/hli2-hermes-egress"
  unit="${HERMES_SYSTEMD_DIR}/hli2-hermes-egress.service"
  dropin="${HERMES_DOCKER_DROPIN_DIR}/hli2-hermes-egress.conf"
  if ! sudo -n sh -c 'iptables -w -S' >/dev/null 2>&1; then
    msg "No se encontró 'iptables' (o no se pudo consultar) en el servidor: hace falta para impedir que el agente alcance la LAN. Instale el paquete 'iptables' y vuelva a correr este módulo. Se cancela el despliegue de Hermes."
    return 1
  fi
  _hermes_install_root_file "$script" "$(_hermes_render_egress_script "$subnet" "$dns_hosts")" 0755 || return 1
  [[ "$H_FILE_CHANGED" -eq 0 ]] || changed=1
  _hermes_install_root_file "$unit" "$(_hermes_render_egress_unit)" 0644 || return 1
  [[ "$H_FILE_CHANGED" -eq 0 ]] || changed=1
  _hermes_install_root_file "$dropin" "$(_hermes_render_egress_dropin)" 0644 || return 1
  [[ "$H_FILE_CHANGED" -eq 0 ]] || changed=1
  [[ "$changed" -eq 0 ]] || sudo systemctl daemon-reload || true
  sudo systemctl enable --now hli2-hermes-egress.service >/dev/null 2>&1 || true
  if ! sudo "$script" apply; then
    msg "No se pudieron aplicar las reglas de aislamiento de salida de Hermes (iptables). Se cancela el despliegue: sin ellas el agente podría alcanzar la LAN."
    return 1
  fi
  log "Aislamiento de salida de Hermes aplicado (subred $subnet)."
}

# --- Publicación en la IP de Tailscale tras un reinicio ---------------------------------

# Sin esperas: ni 'network-online.target' ni un bucle sobre 'tailscale ip'
# retrasarían a Docker (y con él a AdGuard, el DNS de toda la LAN).
# - docker.service queda After=tailscaled.service (sin Wants): si Tailscale
#   está instalado, arranca antes, pero Docker no lo espera ni lo exige.
# - net.ipv4.ip_nonlocal_bind=1 permite que docker-proxy haga bind() sobre la
#   IP de Tailscale aunque tailscale0 todavía no exista. Las reglas DNAT de
#   Docker para el puerto publicado se crean con '-d <ip>' y no exigen que la
#   IP esté asignada: el kernel solo las evalúa cuando llega un paquete con ese
#   destino, o sea cuando la interfaz ya está arriba. Efecto lateral: el
#   sistema entero acepta bind() a IPs no locales (menor riesgo; ver ROADMAP).
#   Si en el servidor esto no alcanzara, la alternativa sin esperas es un
#   servicio aparte que reinicie el contenedor cuando tailscale0 obtenga IP
#   (p. ej. un tailscale-online.path/dispatcher), no un retraso de Docker.
_hermes_render_docker_dropin() {
  cat <<'EOF'
# Generado por el HLI 2 (modules/hermes.sh): si Tailscale está instalado,
# arranca antes que Docker. Sin Wants y sin esperas.
[Unit]
After=tailscaled.service
EOF
}

_hermes_render_sysctl() {
  cat <<'EOF'
# Generado por el HLI 2 (modules/hermes.sh): permite publicar el puerto de
# Hermes en la IP de Tailscale antes de que exista la interfaz tailscale0.
net.ipv4.ip_nonlocal_bind = 1
EOF
}

# Solo si hay IP de Tailscale publicada. Idempotente: no reescribe ni recarga
# nada si el contenido ya es el mismo.
_hermes_install_tailscale_boot_support() {
  local sysctl_file="${HERMES_SYSCTL_DIR}/90-hli2-hermes.conf"
  if systemctl cat tailscaled.service >/dev/null 2>&1; then
    _hermes_install_root_file "${HERMES_DOCKER_DROPIN_DIR}/hli2-tailscale.conf" "$(_hermes_render_docker_dropin)" 0644 || return 1
    [[ "$H_FILE_CHANGED" -eq 0 ]] || sudo systemctl daemon-reload || true
  fi
  _hermes_install_root_file "$sysctl_file" "$(_hermes_render_sysctl)" 0644 || return 1
  if [[ "$H_FILE_CHANGED" -eq 1 ]]; then
    sudo sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null 2>&1 || true
    log "ip_nonlocal_bind activado ($sysctl_file)."
  fi
}

# Redes a las que Dokploy dejó conectado el contenedor: debe ser solo
# 'hermes-net'; cualquier otra (p. ej. dokploy-network) le daría alcance a
# otros contenedores sin pasar por las reglas de la subred propia.
_hermes_check_container_networks() {
  local nets
  nets="$(hli_docker inspect hermes --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)" || nets=""
  nets="${nets%"${nets##*[![:space:]]}"}"
  if [[ -z "$nets" ]]; then
    msg "No se pudo verificar a qué redes quedó conectado el contenedor 'hermes' (docker inspect). Compruébelo a mano: debe estar SOLO en 'hermes-net' (docker inspect hermes --format '{{json .NetworkSettings.Networks}}')."
    return 0
  fi
  [[ "$nets" =~ ^[^[:space:]]*hermes-net$ ]] && return 0
  msg "ATENCIÓN: el contenedor 'hermes' está conectado a estas redes: ${nets}. Debería estar SOLO en 'hermes-net'. Con otra red conectada (por ejemplo 'dokploy-network') el agente podría alcanzar otros contenedores sin pasar por el aislamiento de salida. Revise el compose en el panel de Dokploy y vuelva a desplegar."
}

# Código HTTP de GET $1 (URL); $2 opcional = clave Bearer, que va a curl por
# stdin ('-K -'), nunca por argv. Imprime 000 si no hubo respuesta.
_hermes_http_code() {
  local url="$1" key="${2:-}" resp
  local -a args=(-sS --connect-timeout 5 --max-time 10 -w $'\n%{http_code}')
  if [[ -n "$key" ]]; then
    args+=(-K -)
    resp="$(curl "${args[@]}" "$url" <<<"header = \"Authorization: Bearer ${key}\"" 2>/dev/null)" || { printf '000'; return 0; }
  else
    resp="$(curl "${args[@]}" "$url" 2>/dev/null)" || { printf '000'; return 0; }
  fi
  printf '%s' "${resp##*$'\n'}"
}

# Espera a que /health responda 200. HLI2_HERMES_HEALTH_TIMEOUT/_STEP existen
# para los tests.
_hermes_wait_health() {
  local url="$1" timeout="${HLI2_HERMES_HEALTH_TIMEOUT:-120}" step="${HLI2_HERMES_HEALTH_STEP:-5}" waited=0
  hli_busy "Esperando que Hermes responda en /health..."
  while true; do
    [[ "$(_hermes_http_code "$url")" == "200" ]] && return 0
    (( waited >= timeout )) && return 1
    sleep "$step"
    waited=$(( waited + step ))
  done
}

# --- Credenciales (se muestran UNA vez) -------------------------------------------

_hermes_show_credentials() {
  local lan_ip="$1" ts_ip="$2" tries=0 max=10
  trap _hermes_creds_cleanup EXIT
  trap '_hermes_creds_cleanup; exit 130' INT HUP
  trap '_hermes_creds_cleanup; exit 143' TERM
  HERMES_CREDS_TMP="$(mktemp)"
  chmod 0600 "$HERMES_CREDS_TMP"
  {
    printf 'CREDENCIALES DE HERMES (se muestran UNA sola vez)\n\n'
    printf 'API (hermes-android)\n'
    printf '  Servidor: http://%s:8642\n' "${ts_ip:-<IP de Tailscale>}"
    # La clave (64 caracteres) va sola en su línea: con el rótulo delante la
    # línea superaba el ancho visible del textbox (76 - bordes) y dialog la
    # cortaba sin avisar (en el M70q se copiaron ~10 caracteres de menos).
    printf '  Clave de API:\n  %s\n\n' "$H_API_KEY"
    printf 'Dashboard\n'
    printf '  URL: http://%s:9119\n' "${ts_ip:-$lan_ip}"
    printf '  Usuario: admin\n'
    printf '  Contraseña: %s\n\n' "$H_DASH_PASS"
    printf 'La clave de API equivale a control total del agente (incluida la\n'
    printf 'terminal del contenedor). Guárdela en Vaultwarden: no se vuelve a\n'
    printf 'mostrar. También quedan en /etc/hli2/hermes.env (solo root).\n'
  } > "$HERMES_CREDS_TMP"
  while true; do
    hli_busy_end
    # --no-mouse: sin esto dialog captura el mouse y no se puede seleccionar
    # el texto para copiarlo (mismo criterio que modules/backup-setup.sh).
    dialog --no-mouse --title "Credenciales de Hermes" --textbox "$HERMES_CREDS_TMP" 20 76 || true
    if confirm "¿Guardó la clave de API y la contraseña del dashboard en Vaultwarden?\n\nSi elige 'No', se mostrarán de nuevo."; then
      break
    fi
    tries=$(( tries + 1 ))
    if [[ "$tries" -ge "$max" ]]; then
      _hermes_creds_cleanup
      msg "No se confirmó que las credenciales estén guardadas. Vuelva a correr este módulo: se mostrarán de nuevo."
      return 1
    fi
  done
  _hermes_creds_cleanup
  trap - EXIT INT HUP TERM
  H_PENDING="0"
  _hermes_write_secrets
}

# --- Principal -----------------------------------------------------------------

_hermes_main() {
  # Todo lo que no tiene efectos (IPs y subred) se valida primero: si algo no
  # sirve, no se pregunta ni se instala nada.
  local lan_ip ts_ip
  lan_ip="$(_hermes_lan_ip)"
  if ! _hermes_private_lan_ip "$lan_ip"; then
    msg "La IP de la LAN del servidor ('${lan_ip}') no es una dirección privada válida (10.x, 172.16-31.x o 192.168.x). Se cancela el despliegue de Hermes: sus puertos solo se publican en la LAN y en Tailscale, nunca en una IP pública ni en todas las interfaces."
    return 1
  fi
  _hermes_validate_subnet "$HERMES_SUBNET" "$lan_ip" || return 1
  ts_ip="$(_hermes_tailscale_ip)"
  local -a ips=("$lan_ip")
  [[ -z "$ts_ip" || "$ts_ip" == "$lan_ip" ]] || ips+=("$ts_ip")

  _hermes_ensure_secrets || return 1
  _hermes_prepare_dirs || return 1

  local cfg change_models=0
  cfg="$(_hermes_config_path)"
  if _hermes_config_valid; then
    if confirm "Ya existe config.yaml de Hermes (${cfg}). No se modifica.\n\n¿Cambiar solamente los modelos (principal y auxiliares)?" "no"; then
      change_models=1
      _hermes_ask_models || return 1
    fi
  else
    _hermes_ask_models || return 1
  fi
  _hermes_seed_config "$H_MODEL" "$H_AUX_MODEL" || { msg "No se pudo escribir config.yaml de Hermes. Se cancela el despliegue."; return 1; }

  # DNS del contenedor: el de la LAN (AdGuard en este servidor) solo si
  # AdGuard está instalado; si no, resolvers públicos (salen por Internet).
  local dns_csv
  if is_done adguard; then
    dns_csv="$lan_ip"
  else
    dns_csv="1.1.1.1,9.9.9.9"
  fi

  # Aislamiento de salida ANTES de crear el contenedor.
  _hermes_install_egress "$HERMES_SUBNET" "${dns_csv//,/ }" || return 1
  [[ -z "$ts_ip" ]] || _hermes_install_tailscale_boot_support || log "No se pudo instalar el soporte de arranque con Tailscale."

  dokploy_preflight || return 1

  local project_json environment_id compose_file composeId env_content
  project_json="$(dokploy_project_find_or_create)" || { msg "No se pudo crear/encontrar el proyecto 'homelab' en Dokploy."; return 1; }
  environment_id="$(dokploy_environment_default_id "$project_json")" || { msg "No se pudo resolver el ambiente por defecto del proyecto 'homelab' en Dokploy."; return 1; }

  compose_file="$(mktemp)"
  if ! compose_render_hermes "$HERMES_SUBNET" "$dns_csv" "${ips[@]}" > "$compose_file"; then
    msg "No se pudo renderizar el compose de Hermes."
    rm -f "$compose_file"
    return 1
  fi

  local l1 l2 l3 l4
  if ! l1="$(dotenv_single_quoted OPENROUTER_API_KEY "$H_OR_KEY")" \
     || ! l2="$(dotenv_single_quoted API_SERVER_KEY "$H_API_KEY")" \
     || ! l3="$(dotenv_single_quoted HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$H_DASH_PASS")" \
     || ! l4="$(dotenv_single_quoted HERMES_DASHBOARD_BASIC_AUTH_SECRET "$H_DASH_SECRET")"; then
    rm -f "$compose_file"
    msg "Un secreto guardado de Hermes tiene un formato inesperado. Vuelva a generarlo."
    return 1
  fi
  env_content="${l1}"$'\n'"${l2}"$'\n'"${l3}"$'\n'"${l4}"
  l1=""; l2=""; l3=""; l4=""

  if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "hermes" "$compose_file" "$env_content")"; then
    env_content=""; rm -f "$compose_file"
    msg "Falló el despliegue de Hermes vía la API de Dokploy. Revise las credenciales y el panel."
    return 1
  fi
  env_content=""
  rm -f "$compose_file"

  if ! service_wait_active hermes 300; then
    msg "El contenedor 'hermes' no llegó a 'activo' dentro de los 300 segundos de espera (la primera vez descarga la imagen). Revise el panel de Dokploy y los logs (sudo docker logs hermes). Puede deberse a que una IP publicada (LAN o Tailscale) todavía no existe en el host, o a las opciones de endurecimiento del compose (ver la prueba 119 de docs/VALIDACION.md): vuelva a correr este módulo cuando esté arriba."
    return 1
  fi

  _hermes_check_container_networks

  if ! _hermes_wait_health "http://${lan_ip}:8642/health"; then
    msg "El contenedor 'hermes' está corriendo pero http://${lan_ip}:8642/health no respondió OK a tiempo. Revise los logs (sudo docker logs --tail 50 hermes). No se muestran credenciales hasta que la API responda."
    return 1
  fi
  if [[ "$(_hermes_http_code "http://${lan_ip}:8642/v1/models" "$H_API_KEY")" != "200" ]]; then
    msg "/health responde, pero /v1/models con la clave de API no devolvió 200 (¿clave distinta a la que usa el contenedor?). Vuelva a correr el módulo; si persiste, revise los logs (sudo docker logs --tail 50 hermes)."
    return 1
  fi

  if [[ "$change_models" -eq 1 ]]; then
    if ! _hermes_apply_model_change; then
      return 1
    fi
    if ! _hermes_wait_health "http://${lan_ip}:8642/health"; then
      msg "Se cambiaron los modelos y se reinició Hermes, pero http://${lan_ip}:8642/health no volvió a responder a tiempo. Revise los logs (sudo docker logs --tail 50 hermes) y config.yaml (${cfg})."
      return 1
    fi
  fi

  if [[ "$H_PENDING" == "1" ]]; then
    _hermes_show_credentials "$lan_ip" "$ts_ip" || return 1
  fi

  local ts_note
  if [[ -n "$ts_ip" ]]; then
    ts_note="Desde el teléfono (Tailscale encendido): http://${ts_ip}:8642 con la clave de API."
  else
    ts_note="Tailscale no está activo en el servidor: por ahora Hermes solo responde en la LAN. Instale/inicie sesión con el módulo 'tailscale' y vuelva a correr este módulo para publicarlo también en la IP de Tailscale."
  fi
  msg "Hermes desplegado (composeId=$composeId) y respondiendo en http://${lan_ip}:8642.\n\n${ts_note}\n\nApp Android: descargue el APK desde GitHub (https://github.com/rusty4444/hermes-android/releases; el de arm64-v8a sirve para teléfonos modernos). Permita instalar de orígenes desconocidos, agregue una conexión con servidor, puerto 8642 y la clave de API.\n\nDashboard: http://${ts_ip:-$lan_ip}:9119 (usuario admin).\n\nLos puertos 8642 y 9119 solo se publican en la IP de la LAN y en la de Tailscale: no hay acceso desde Internet. El agente, por su parte, no puede iniciar conexiones hacia la LAN, Tailscale ni el propio servidor (reglas de iptables 'HLI2-HERMES-*', servicio hli2-hermes-egress); sí tiene Internet.\n\nRecomendación: reserve en el router (DHCP) la IP ${lan_ip} para este servidor; si cambia la IP de la LAN o de Tailscale, vuelva a correr este módulo para volver a publicar los puertos."

  mark_done hermes
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _hermes_main
fi
