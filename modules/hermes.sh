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
#   OpenRouter con data_collection "deny"; tareas auxiliares (lista en
#   HERMES_AUX_TASKS) con provider "auto" y model "" por defecto, que
#   significa "el modelo del chat actual" (ver más abajo).
#   https://hermes-agent.nousresearch.com/docs/user-guide/configuration
#   https://hermes-agent.nousresearch.com/docs/user-guide/security
#   https://hermes-agent.nousresearch.com/docs/user-guide/features/fallback-providers
#   https://openrouter.ai/docs/cookbook/coding-agents/hermes-integration
#
# TELEGRAM (v2.6e, opcional; fuentes del código v0.22.2, ver _hermes_telegram_setup):
# - Variables: TELEGRAM_BOT_TOKEN (gateway/config_env.py línea 512: la plataforma
#   solo se activa si el token no está vacío, así que sin token no hay nada que
#   activar; igual el compose omite las variables) y TELEGRAM_ALLOWED_USERS (IDs
#   numéricos separados por comas; gateway/pairing.py línea 68).
# - Conexión: long polling, es decir conexión saliente a api.telegram.org; el
#   modo webhook solo se usa si existe TELEGRAM_WEBHOOK_URL
#   (plugins/platforms/telegram/adapter.py línea 3155-3161), que este módulo no
#   define. El aislamiento de salida ya deja pasar Internet público (solo se
#   bloquean rangos privados), así que no hace falta ninguna regla nueva.
# - Mensajes de no autorizados: con TELEGRAM_ALLOWED_USERS definido el valor por
#   defecto de unauthorized_dm_behavior es "ignore" (gateway/authz_mixin.py líneas
#   698-748; sin lista sería "pair", que responde con códigos de emparejamiento).
#   En config.yaml nuevos se siembra además `unauthorized_dm_behavior: ignore`
#   (gateway/config_loader.py línea 102).
# - Destino por defecto de recordatorios/cron (`deliver: telegram`):
#   TELEGRAM_HOME_CHANNEL (gateway/config_env.py línea 515; cron/scheduler_delivery.py
#   líneas 44 y 479-487). En un chat privado el chat_id es el ID del usuario.
# - Estado: GET /health/detailed (api_server.py línea 2430, con la clave de la API)
#   devuelve platforms.<plataforma>.state (gateway/status.py línea 1160 "connected").
#
# TAREAS AUXILIARES (diseño corregido el 2026-10-19; reemplaza al de fijarlas a
# un modelo barato de OpenRouter y al de fijarlas a gemma4:e2b local). Todas
# quedan en 'provider: auto' y 'model: ""', que es el valor por defecto de
# Hermes (hermes_cli/config_defaults.py, _aux(), línea 26) y significa "usar el
# modelo del chat actual":
# - agent/auxiliary_client.py _resolve_auto_route (línea 4676, "(1) main
#   provider + main model") toma el proveedor/modelo de la ejecución en curso
#   (_main_route_target, línea 4563). Esa ejecución se publica en cada turno
#   (agent/turn_context.py _publish_runtime_main, línea 527) y la compresión la
#   pasa explícita (agent/conversation_compression.py línea 2041,
#   main_runtime=agent._current_main_runtime()), así que sigue la selección de
#   modelo POR CHAT de la API (gateway/platforms/api_server.py
#   _select_agent_runtime, línea 2268).
# - El problema #24029 (auxiliares que caían en un modelo pago) ya estaba
#   corregido el 2026-06-28: fijar cada tarea era innecesario y, peor, hacía
#   que un chat con DeepSeek (1M de contexto) comprimiera con un modelo
#   auxiliar más chico, o que un chat local mandara su contexto a OpenRouter.
# - Sin respaldo silencioso: con un proveedor principal elegido, el recorrido
#   de descubrimiento (probar "lo que haya") está apagado
#   (_discovery_chain_allowed, línea 4637); solo actúa 'fallback_providers'
#   (_try_main_fallback_chain, línea 4486).
# - Si el auxiliar usa la misma ruta que el chat, la compresión reutiliza la
#   ventana de contexto del modelo principal (no se recorta a la de un modelo
#   auxiliar menor).
# - Tiempos: compression.timeout vale 120 s por defecto y 300 s como piso para
#   los derivados de la configuración (config_defaults.py, línea 761: "raise
#   timeout for local models"); con un modelo local en CPU hace falta mucho más
#   (HERMES_AUX_COMPRESSION_TIMEOUT) y no_progress_timeout (60 s por defecto)
#   debe cubrir la lectura del prompt largo.
#
# Zona horaria: Hermes lee HERMES_TIMEZONE, luego 'timezone:' de config.yaml y,
# si no hay ninguno, la hora local del proceso (hermes_time.py líneas 3-5 y
# 67-75); 'TZ' solo no la lee. Sin esto los recordatorios/cron salían en UTC.
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
# Modelo del respaldo automático sembrado en config.yaml (barato). Fue también
# el modelo auxiliar por defecto de versiones anteriores: la migración lo
# reconoce como valor propio del HLI (_hermes_aux_plan).
HERMES_FALLBACK_MODEL="qwen/qwen3.7-flash"
# Zona horaria que se propone cuando el servidor está en UTC (ver
# _hermes_resolve_timezone) y carpeta de zonas del sistema (HLI2_* para tests).
HERMES_DEFAULT_TIMEZONE="America/Santiago"
HERMES_ZONEINFO_DIR="${HLI2_ZONEINFO_DIR:-/usr/share/zoneinfo}"
HERMES_TZ_FILE="${HLI2_TZ_FILE:-/etc/timezone}"
# Binario de Hermes dentro de la imagen.
HERMES_BIN="/opt/hermes/.venv/bin/hermes"
# Lista de excepciones del aislamiento de salida (v2.6c): líneas 'ip:puerto/proto'
# (root-only, junto a los secretos). La lee hli2-hermes-egress en cada 'apply'
# y las incorpora a la construcción atómica de las cadenas. Solo se aceptan
# destinos dentro de la propia subred del contenedor (nunca la LAN).
HERMES_EGRESS_ALLOW_FILE="${SECRETS_DIR}/hermes-egress-allow.conf"

# Tareas auxiliares de Hermes v0.22.2 que usan un LLM
# (DEFAULT_CONFIG["auxiliary"]); web_extract y session_search ya no lo usan.
# Todas se siembran en provider "auto" / model "" (siguen al modelo del chat);
# la lista sirve para sembrar, migrar y probar.
HERMES_AUX_TASKS=(
  vision compression skills_hub approval review mcp title_generation
  memory_query_rewrite tts_audio_tags voice_chat triage_specifier
  kanban_decomposer profile_describer goal_judge curator monitor
  background_review moa_reference moa_aggregator
)

# Tiempos de las tareas auxiliares que un modelo local en CPU puede agotar
# (un solo lugar; segundos). Hermes los toma de config.yaml:
# - compression.timeout: presupuesto total de la petición (120 por defecto).
# - compression.no_progress_timeout: espera sin ningún fragmento del modelo
#   (60 por defecto; leer un contexto largo puede tardar minutos).
# - title_generation.timeout: 30 por defecto.
HERMES_AUX_COMPRESSION_TIMEOUT=1800
HERMES_AUX_COMPRESSION_NO_PROGRESS=900
HERMES_AUX_TITLE_TIMEOUT=120
# Compresión y títulos no necesitan razonamiento (más rápido en un modelo local,
# más barato en uno de pago). Solo estas dos tareas llevan reasoning_effort: las
# demás no. Las auxiliares NO heredan agent.reasoning_overrides (solo leen
# auxiliary.<tarea>.reasoning_effort: agent/auxiliary_client.py
# _get_task_extra_body, línea 6405), por eso se fija aquí.
HERMES_AUX_REASONING_TASKS=(compression title_generation)
HERMES_AUX_REASONING_EFFORT="none"

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
# Telegram (opcional): ambos vacíos = no configurado; las claves no se escriben.
H_TG_TOKEN="" H_TG_USER=""

_hermes_write_secrets() {
  local content="OPENROUTER_API_KEY=${H_OR_KEY}
API_SERVER_KEY=${H_API_KEY}
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${H_DASH_PASS}
HERMES_DASHBOARD_BASIC_AUTH_SECRET=${H_DASH_SECRET}
HLI_CREDENTIALS_PENDING=${H_PENDING}"
  if [[ -n "$H_TG_TOKEN" && -n "$H_TG_USER" ]]; then
    content+="
TELEGRAM_BOT_TOKEN=${H_TG_TOKEN}
TELEGRAM_ALLOWED_USERS=${H_TG_USER}"
  fi
  secret_file_write hermes "$content"
}

# Forma del token de @BotFather (<id>:<secreto>) y del ID numérico de usuario.
_hermes_valid_telegram_token() { [[ "$1" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]]; }
_hermes_valid_telegram_user() { [[ "$1" =~ ^[0-9]{5,15}$ ]]; }

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
    H_TG_TOKEN="$(_hermes_env_value "$content" TELEGRAM_BOT_TOKEN)"
    H_TG_USER="$(_hermes_env_value "$content" TELEGRAM_ALLOWED_USERS)"
    content=""
    if [[ -n "$H_TG_TOKEN$H_TG_USER" ]] && { ! _hermes_valid_telegram_token "$H_TG_TOKEN" || ! _hermes_valid_telegram_user "$H_TG_USER"; }; then
      msg "Los datos de Telegram guardados en /etc/hli2/hermes.env (token o ID de usuario) tienen una forma inesperada. Corríjalos a mano (o borre las dos líneas TELEGRAM_* para quitar Telegram) y vuelva a correr el módulo."
      return 1
    fi
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
  local model="$1" timezone="$2" task
  cat <<EOF
# Sembrado por el HLI 2 (modules/hermes.sh) solo si este archivo no existía.
# Hermes y usted pueden editarlo: el HLI no lo vuelve a escribir.
model:
  provider: openrouter
  default: ${model}

# Hora local de recordatorios y tareas programadas (HERMES_TIMEZONE del
# compose tiene prioridad; ambos llevan la misma zona).
timezone: ${timezone}

# Si el modelo principal falla (429, 5xx, 401/403), se prueba este, también
# barato. Nunca un modelo caro como respaldo automático.
fallback_providers:
  - provider: openrouter
    model: ${HERMES_FALLBACK_MODEL}

# OpenRouter: excluir proveedores que puedan guardar o entrenar con los datos.
provider_routing:
  data_collection: deny

# Mensajes de personas no autorizadas (Telegram): se ignoran, sin códigos de
# emparejamiento (el valor por defecto de Hermes es "pair").
unauthorized_dm_behavior: ignore

# Tareas auxiliares: "auto" con modelo vacío = el modelo del chat actual
# (un chat local usa el modelo local, uno de OpenRouter usa ese mismo modelo).
# Los tiempos de compresión y títulos son amplios para modelos locales.
auxiliary:
EOF
  for task in "${HERMES_AUX_TASKS[@]}"; do
    printf '  %s:\n    provider: auto\n    model: ""\n' "$task"
    case "$task" in
      compression) printf '    timeout: %s\n    no_progress_timeout: %s\n    reasoning_effort: %s\n' "$HERMES_AUX_COMPRESSION_TIMEOUT" "$HERMES_AUX_COMPRESSION_NO_PROGRESS" "$HERMES_AUX_REASONING_EFFORT" ;;
      title_generation) printf '    timeout: %s\n    reasoning_effort: %s\n' "$HERMES_AUX_TITLE_TIMEOUT" "$HERMES_AUX_REASONING_EFFORT" ;;
    esac
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
  local model="$1" timezone="$2" cfg stage
  cfg="$(_hermes_config_path)"
  _hermes_config_valid && return 0
  stage="${cfg}.tmp.$$"
  if ! sudo install -m 0640 -o "$H_UID" -g "$H_GID" /dev/null "$stage"; then
    return 1
  fi
  if ! _hermes_render_config "$model" "$timezone" | sudo tee "$stage" >/dev/null; then
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

H_MODEL="$HERMES_DEFAULT_MODEL"
_hermes_ask_models() {
  local m
  m=$(input_box "Hermes — modelo principal" "Modelo principal en OpenRouter (formato autor/modelo).\n\nPor defecto se propone un modelo abierto barato con herramientas y contexto de 1M tokens (deepseek-v4.1-flash, unos 0,03 USD por millón de tokens de entrada y 0,14 de salida al 2026-10-16). Puede cambiarlo; los precios actuales están en openrouter.ai/models.\n\nLas tareas auxiliares (títulos, compresión de contexto, visión, etc.) usan el mismo modelo de cada chat: no hay un modelo auxiliar aparte." "$HERMES_DEFAULT_MODEL") \
    || { msg "Se cancela el despliegue de Hermes."; return 1; }
  if ! _hermes_valid_model "$m"; then
    msg "El id del modelo no tiene la forma autor/modelo de OpenRouter (por ejemplo deepseek/deepseek-v4.1-flash). Se cancela: vuelva a correr el módulo."
    return 1
  fi
  H_MODEL="$m"
}

# En una re-ejecución, con config.yaml ya existente: cambia SOLO la clave del
# modelo principal, con la propia CLI de Hermes dentro del contenedor ya
# desplegado (no se edita YAML a mano: el archivo puede haber sido reescrito
# por el agente). Se ejecuta con el uid/gid del agente ('-u'): 'docker exec'
# como root dejaría archivos de root dentro de /opt/data.
_hermes_apply_model_change() {
  if ! hli_docker exec -u "${H_UID}:${H_GID}" hermes "$HERMES_BIN" config set model.default "$H_MODEL" >/dev/null 2>&1; then
    msg "No se pudo cambiar el modelo con la CLI de Hermes. Edite a mano ${APPDATA_ROOT}/hermes/config.yaml (clave model.default) y reinicie el contenedor 'hermes'."
    return 1
  fi
  hli_docker restart hermes >/dev/null 2>&1 || true
}

# --- Zona horaria ------------------------------------------------------------------

# ¿$1 es una zona horaria utilizable? Forma segura (la misma regla del render
# del compose) Y que exista en la base de zonas del sistema.
_hermes_valid_timezone() {
  _compose_valid_timezone "$1" && [[ -f "${HERMES_ZONEINFO_DIR}/$1" ]]
}

# Zonas que equivalen a "sin zona configurada" (servidores en UTC).
_hermes_utc_like_zone() {
  case "$1" in
    ""|UTC|Etc/UTC|UCT|Etc/UCT|Zulu|Etc/Zulu|Universal|Etc/Universal|GMT|Etc/GMT) return 0 ;;
  esac
  return 1
}

# Zona del servidor ('timedatectl show -p Timezone --value'; si falla,
# /etc/timezone). Vacío si no se pudo determinar.
_hermes_host_timezone() {
  local tz=""
  tz="$(timedatectl show -p Timezone --value 2>/dev/null | head -n1)" || tz=""
  [[ -n "$tz" ]] || tz="$(head -n1 "$HERMES_TZ_FILE" 2>/dev/null)" || tz=""
  printf '%s' "$tz"
}

# 'timezone:' ya presente en el config.yaml de Hermes ('' si no hay).
_hermes_config_timezone() {
  local line v
  line="$(sudo -n cat -- "$(_hermes_config_path)" 2>/dev/null | grep -E -m1 '^timezone:')" || return 0
  v="${line#timezone:}"
  v="${v%%#*}"
  v="${v//[\"\' ]/}"
  printf '%s' "$v"
}

# Deja en H_TZ la zona horaria para HERMES_TIMEZONE. Se usa la del servidor; si
# es UTC (o no se pudo leer) se pregunta, proponiendo la ya guardada en
# config.yaml o, si no hay, HERMES_DEFAULT_TIMEZONE. Una respuesta que no sea
# una zona válida cancela el despliegue (todavía no se instaló nada).
H_TZ=""
_hermes_resolve_timezone() {
  local tz saved default
  tz="$(_hermes_host_timezone)"
  if ! _hermes_utc_like_zone "$tz" && _hermes_valid_timezone "$tz"; then
    H_TZ="$tz"
    return 0
  fi
  saved="$(_hermes_config_timezone)"
  default="$HERMES_DEFAULT_TIMEZONE"
  if [[ -n "$saved" ]] && ! _hermes_utc_like_zone "$saved" && _hermes_valid_timezone "$saved"; then
    default="$saved"
  fi
  tz=$(input_box "Hermes — zona horaria" "El servidor está en UTC (o no se pudo leer su zona horaria). Hermes usa la zona horaria para la hora de los recordatorios y las tareas programadas: sin ella un recordatorio de las 9:00 saldría a la hora de UTC.\n\nIndique su zona en formato Región/Ciudad (por ejemplo America/Santiago, America/Bogota, Europe/Madrid)." "$default") \
    || { msg "Se cancela el despliegue de Hermes: no se indicó la zona horaria."; return 1; }
  tz="${tz#"${tz%%[![:space:]]*}"}"
  tz="${tz%"${tz##*[![:space:]]}"}"
  if _hermes_utc_like_zone "$tz" || ! _hermes_valid_timezone "$tz"; then
    msg "'${tz}' no es una zona horaria válida de este sistema (se espera, por ejemplo, America/Santiago; la lista está en ${HERMES_ZONEINFO_DIR}). Se cancela el despliegue: vuelva a correr el módulo."
    return 1
  fi
  H_TZ="$tz"
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

# AdGuard con "Allowed clients" (dns.allowed_clients no vacío) rechaza a todo
# cliente fuera de la lista, y las consultas de Hermes salen de su propia
# subred $1: sin agregarla, el contenedor no resuelve nombres y no llega a
# OpenRouter (pasó en el M70q, 2026-10-18). Solo avisa: tocar AdGuardHome.yaml
# exige reiniciar AdGuard (corte de DNS para toda la casa).
_hermes_adguard_acl_check() {
  local subnet="$1" yaml="$APPDATA_ROOT/adguard/conf/AdGuardHome.yaml" content clients
  content="$(priv_file_read "$yaml" 2>/dev/null)" || return 0
  clients="$(printf '%s\n' "$content" | awk '
    /^[[:space:]]*allowed_clients:/ { inlist=1; if ($0 ~ /\[\]/) inlist=0; next }
    inlist && /^[[:space:]]*-[[:space:]]/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; next }
    inlist && /^[[:space:]]*[^[:space:]-]/ { inlist=0 }
  ')"
  [[ -n "$clients" ]] || return 0
  if ! printf '%s\n' "$clients" | grep -qxF "$subnet"; then
    msg "AdGuard Home tiene una lista de 'Allowed clients' y no incluye la red de Hermes ($subnet).\n\nSin agregarla, Hermes no puede resolver nombres ni llegar a OpenRouter (responde 'Your request was not processed').\n\nEn AdGuard: Settings -> DNS settings -> Access settings -> Allowed clients, agregue una línea:\n\n$subnet\n\ny guarde."
  fi
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
# - Excepciones (v2.6c, Ollama): el archivo $HERMES_EGRESS_ALLOW_FILE
#   (root-only) lista destinos 'ip:puerto/proto'. 'apply' los valida UNO POR
#   UNO (IPv4 de la propia subred del contenedor, ni .0, .1 ni .255; puerto
#   1-65535; tcp o udp) y agrega un ACCEPT por cada uno DENTRO de la
#   construcción atómica de la cadena FWD (antes del hook), así que sobreviven a
#   reinicios y a cada 'apply'. Una línea inválida se ignora con un aviso (nunca
#   se abre una excepción por una línea dudosa). Además queda el hook
#   HLI2-HERMES-ALLOW para reglas manuales: 'apply' no la reconstruye y
#   'remove' SÍ la vacía y la borra.
#   Razonamiento sobre el tráfico dentro del mismo puente: pasa por FORWARD (y
#   por DOCKER-USER) solo si br_netfilter está activo (bridge-nf-call-iptables=1).
#   Si lo está, el DROP hacia 10.0.0.0/8 bloquearía a Hermes -> Ollama (están en
#   10.x), así que la excepción es necesaria; si no lo está, la regla es
#   inocua. No se verificó en el servidor cuál es el caso.
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
ALLOW_FILE="${HERMES_EGRESS_ALLOW_FILE}"
EXPECT_UID="\${HLI2_EGRESS_EXPECT_UID:-0}"
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

# Excepciones válidas de \$ALLOW_FILE, una por línea: "ip puerto proto". El
# archivo se lee como root, así que primero se exige que sea un archivo regular
# (no un enlace), del uid esperado (0; HLI2_EGRESS_EXPECT_UID solo para los
# tests) y con modo 600 o 400; si no, se ignora entero con un aviso. Solo se
# recortan los espacios de los extremos de cada línea (los internos invalidan la
# línea), un CR (archivo con fin de línea de Windows) la invalida, y solo valen
# destinos dentro de la subred del contenedor (nunca la LAN), host .2-.254, sin
# ceros a la izquierda; lo demás se ignora con un aviso.
allow_rules() {
  local line a b c d port proto st
  [[ -e "\$ALLOW_FILE" || -L "\$ALLOW_FILE" ]] || return 0
  if [[ -L "\$ALLOW_FILE" || ! -f "\$ALLOW_FILE" ]]; then
    echo "hli2-hermes-egress: \$ALLOW_FILE no es un archivo regular: se ignora" >&2
    return 0
  fi
  st="\$(stat -c '%u %a' -- "\$ALLOW_FILE" 2>/dev/null)" || st=""
  if [[ "\$st" != "\$EXPECT_UID 600" && "\$st" != "\$EXPECT_UID 400" ]]; then
    echo "hli2-hermes-egress: \$ALLOW_FILE debe ser de root (uid \$EXPECT_UID) con modo 600 o 400 (tiene '\$st'): se ignora" >&2
    return 0
  fi
  while IFS= read -r line || [[ -n "\$line" ]]; do
    if [[ "\$line" == *\$'\\r'* ]]; then
      echo "hli2-hermes-egress: línea con retorno de carro ignorada en \$ALLOW_FILE" >&2
      continue
    fi
    line="\${line#"\${line%%[![:space:]]*}"}"
    line="\${line%"\${line##*[![:space:]]}"}"
    [[ -n "\$line" && "\${line:0:1}" != "#" ]] || continue
    if [[ "\$line" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2}):([1-9][0-9]{0,4})/(tcp|udp)\$ ]]; then
      a=\${BASH_REMATCH[1]}; b=\${BASH_REMATCH[2]}; c=\${BASH_REMATCH[3]}; d=\${BASH_REMATCH[4]}
      port=\${BASH_REMATCH[5]}; proto="\${BASH_REMATCH[6]}"
      if (( a <= 255 && b <= 255 && c <= 255 && d >= 2 && d <= 254 && port <= 65535 )) && [[ "\$a.\$b.\$c" == "\${SUBNET%.*}" ]]; then
        printf '%s %s %s\\n' "\$a.\$b.\$c.\$d" "\$port" "\$proto"
        continue
      fi
    fi
    echo "hli2-hermes-egress: excepción ignorada en \$ALLOW_FILE: \$line" >&2
  done < "\$ALLOW_FILE"
}

fill_chain() {
  local chain="\$1" kind="\$2" d r ip port proto
  ipt -N "\$chain"
  ipt -A "\$chain" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  # Solo en FWD (tráfico hacia otros contenedores/máquinas): la cadena IN es
  # para destinos que son el propio servidor, y las excepciones son de la subred.
  if [[ "\$kind" == "fwd" ]]; then
    while read -r ip port proto; do
      ipt -A "\$chain" -d "\$ip" -p "\$proto" --dport "\$port" -j ACCEPT
    done < <(allow_rules)
  fi
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

# --- Lista de excepciones del aislamiento (v2.6c) -------------------------------------

# ¿$1 es una excepción válida 'ip:puerto/proto' dentro de la subred $2
# (a.b.c.0/24)? Mismas reglas que aplica hli2-hermes-egress al leer el
# archivo: IPv4 canónica (sin ceros a la izquierda) de la propia subred, host
# entre .2 y .254 (.1 es la puerta de enlace = el propio servidor), puerto
# 1-65535, tcp o udp. Nunca una IP de la LAN.
_hermes_valid_allow_entry() {
  local entry="$1" subnet="$2" ip port
  [[ "$entry" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3}):([0-9]{1,5})/(tcp|udp)$ ]] || return 1
  local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}" p="${BASH_REMATCH[5]}"
  [[ "$a" != 0?* && "$b" != 0?* && "$c" != 0?* && "$d" != 0?* && "$p" != 0* ]] || return 1
  (( a <= 255 && b <= 255 && c <= 255 && d >= 2 && d <= 254 && p >= 1 && p <= 65535 )) || return 1
  ip="${a}.${b}.${c}"
  [[ "$subnet" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\.0/24$ ]] || return 1
  [[ "$ip" == "${BASH_REMATCH[1]}" ]]
}

# Escribe root:root 0600 el archivo $1 con el contenido $2 de forma atómica:
# temporal en la MISMA carpeta (creado ya con el modo final) y 'mv' (rename). Si
# algo falla, el archivo anterior queda intacto y no sobra el temporal; si el
# proceso muere a medias, la próxima escritura borra los restos. No
# cambia el modo de la carpeta (puede ser /etc/hli2, 0700).
_hermes_root_write() {
  local f="$1" content="$2" stage
  stage="${f}.tmp.$$"
  # Restos de una escritura interrumpida antes (nombre único por proceso: no
  # hay trap que pueda pisar el de quien llama).
  sudo -n sh -c 'rm -f -- "$1".tmp.*' _ "$f" 2>/dev/null || true
  sudo -n install -d -m 0700 -o root -g root "$(dirname "$f")" 2>/dev/null || true
  sudo -n install -m 0600 -o root -g root /dev/null "$stage" || return 1
  if ! printf '%s\n' "$content" | sudo -n tee "$stage" >/dev/null; then
    sudo -n rm -f "$stage"
    return 1
  fi
  if ! sudo -n mv -f "$stage" "$f"; then
    sudo -n rm -f "$stage"
    return 1
  fi
}

# Agrega la excepción $1 al archivo (root-only 0600 en $SECRETS_DIR) si no
# estaba. Valida contra la subred $2. Escritura atómica (_hermes_root_write).
# Aborta si 'sudo' no está disponible (no se puede saber si el archivo existe:
# nunca se asume "no existe", se perderían las demás excepciones).
_hermes_allow_add() {
  local entry="$1" subnet="$2" f content="" line
  _hermes_valid_allow_entry "$entry" "$subnet" || { echo "ERROR: excepción no válida o fuera de la subred de Hermes: '$entry'." >&2; return 1; }
  f="$HERMES_EGRESS_ALLOW_FILE"
  sudo -n true 2>/dev/null || { echo "ERROR: 'sudo' no está disponible sin contraseña: no se puede leer ni escribir $f." >&2; return 1; }
  if sudo -n test -f "$f" 2>/dev/null; then
    content="$(sudo -n cat -- "$f" 2>/dev/null)" || { echo "ERROR: no se pudo leer $f." >&2; return 1; }
    while IFS= read -r line; do
      [[ "$line" == "$entry" ]] && return 0
    done <<<"$content"
  else
    content="# Excepciones del aislamiento de salida de Hermes (HLI 2).
# Una por línea: ip:puerto/proto. Solo destinos dentro de la subred de Hermes.
# La lee hli2-hermes-egress en cada 'apply'."
  fi
  _hermes_root_write "$f" "$content"$'\n'"$entry"
}

# --- Tareas auxiliares: siguen al modelo del chat (migración compartida) --------------------

# Versiones anteriores del HLI fijaron las tareas auxiliares de dos maneras:
#   (O) v2.6a: provider openrouter + un modelo barato (HERMES_FALLBACK_MODEL u
#       otro elegido por el usuario en el cuadro de entrada de entonces).
#   (L) v2.6c: provider custom + base_url http://<IP>:11434/v1 + api_key
#       ficticia + model gemma4:e2b + timeout 3600 + reasoning_effort none (+
#       no_progress_timeout 900 en compression).
# Ambas se reemplazan por provider auto / model "" (ver el encabezado). Este
# código lo comparten los módulos 'hermes' y 'ollama'; actúa SOLO sobre lo que
# el HLI escribió (por valor) y lista aparte las tareas con valores propios del
# usuario, que no toca.
#
# Cómo se quitan claves: la CLI de Hermes v0.22.2 tiene 'hermes config unset
# <clave>' (hermes_cli/config.py, unset_config_value línea 3767 y el despacho
# _CONFIG_SUBCOMMANDS línea 3976): borra la clave del config.yaml del usuario
# (_unset_nested) y deja que valga el valor por defecto de DEFAULT_CONFIG
# (base_url "", api_key "", timeout de cada tarea, reasoning_effort ""). Si la
# clave no existe sale con error ("Config key not set"), por eso solo se pide
# quitar las claves que se leyeron del archivo.
# 'hermes config set <clave> ""' guarda la cadena vacía tal cual (el valor por
# defecto de 'model' es una cadena, _coerce_config_set_value línea 3376), que es
# el "sin modelo propio" de 'auto'.
#
# Orden de las operaciones de cada tarea: primero tiempos y razonamiento,
# después api_key y base_url y al final model y provider. Una migración
# interrumpida deja siempre una tarea todavía reconocible como propia, así que
# la re-ejecución la completa.
HERMES_AUX_MARKER="${SECRETS_DIR}/hermes-aux-auto"
HERMES_AUX_MARKER_TAG="# aux-version: 2 (reasoning_effort none en compression y title_generation)"
HERMES_AUX_LEGACY_MARKER="${SECRETS_DIR}/hermes-aux-migrated"
HERMES_AUX_PREV_FILE="${SECRETS_DIR}/hermes-aux-previous.conf"
# Valores que escribió la versión (L); un solo lugar.
HERMES_LEGACY_LOCAL_AUX_MODEL="gemma4:e2b"
HERMES_LEGACY_LOCAL_AUX_TIMEOUT=3600
HERMES_LEGACY_LOCAL_AUX_KEY="no-key-required"
HERMES_OLLAMA_PORT=11434

# Estado de la migración (globales: los leen los manejadores de Ctrl-C y los
# mensajes finales de los módulos).
declare -a H_AUX_OPS=()       # "aux:<tarea>\t<set|unset>\t<clave>\t<valor>"
declare -a H_AUX_PLANNED=()   # tareas que hay que pasar a 'auto'
declare -a H_AUX_CUSTOM=()    # tareas con valores propios (no se tocan)
declare -A H_AUX_PREV_PROV=() # tarea -> proveedor/modelo antes de migrar
H_AUX_SKIP=0                  # 1 = marcador presente: no se revisa nada
H_AUX_PREV_FAIL=0             # 1 = no se pudo guardar el registro previo
H_AUX_INCOMPLETE=0
AUX_PREV_NOTE=""
AUX_CUSTOM_NOTE=""

# Valores del bloque 'auxiliary' del YAML $1: "tarea\tclave\tvalor" por línea.
_hermes_aux_parse() {
  awk '
    function clean(v) { gsub(/["\047]/, "", v); return v }
    /^auxiliary:/ { on = 1; next }
    on && /^[^[:space:]#]/ { on = 0 }
    on && /^  [A-Za-z_]+:[[:space:]]*$/ { task = $1; sub(/:$/, "", task); next }
    on && task != "" && /^    (provider|model|base_url|api_key|timeout|reasoning_effort|no_progress_timeout):/ {
      key = $1; sub(/:$/, "", key); printf "%s\t%s\t%s\n", task, key, clean($2)
    }
  ' <<<"$1"
}

# Bloque de nivel superior $2 (p. ej. 'auxiliary', 'fallback_providers') del
# YAML en $1, tal cual está escrito (vacío si no existe).
_hermes_yaml_block() {
  awk -v k="$2" '
    $0 ~ ("^" k ":") { on = 1; print; next }
    on && /^[^[:space:]#-]/ { on = 0 }
    on { print }
  ' <<<"$1"
}

# Resumen "tarea: proveedor/modelo" del bloque auxiliary (solo tareas escritas).
_hermes_aux_summary() {
  awk '
    function clean(v) { gsub(/["\047]/, "", v); return v }
    /^auxiliary:/ { on = 1; next }
    on && /^[^[:space:]#]/ { on = 0 }
    on && /^  [A-Za-z_]+:[[:space:]]*$/ { task = $1; sub(/:$/, "", task); order[++n] = task; next }
    on && task != "" && /^    provider:/ { prov[task] = clean($2) }
    on && task != "" && /^    model:/ { mod[task] = clean($2) }
    END { for (i = 1; i <= n; i++) { t = order[i]; printf "%s: %s/%s\n", t, (prov[t] == "" ? "auto" : prov[t]), (mod[t] == "" ? "(modelo principal)" : mod[t]) } }
  ' <<<"$1"
}

# Calcula, a partir del YAML $1, qué tareas hay que pasar a 'auto' y con qué
# operaciones. Llena H_AUX_PLANNED, H_AUX_OPS y H_AUX_CUSTOM (sin tocar nada).
_hermes_aux_plan() {
  local content="$1" t task key val p m b k to re np state ormodel best=0 n want_re
  local -A cfg=() mcount=()
  H_AUX_OPS=() H_AUX_PLANNED=() H_AUX_CUSTOM=()
  while IFS=$'\t' read -r task key val; do
    [[ -n "$task" ]] && cfg["${task}.${key}"]="$val"
  done < <(_hermes_aux_parse "$content")

  # Modelo auxiliar que eligió el usuario en la versión (O): el que comparten
  # más de la mitad de las tareas (cuenta también las ya pasadas a 'auto' que
  # conservan el modelo). El valor por defecto de entonces siempre cuenta.
  ormodel=""
  for t in "${HERMES_AUX_TASKS[@]}"; do
    p="${cfg[$t.provider]:-}" m="${cfg[$t.model]:-}" b="${cfg[$t.base_url]:-}" k="${cfg[$t.api_key]:-}"
    [[ -n "$m" && -z "$b" && -z "$k" && ( "$p" == "openrouter" || "$p" == "auto" || -z "$p" ) ]] || continue
    mcount["$m"]=$(( ${mcount[$m]:-0} + 1 ))
  done
  for m in "${!mcount[@]}"; do
    n="${mcount[$m]}"
    if (( n > best && n * 2 > ${#HERMES_AUX_TASKS[@]} )); then best="$n"; ormodel="$m"; fi
  done

  for t in "${HERMES_AUX_TASKS[@]}"; do
    p="${cfg[$t.provider]:-}" m="${cfg[$t.model]:-}" b="${cfg[$t.base_url]:-}" k="${cfg[$t.api_key]:-}"
    to="${cfg[$t.timeout]:-}" re="${cfg[$t.reasoning_effort]:-}" np="${cfg[$t.no_progress_timeout]:-}"
    state=custom
    if [[ ( -z "$p" || "$p" == "auto" ) && -z "$m" && -z "$b" && -z "$k" ]]; then
      state=clean
    elif [[ ( -z "$b" || "$b" =~ ^https?://[^/]+:${HERMES_OLLAMA_PORT}/v1/?$ ) \
         && ( -z "$k" || "$k" == "$HERMES_LEGACY_LOCAL_AUX_KEY" ) \
         && ( -z "$m" || "$m" == "$HERMES_LEGACY_LOCAL_AUX_MODEL" ) \
         && ( "$p" == "custom" || "$p" == "auto" || -z "$p" ) \
         && ( -n "$b" || -n "$k" || -n "$m" || "$p" == "custom" ) ]]; then
      state=local
    elif [[ -z "$b" && -z "$k" && -n "$m" && ( "$p" == "openrouter" || "$p" == "auto" || -z "$p" ) \
         && ( "$m" == "$HERMES_FALLBACK_MODEL" || "$m" == "$ormodel" ) ]]; then
      state=openrouter
    fi
    want_re=""
    case "$t" in compression|title_generation) want_re="$HERMES_AUX_REASONING_EFFORT" ;; esac
    case "$state" in
      clean)
        # Ya en auto: solo falta el razonamiento de compresión/títulos.
        if [[ -n "$want_re" && "$re" != "$want_re" ]]; then
          H_AUX_PLANNED+=("$t")
          H_AUX_OPS+=("aux:${t}"$'\t'"set"$'\t'"auxiliary.${t}.reasoning_effort"$'\t'"${want_re}")
        fi
        continue ;;
      custom)
        H_AUX_CUSTOM+=("${t} (${p:-auto}/${m:-modelo principal}${b:+, ${b}})")
        continue ;;
    esac
    H_AUX_PLANNED+=("$t")
    local unit="aux:${t}" want_to=""
    case "$t" in
      compression) want_to="$HERMES_AUX_COMPRESSION_TIMEOUT"
        [[ "$np" == "$HERMES_AUX_COMPRESSION_NO_PROGRESS" ]] || H_AUX_OPS+=("${unit}"$'\t'"set"$'\t'"auxiliary.${t}.no_progress_timeout"$'\t'"${HERMES_AUX_COMPRESSION_NO_PROGRESS}") ;;
      title_generation) want_to="$HERMES_AUX_TITLE_TIMEOUT" ;;
    esac
    [[ -z "$want_re" || "$re" == "$want_re" ]] || H_AUX_OPS+=("${unit}"$'\t'"set"$'\t'"auxiliary.${t}.reasoning_effort"$'\t'"${want_re}")
    if [[ -n "$want_to" ]]; then
      [[ "$to" == "$want_to" ]] || H_AUX_OPS+=("${unit}"$'\t'"set"$'\t'"auxiliary.${t}.timeout"$'\t'"${want_to}")
    elif [[ "$state" == local && "$to" == "$HERMES_LEGACY_LOCAL_AUX_TIMEOUT" ]]; then
      H_AUX_OPS+=("${unit}"$'\t'"unset"$'\t'"auxiliary.${t}.timeout"$'\t')
    fi
    if [[ "$state" == local ]]; then
      [[ -n "$want_re" || "$re" != "none" ]] || H_AUX_OPS+=("${unit}"$'\t'"unset"$'\t'"auxiliary.${t}.reasoning_effort"$'\t')
      [[ -z "$k" ]] || H_AUX_OPS+=("${unit}"$'\t'"unset"$'\t'"auxiliary.${t}.api_key"$'\t')
      [[ -z "$b" ]] || H_AUX_OPS+=("${unit}"$'\t'"unset"$'\t'"auxiliary.${t}.base_url"$'\t')
      # Para (L) primero el modelo y al final el proveedor; para (O) al revés.
      [[ -z "$m" ]] || H_AUX_OPS+=("${unit}"$'\t'"set"$'\t'"auxiliary.${t}.model"$'\t')
      [[ -z "$p" || "$p" == "auto" ]] || H_AUX_OPS+=("${unit}"$'\t'"set"$'\t'"auxiliary.${t}.provider"$'\t'"auto")
    else
      [[ -z "$p" || "$p" == "auto" ]] || H_AUX_OPS+=("${unit}"$'\t'"set"$'\t'"auxiliary.${t}.provider"$'\t'"auto")
      [[ -z "$m" ]] || H_AUX_OPS+=("${unit}"$'\t'"set"$'\t'"auxiliary.${t}.model"$'\t')
    fi
  done
}

# Deja en el archivo root-only $HERMES_AUX_PREV_FILE los valores de 'auxiliary'
# previos a la migración (solo la primera vez: una re-ejecución no debe pisar el
# registro original). Deja en AUX_PREV_NOTE el resumen. Retorna 1 si no pudo
# guardarlo.
_hermes_aux_record_previous() {
  local content="$1" block summary
  AUX_PREV_NOTE=""
  block="$(_hermes_yaml_block "$content" auxiliary)"
  summary="$(_hermes_aux_summary "$content")"
  if sudo -n test -f "$HERMES_AUX_PREV_FILE" 2>/dev/null; then
    AUX_PREV_NOTE="Se conserva el registro anterior de las tareas auxiliares en ${HERMES_AUX_PREV_FILE}."
    return 0
  fi
  if ! _hermes_root_write "$HERMES_AUX_PREV_FILE" "# Valores de 'auxiliary' de Hermes ANTES de pasarlas a 'auto' (siguen al modelo del chat; HLI 2), $(date +%F).
# Para revertir una tarea: hermes config set auxiliary.<tarea>.provider/.model con estos valores
# (y .base_url/.api_key si los tenía). Solo root.
${block:-# (sin bloque auxiliary: valores por defecto de Hermes, provider auto)}"; then
    AUX_PREV_NOTE="AVISO: no se pudo guardar el registro de las tareas auxiliares previas en ${HERMES_AUX_PREV_FILE}."
    return 1
  fi
  if [[ -n "$summary" ]]; then
    AUX_PREV_NOTE="Valores previos de las tareas auxiliares (guardados en ${HERMES_AUX_PREV_FILE}, solo root): $(printf '%s' "$summary" | tr '\n' ';')"
  else
    AUX_PREV_NOTE="Tareas auxiliares previas: ninguna escrita en config.yaml (provider auto = el modelo del chat); registro en ${HERMES_AUX_PREV_FILE}."
  fi
}

# Prepara la migración con el config.yaml $1: llena H_AUX_* (plan, tareas con
# valores propios y proveedor/modelo previos) y guarda el registro previo ANTES
# de que se toque nada. Con el marcador presente no revisa nada (así no se
# pisan las decisiones que el usuario tome después).
_hermes_aux_prepare() {
  local content="$1" line custom
  H_AUX_OPS=() H_AUX_PLANNED=() H_AUX_CUSTOM=() H_AUX_PREV_PROV=()
  H_AUX_SKIP=0 H_AUX_PREV_FAIL=0 H_AUX_INCOMPLETE=0 AUX_PREV_NOTE="" AUX_CUSTOM_NOTE=""
  # Un marcador sin la etiqueta de razonamiento es de la versión anterior: se
  # revisa otra vez (el plan va por valores y no toca lo que el usuario fijó).
  if sudo -n cat -- "$HERMES_AUX_MARKER" 2>/dev/null | grep -qF "$HERMES_AUX_MARKER_TAG"; then
    H_AUX_SKIP=1
    return 0
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] && H_AUX_PREV_PROV["${line%%:*}"]="${line#*: }"
  done < <(_hermes_aux_summary "$content")
  _hermes_aux_plan "$content"
  if [[ "${#H_AUX_CUSTOM[@]}" -gt 0 ]]; then
    custom="$(printf '%s; ' "${H_AUX_CUSTOM[@]}")"
    AUX_CUSTOM_NOTE="Tareas auxiliares con valores propios que NO se tocaron (siguen fijadas a lo que usted puso; para que sigan al modelo del chat use 'hermes config set auxiliary.<tarea>.provider auto' y '.model \"\"'): ${custom%; }."
  fi
  if [[ "${#H_AUX_PLANNED[@]}" -gt 0 ]]; then
    if ! _hermes_aux_record_previous "$content"; then
      H_AUX_PREV_FAIL=1
      H_AUX_OPS=()
    fi
  fi
}

# Ejecución de operaciones de 'hermes config' dentro del contenedor, con el
# uid/gid del agente. Entradas en H_RUN: "unidad\t<set|unset>\tclave\tvalor".
# Una unidad (p. ej. "aux:vision") queda hecha solo si TODAS sus operaciones
# salieron bien. Los valores van como argumentos (nunca por una shell).
declare -a H_RUN=()
declare -A H_UNIT_OK=()
H_OPS_FAILED=0
H_CUR_UNIT="" H_CUR_FAILED=0

_hermes_unit_close() {
  if [[ -n "$H_CUR_UNIT" && "$H_CUR_FAILED" -eq 0 ]]; then
    H_UNIT_OK["$H_CUR_UNIT"]=1
  fi
  H_CUR_UNIT="" H_CUR_FAILED=0
}

_hermes_run_ops() {
  local uid="$1" gid="$2" entry unit rest op key val
  H_OPS_FAILED=0 H_UNIT_OK=() H_CUR_UNIT="" H_CUR_FAILED=0
  for entry in "${H_RUN[@]}"; do
    unit="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"
    op="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    key="${rest%%$'\t'*}"; val="${rest#*$'\t'}"
    if [[ "$unit" != "$H_CUR_UNIT" ]]; then _hermes_unit_close; H_CUR_UNIT="$unit"; fi
    if [[ "$op" == "unset" ]]; then
      hli_docker exec -u "${uid}:${gid}" hermes "$HERMES_BIN" config unset "$key" >/dev/null 2>&1 \
        || { H_CUR_FAILED=1; H_OPS_FAILED=1; }
    else
      hli_docker exec -u "${uid}:${gid}" hermes "$HERMES_BIN" config set "$key" "$val" >/dev/null 2>&1 \
        || { H_CUR_FAILED=1; H_OPS_FAILED=1; }
    fi
  done
  _hermes_unit_close
}

# "migración incompleta: X de N tareas ..." con las que faltan y su valor previo.
_hermes_incomplete_note() {
  local t pending="" n=0
  for t in "${H_AUX_PLANNED[@]}"; do
    [[ -n "${H_UNIT_OK[aux:$t]:-}" ]] && continue
    n=$(( n + 1 ))
    pending+="${t}: ${H_AUX_PREV_PROV[$t]:-auto/(modelo principal)}; "
  done
  if [[ "$n" -gt 0 ]]; then
    printf "migración incompleta: %s de %s tareas auxiliares quedaron sin pasar a 'auto' o a medias (%s); vuelva a correr el módulo para completarla." \
      "$n" "${#H_AUX_PLANNED[@]}" "${pending%; }"
  else
    printf 'configuración de Hermes incompleta: alguna clave no se pudo escribir con la CLI; vuelva a correr el módulo.'
  fi
}

# Ctrl-C / TERM mientras se configura Hermes: el disco puede tener la
# configuración a medias, así que se reinicia Hermes (para que el proceso
# coincida con el disco), se muestra el aviso y se sale SIN marcar nada.
_hermes_cfg_interrupt() {
  trap - INT TERM
  hli_docker restart hermes >/dev/null 2>&1 || true
  msg "Se interrumpió la configuración de Hermes. $(_hermes_incomplete_note)\n\nHermes se reinició para que coincida con lo que quedó escrito."
  exit 130
}

# Cierra la migración: si TODO quedó bien ($1 = 1 si otra parte de la
# configuración falló) deja el marcador root-only; si no, H_AUX_INCOMPLETE=1.
# Sin plan (todo ya en 'auto', p. ej. una instalación nueva) solo escribe el
# marcador. Con el marcador presente no hace nada.
_hermes_aux_finish() {
  local other_failed="${1:-0}" t pending=0
  for t in "${H_AUX_PLANNED[@]}"; do
    [[ -n "${H_UNIT_OK[aux:$t]:-}" ]] || pending=$(( pending + 1 ))
  done
  if [[ "$other_failed" -eq 1 || "$H_OPS_FAILED" -eq 1 || "$H_AUX_PREV_FAIL" -eq 1 || "$pending" -gt 0 ]]; then
    H_AUX_INCOMPLETE=1
    return 0
  fi
  [[ "$H_AUX_SKIP" -eq 0 ]] || return 0
  if ! _hermes_root_write "$HERMES_AUX_MARKER" "# Las tareas auxiliares de Hermes siguen al modelo del chat (provider auto, model vacío), HLI 2, $(date +%F).
# Mientras exista, los módulos 'hermes' y 'ollama' no revisan ni tocan el bloque 'auxiliary'
# (respetan lo que usted fije después). Bórrelo para repetir la revisión.
${HERMES_AUX_MARKER_TAG}"; then
    H_AUX_INCOMPLETE=1
  fi
}

# Migración completa desde el módulo 'hermes' (con el contenedor ya arriba):
# prepara, ejecuta, cierra y, si cambió algo, reinicia Hermes. Retorna 1 si
# quedó incompleta (el aviso queda en AUX_MIGRATION_NOTE). Sin config.yaml
# utilizable no hay nada que migrar.
AUX_MIGRATION_NOTE=""
H_AUX_RESTARTED=0
_hermes_aux_migrate() {
  local uid="$1" gid="$2" content
  AUX_MIGRATION_NOTE="" H_AUX_RESTARTED=0
  _hermes_config_valid || return 0
  content="$(sudo -n cat -- "$(_hermes_config_path)" 2>/dev/null)" || content=""
  _hermes_aux_prepare "$content"
  H_RUN=("${H_AUX_OPS[@]}")
  H_OPS_FAILED=0 H_UNIT_OK=()
  if [[ "${#H_RUN[@]}" -gt 0 ]]; then
    hli_busy "Pasando las tareas auxiliares de Hermes a 'auto' (siguen al modelo del chat)..."
    trap '_hermes_cfg_interrupt' INT TERM
    _hermes_run_ops "$uid" "$gid"
    trap - INT TERM
  fi
  _hermes_aux_finish 0
  # Hermes se reinicia siempre que se escribió algo (también si quedó a medias):
  # el proceso tiene que coincidir con el disco.
  if [[ "${#H_RUN[@]}" -gt 0 ]]; then
    hli_docker restart hermes >/dev/null 2>&1 || true
    H_AUX_RESTARTED=1
  fi
  if [[ "$H_AUX_INCOMPLETE" -eq 1 ]]; then
    if [[ "$H_AUX_PREV_FAIL" -eq 1 ]]; then
      AUX_MIGRATION_NOTE="No se migraron las tareas auxiliares porque no se pudo guardar el registro de sus valores previos (${HERMES_AUX_PREV_FILE}). $(_hermes_incomplete_note)"
    else
      AUX_MIGRATION_NOTE="$(_hermes_incomplete_note)"
    fi
    return 1
  fi
  return 0
}

# --- Telegram (opcional) ---------------------------------------------------------------------

# Pide el token y el ID de usuario y los deja en H_TG_*. Retorna 2 si el usuario
# cancela un cuadro (Telegram se omite sin abortar el despliegue) y 1 si un
# valor no tiene la forma esperada (se cancela el despliegue, como la clave de
# OpenRouter). Los valores no se muestran ni se registran.
_hermes_telegram_ask() {
  local token user
  msg "Para conectar Telegram necesita dos datos:\n\n1. El TOKEN del bot: en Telegram abra @BotFather, envíe /newbot, elija un nombre y un usuario que termine en 'bot'; BotFather le entrega un token con la forma 123456789:AAE... (tratelo como una contraseña).\n\n2. Su ID NUMÉRICO de usuario: abra @userinfobot y envíele /start; responde con su 'Id' (solo dígitos).\n\nSolo ese usuario podrá hablar con el bot: los mensajes de cualquier otra cuenta se ignoran. Hermes se conecta hacia afuera (api.telegram.org, sin puertos entrantes), pero las conversaciones por Telegram pasan por los servidores de Telegram: úselo para avisos, recordatorios y consultas que no sean privadas.\n\nEn los siguientes pasos se le pedirán; el token no se muestra en pantalla ni se registra en logs."
  token=$(password_box "Hermes — token del bot de Telegram" "Pegue el token que le dio @BotFather.") \
    || { msg "Se omite Telegram: no se ingresó ningún token."; return 2; }
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"
  if ! _hermes_valid_telegram_token "$token"; then
    token=""
    msg "El valor ingresado no tiene la forma de un token de bot de Telegram (<número>:<texto de 30 o más letras, números, '-' o '_'>). Se cancela el despliegue: copie de nuevo el token desde @BotFather y vuelva a correr este módulo."
    return 1
  fi
  user=$(input_box "Hermes — usuario de Telegram" "Su ID numérico de usuario de Telegram (el que le muestra @userinfobot). Solo este usuario podrá usar el bot." "") \
    || { token=""; msg "Se omite Telegram: no se ingresó ningún ID de usuario."; return 2; }
  user="${user#"${user%%[![:space:]]*}"}"
  user="${user%"${user##*[![:space:]]}"}"
  if ! _hermes_valid_telegram_user "$user"; then
    token=""
    msg "El ID de usuario debe ser numérico (5 a 15 dígitos). Se cancela el despliegue: vuelva a correr este módulo."
    return 1
  fi
  H_TG_TOKEN="$token"; H_TG_USER="$user"
  token=""
}

# Paso opcional de Telegram: configurar (por defecto No), o, si ya está, cambiar
# o quitar. Guarda en /etc/hli2/hermes.env solo si hubo un cambio.
_hermes_telegram_setup() {
  local rc=0 old_token="$H_TG_TOKEN" old_user="$H_TG_USER"
  if [[ -n "$H_TG_TOKEN" ]]; then
    confirm "Telegram ya está configurado (usuario autorizado: ${H_TG_USER}).\n\n¿Cambiarlo o quitarlo?" "no" || return 0
    if confirm "¿Quitar Telegram por completo? (Si elige 'No' se le pedirá un token y un usuario nuevos.)" "no"; then
      H_TG_TOKEN="" H_TG_USER=""
    else
      _hermes_telegram_ask || rc=$?
    fi
  else
    confirm "¿Configurar Telegram como canal de Hermes (avisos y recordatorios al teléfono)?" "no" || return 0
    _hermes_telegram_ask || rc=$?
  fi
  if [[ "$rc" -eq 2 ]]; then
    H_TG_TOKEN="$old_token"; H_TG_USER="$old_user"
    return 0
  elif [[ "$rc" -ne 0 ]]; then
    H_TG_TOKEN="$old_token"; H_TG_USER="$old_user"
    return 1
  fi
  if [[ "$H_TG_TOKEN" != "$old_token" || "$H_TG_USER" != "$old_user" ]]; then
    _hermes_write_secrets || { msg "No se pudieron guardar los datos de Telegram en /etc/hli2/hermes.env. Se cancela el despliegue de Hermes."; return 1; }
    log "Configuración de Telegram de Hermes actualizada en /etc/hli2/hermes.env (no se loguean los valores)."
  fi
  return 0
}

# Estado de Telegram según GET /health/detailed (clave de la API por stdin,
# '-K -'): imprime el estado (p. ej. connected) o nada. Espera como máximo lo
# mismo que _hermes_wait_health (HLI2_HERMES_HEALTH_*).
_hermes_telegram_state() {
  local url="$1" key="$2" timeout="${HLI2_HERMES_HEALTH_TIMEOUT:-120}" step="${HLI2_HERMES_HEALTH_STEP:-5}" waited=0 body st=""
  while true; do
    body="$(curl -sS --connect-timeout 5 --max-time 10 -w $'\n%{http_code}' -K - "$url" <<<"header = \"Authorization: Bearer ${key}\"" 2>/dev/null)" || body=""
    body="${body%$'\n'*}"
    st="$(jq -r '.platforms.telegram.state // empty' <<<"$body" 2>/dev/null)" || st=""
    [[ "$st" == "connected" ]] && break
    (( waited >= timeout )) && break
    sleep "$step"
    waited=$(( waited + step ))
  done
  printf '%s' "$st"
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
    if confirm "Ya existe config.yaml de Hermes (${cfg}). No se modifica.\n\n¿Cambiar solamente el modelo principal? (las tareas auxiliares siguen al modelo de cada chat)" "no"; then
      change_models=1
      _hermes_ask_models || return 1
    fi
  else
    _hermes_ask_models || return 1
  fi
  _hermes_resolve_timezone || return 1
  _hermes_telegram_setup || return 1
  _hermes_seed_config "$H_MODEL" "$H_TZ" || { msg "No se pudo escribir config.yaml de Hermes. Se cancela el despliegue."; return 1; }

  # DNS del contenedor: el de la LAN (AdGuard en este servidor) solo si
  # AdGuard está instalado; si no, resolvers públicos (salen por Internet).
  local dns_csv
  if is_done adguard; then
    dns_csv="$lan_ip"
    _hermes_adguard_acl_check "$HERMES_SUBNET"
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
  local -a tg_flag=()
  [[ -z "$H_TG_TOKEN" ]] || tg_flag=(--telegram)
  if ! compose_render_hermes "${tg_flag[@]}" "$HERMES_SUBNET" "$dns_csv" "$H_TZ" "${ips[@]}" > "$compose_file"; then
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
  if [[ -n "$H_TG_TOKEN" ]]; then
    local t1 t2
    if ! t1="$(dotenv_single_quoted TELEGRAM_BOT_TOKEN "$H_TG_TOKEN")" || ! t2="$(dotenv_single_quoted TELEGRAM_ALLOWED_USERS "$H_TG_USER")"; then
      rm -f "$compose_file"
      msg "Un dato de Telegram guardado tiene un formato inesperado. Vuelva a configurarlo."
      return 1
    fi
    env_content+=$'\n'"${t1}"$'\n'"${t2}"
    t1=""; t2=""
  fi

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

  # Tareas auxiliares a 'auto' (siguen al modelo del chat): migra los valores
  # fijados por versiones anteriores del HLI y deja el marcador en instalaciones
  # nuevas.
  if ! _hermes_aux_migrate "$H_UID" "$H_GID"; then
    msg "ATENCIÓN: ${AUX_MIGRATION_NOTE}"
    return 1
  fi
  if [[ "$H_AUX_RESTARTED" -eq 1 ]] && ! _hermes_wait_health "http://${lan_ip}:8642/health"; then
    msg "Se pasaron las tareas auxiliares a 'auto' y se reinició Hermes, pero http://${lan_ip}:8642/health no volvió a responder a tiempo. Revise los logs (sudo docker logs --tail 50 hermes) y config.yaml (${cfg})."
    return 1
  fi

  local tg_note=""
  if [[ -n "$H_TG_TOKEN" ]]; then
    if [[ "$(_hermes_telegram_state "http://${lan_ip}:8642/health/detailed" "$H_API_KEY")" == "connected" ]]; then
      tg_note="Telegram: conectado. Envíele /start (o cualquier mensaje) a su bot desde su cuenta (ID ${H_TG_USER}); las demás cuentas se ignoran. Para probar los avisos pídale: \"recuérdame en 2 minutos probar Telegram\" y que lo envíe a Telegram."
    else
      tg_note="Telegram: NO figura como conectado todavía (GET /health/detailed). Revise el token y los logs (sudo docker logs --tail 50 hermes | grep -i telegram) y vuelva a correr este módulo. Hermes se conecta hacia api.telegram.org (HTTPS saliente, ya permitido por el aislamiento de salida)."
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
  msg "Hermes desplegado (composeId=$composeId) y respondiendo en http://${lan_ip}:8642.\n\n${ts_note}\n\nApp Android: descargue el APK desde GitHub (https://github.com/rusty4444/hermes-android/releases; el de arm64-v8a sirve para teléfonos modernos). Permita instalar de orígenes desconocidos, agregue una conexión con servidor, puerto 8642 y la clave de API.\n\nDashboard: http://${ts_ip:-$lan_ip}:9119 (usuario admin).\n\nLos puertos 8642 y 9119 solo se publican en la IP de la LAN y en la de Tailscale: no hay acceso desde Internet. El agente, por su parte, no puede iniciar conexiones hacia la LAN, Tailscale ni el propio servidor (reglas de iptables 'HLI2-HERMES-*', servicio hli2-hermes-egress); sí tiene Internet.\n\nZona horaria: ${H_TZ} (los recordatorios y tareas programadas salen a esa hora). Las tareas auxiliares (títulos, compresión de contexto, visión, etc.) siguen al modelo de cada chat.${tg_note:+\n\n${tg_note}}${AUX_PREV_NOTE:+\n\n${AUX_PREV_NOTE}}${AUX_CUSTOM_NOTE:+\n\n${AUX_CUSTOM_NOTE}}\n\nRecomendación: reserve en el router (DHCP) la IP ${lan_ip} para este servidor; si cambia la IP de la LAN o de Tailscale, vuelva a correr este módulo para volver a publicar los puertos."

  mark_done hermes
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _hermes_main
fi
