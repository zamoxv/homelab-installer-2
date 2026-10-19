#!/usr/bin/env bash
# HLI-MODULE: ollama
# HLI-DESC: Ollama (IA local en CPU, cerebro privado opcional de Hermes, vía API de Dokploy)
# HLI-ORDER: 69
# HLI-DEFAULT: no
# HLI-TUI: yes
# HLI-REQUIERE: dokploy-api
#
# v2.6c: despliega Ollama como compose de Dokploy (compose/ollama/
# docker-compose.yml), descarga gemma4:e4b (cerebro local) y gemma4:e2b
# (fondo) y, SI Hermes está instalado, lo conecta como proveedor local
# seleccionable por chat. Funciona solo (sin Hermes): en ese caso queda en su
# propia red y no hay integración.
#
# HLI-DEFAULT: no, a propósito: descarga ~11 GB de modelos y reserva 8 CPU y
# 20 GB de RAM; no debe dispararse dentro de "instalar todo".
#
# Hechos verificados el 2026-10-18 (fuentes oficiales):
# - Imagen ollama/ollama:0.40.6 (Docker Hub, 2026-10-17; GitHub release
#   v0.40.6 del 2026-10-16, no prerelease), fijada además por digest de la
#   lista de manifiestos (amd64+arm64). https://hub.docker.com/r/ollama/ollama
# - Variables: OLLAMA_HOST, OLLAMA_KEEP_ALIVE, OLLAMA_NUM_PARALLEL,
#   OLLAMA_MAX_LOADED_MODELS y OLLAMA_CONTEXT_LENGTH (envconfig/config.go,
#   v0.40.6; https://docs.ollama.com/faq). La API compatible con OpenAI no
#   permite fijar num_ctx por petición (https://docs.ollama.com/api/openai-compatibility),
#   pero api.DefaultOptions toma OLLAMA_CONTEXT_LENGTH, así que el valor del
#   servidor rige también en /v1/chat/completions: no hace falta un modelo
#   derivado con Modelfile. No existe variable de entorno para los hilos.
# - Etiquetas gemma4:e4b y gemma4:e2b existentes (https://ollama.com/library/gemma4/tags),
#   contexto máximo del modelo 128K.
# - "Pensamiento" de gemma4: por la API compatible con OpenAI se apaga con
#   reasoning_effort "none" (openai/openai.go: ThinkingFromReasoningEffort mapea
#   "none" a think=false). Hermes envía reasoning_effort a los endpoints
#   locales (por defecto "medium") y permite fijarlo por modelo con
#   agent.reasoning_overrides (documentación de configuración de Hermes).
#   OJO: 'hermes config set X none' guarda null (_SCALAR_WORDS), por eso se usa
#   'false', que Hermes interpreta como "desactivado".
# - Hermes v0.22.2 (código y documentación): exige >= 64.000 tokens de contexto
#   (agent/model_metadata.py MINIMUM_CONTEXT_LENGTH), por eso 65536 y no 32768;
#   proveedores nombrados en 'providers.<id>' con 'api', 'models.<modelo>.
#   context_length', 'request_timeout_seconds' y 'stale_timeout_seconds'
#   (https://hermes-agent.nousresearch.com/docs/integrations/providers y
#   .../user-guide/configuration); 'platforms.api_server.model_routes' (alias ->
#   {model, provider, base_url, api_key}) hace que /v1/models liste esos alias
#   (gateway/platforms/api_server.py _handle_models) y /api/model/options lista
#   los modelos de 'providers:' (hermes_cli/inventory.py).
# - RESPALDO AUTOMÁTICO (hallazgo de privacidad): 'fallback_providers' es global
#   (gateway/run.py GatewayRunner._load_fallback_model se pasa a todo agente de
#   la API) y no hay forma de excluir un proveedor; solo se desactiva en una
#   petición con 'require_model_lock: true' (api_server.py: fallback_model None
#   con bloqueo confirmado), algo que decide la app cliente. Un chat local que
#   falle (timeout, 5xx, respuesta vacía) se reintentaría contra OpenRouter y
#   enviaría el contexto afuera. Por eso el módulo ofrece vaciar la cadena
#   ('hermes fallback clear'); es la opción conservadora.
#
# - TAREAS AUXILIARES (decisión del usuario, 2026-10-18): las 19 pasan a
#   gemma4:e2b local ('auxiliary.<tarea>.provider: custom' + base_url, ver
#   _ollama_aux_pairs; agent/auxiliary_client.py _resolve_task_provider_model).
#   Se guarda el bloque previo en /etc/hli2/hermes-aux-previous.conf. Excepción
#   que no se puede cerrar: con un proveedor auxiliar explícito, una caída de
#   conexión o un error 402/cuota cae al modelo principal (documentación de
#   Hermes, "Auxiliary Capacity-Error Fallback": el último recurso corre siempre).
#
# Red: con Hermes instalado se une a la red de Hermes (nombre real tomado de
# Docker: Dokploy le antepone el proyecto) con IP fija .250 de su subred
# (HLI2_OLLAMA_IP lo cambia); el DHCP interno de Docker asigna desde .2 hacia
# arriba, así que con unos pocos contenedores nunca llega a .250. Una única
# excepción de firewall: Hermes -> esa IP, tcp/11434, en la lista root-only que
# lee hli2-hermes-egress (ver modules/hermes.sh).
set -euo pipefail
source "$(dirname "$0")/hermes.sh"

OLLAMA_PORT=11434
OLLAMA_PROVIDER_ID="ollama-local"
# Modelos: cerebro local y trabajador de fondo (etiquetas verificadas).
OLLAMA_MODELS=(gemma4:e4b gemma4:e2b)
OLLAMA_CTX=65536
OLLAMA_TIMEOUT=3600
HERMES_BIN="/opt/hermes/.venv/bin/hermes"
HERMES_PY="/opt/hermes/.venv/bin/python"

# Estado de la detección (se llena en _ollama_detect).
O_MODE="standalone" O_NET="" O_IP="" O_SUBNET="" O_DNS=""

# Alias que /v1/models de Hermes muestra: "gemma4:e4b" -> "gemma4-e4b-local".
_ollama_alias() {
  local t="$1"
  t="${t//[:.]/-}"
  printf '%s-local' "$t"
}

# Valor de VAR (SUBNET, DNS_HOSTS) en el script de aislamiento instalado.
_ollama_egress_var() {
  local script="${HERMES_SBIN_DIR}/hli2-hermes-egress"
  sudo -n cat -- "$script" 2>/dev/null | awk -F'"' -v k="$1" '$0 ~ ("^" k "=") { print $2; exit }'
}

# Nombre real de la red de Hermes ($1 = subred esperada, la del script de
# aislamiento): una red '…hermes-net' cuya subred IPAM sea EXACTAMENTE esa. Si
# hay más de una candidata o ninguna coincide, vacío y return 1 (una red con otra
# subred no está cubierta por las reglas del firewall).
_ollama_hermes_network() {
  local subnet="$1" names n found="" count=0 subs sn
  names="$(hli_docker network ls --format '{{.Name}}' 2>/dev/null)" || return 1
  while IFS= read -r n; do
    [[ "$n" == *hermes-net ]] || continue
    subs="$(hli_docker network inspect "$n" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)" || continue
    for sn in $subs; do
      [[ "$sn" == "$subnet" ]] || continue
      found="$n"; count=$(( count + 1 ))
      break
    done
  done <<<"$names"
  [[ "$count" -eq 1 ]] || return 1
  printf '%s' "$found"
}

# ¿Otro contenedor de la red $1 ya usa la IP $2?
_ollama_ip_taken() {
  local net="$1" ip="$2" out name addr
  out="$(hli_docker network inspect "$net" --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null)" || return 1
  while read -r name addr; do
    [[ -n "$name" && "${addr%/*}" == "$ip" && "$name" != "ollama" ]] && return 0
  done <<<"$out"
  return 1
}

# Decide el modo (hermes | standalone) y valida TODO antes de instalar nada.
_ollama_detect() {
  O_MODE="standalone"
  is_done hermes || return 0
  local subnet dns net ip
  subnet="$(_ollama_egress_var SUBNET)"
  dns="$(_ollama_egress_var DNS_HOSTS)"
  net="$(_ollama_hermes_network "$subnet")" || net=""
  if [[ -z "$subnet" || -z "$dns" || -z "$net" ]]; then
    msg "Hermes figura como instalado, pero no se encontró su red de Docker (con la subred del aislamiento) o su script de aislamiento (/usr/local/sbin/hli2-hermes-egress). Ollama se despliega por separado, en su propia red, y NO se integra con Hermes. Vuelva a correr el módulo 'hermes' y luego este."
    return 0
  fi
  ip="${HLI2_OLLAMA_IP:-${subnet%.0/24}.250}"
  if ! _hermes_valid_allow_entry "${ip}:${OLLAMA_PORT}/tcp" "$subnet"; then
    msg "La IP de Ollama ('${ip}') no es válida: debe estar dentro de la subred de Hermes (${subnet}), entre .2 y .254. Defina otra con HLI2_OLLAMA_IP y vuelva a correr el módulo."
    return 1
  fi
  if _ollama_ip_taken "$net" "$ip"; then
    msg "La IP ${ip} de la red de Hermes ya la usa otro contenedor. Defina otra con HLI2_OLLAMA_IP y vuelva a correr el módulo."
    return 1
  fi
  O_MODE="hermes" O_NET="$net" O_IP="$ip" O_SUBNET="$subnet" O_DNS="${dns// /,}"
}

# --- Despliegue ---------------------------------------------------------------------

# Carpeta de modelos: ya puede existir (creada por un contenedor root al
# descargar los modelos a mano). Ollama corre como root dentro de su imagen:
# root:root 0755.
_ollama_prepare_dirs() {
  sudo install -d -m 0755 -o root -g root "$APPDATA_ROOT/ollama"
}

# Espera a que el servidor responda dentro del contenedor.
_ollama_wait_ready() {
  local timeout="${HLI2_OLLAMA_READY_TIMEOUT:-120}" step="${HLI2_OLLAMA_READY_STEP:-5}" waited=0
  hli_busy "Esperando que Ollama responda..."
  while true; do
    hli_docker exec ollama ollama list >/dev/null 2>&1 && return 0
    (( waited >= timeout )) && return 1
    sleep "$step"
    waited=$(( waited + step ))
  done
}

# ¿El modelo $1 ya está descargado? (primera columna de 'ollama list').
_ollama_has_model() {
  hli_docker exec ollama ollama list 2>/dev/null | awk -v m="$1" 'NR > 1 && $1 == m { found = 1 } END { exit !found }'
}

# Descarga los modelos que falten, con el progreso de Ollama en la terminal
# (no dentro de un cuadro de dialog). Idempotente: omite los ya presentes.
_ollama_pull_models() {
  local m
  local -a tty_flag=()
  [[ -t 1 ]] && tty_flag=(-t)
  for m in "${OLLAMA_MODELS[@]}"; do
    if _ollama_has_model "$m"; then
      log "Modelo $m ya descargado: se omite."
      continue
    fi
    hli_busy_end
    echo
    echo "Descargando $m (puede tardar varios minutos; el progreso aparece abajo)..."
    if ! hli_docker exec "${tty_flag[@]}" ollama ollama pull "$m"; then
      msg "No se pudo descargar el modelo ${m}. Revise la conexión y el DNS del contenedor (sudo docker logs --tail 50 ollama) y vuelva a correr este módulo: retoma donde quedó."
      return 1
    fi
  done
}

# Redes del contenedor: debe estar SOLO en la esperada ($1: hermes-net u
# ollama-net). Otra red (p. ej. dokploy-network) lo expondría a otros contenedores.
_ollama_check_networks() {
  local expected="$1" nets n bad=0
  nets="$(hli_docker inspect ollama --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)" || nets=""
  nets="${nets%"${nets##*[![:space:]]}"}"
  if [[ -z "$nets" ]]; then
    msg "No se pudo verificar a qué redes quedó conectado el contenedor 'ollama' (docker inspect). Compruébelo a mano: debe estar SOLO en una red *${expected}."
    return 0
  fi
  for n in $nets; do [[ "$n" == *"$expected" ]] || bad=1; done
  [[ "$bad" -eq 0 ]] || msg "ATENCIÓN: el contenedor 'ollama' está conectado a estas redes: ${nets}. Debería estar SOLO en una red *${expected}: con otra red (por ejemplo 'dokploy-network') otros contenedores podrían alcanzarlo. Revise el compose en el panel de Dokploy y vuelva a desplegar."
}

# --- Integración con Hermes ------------------------------------------------------------

# Cuerpo de GET $1 con la clave Bearer en stdin (-K -), nunca por argv.
_ollama_http_body() {
  local url="$1" key="$2"
  curl -sS --connect-timeout 5 --max-time 15 -K - "$url" <<<"header = \"Authorization: Bearer ${key}\"" 2>/dev/null || true
}

# Modelo local de las tareas auxiliares (rápido, con imágenes) y archivos de
# registro root-only (para revertir).
OLLAMA_AUX_MODEL="gemma4:e2b"
OLLAMA_AUX_TIMEOUT=3600
OLLAMA_AUX_PREV_FILE="${SECRETS_DIR}/hermes-aux-previous.conf"
OLLAMA_FALLBACK_REMOVED_FILE="${SECRETS_DIR}/hermes-fallback-removed.conf"

# Pares "clave valor" del proveedor y las rutas para 'hermes config set'. Con el
# proveedor ya presente en config.yaml solo se actualizan las URL (la IP pudo
# cambiar): no se pisan los tiempos de espera ni nada que el usuario haya editado.
_ollama_config_pairs() {
  local ip="$1" full="$2" m alias base="http://${1}:${OLLAMA_PORT}/v1"
  printf '%s\t%s\n' "providers.${OLLAMA_PROVIDER_ID}.api" "$base"
  for m in "${OLLAMA_MODELS[@]}"; do
    alias="$(_ollama_alias "$m")"
    printf '%s\t%s\n' "platforms.api_server.model_routes.${alias}.base_url" "$base"
  done
  [[ "$full" -eq 1 ]] || return 0
  printf '%s\t%s\n' "providers.${OLLAMA_PROVIDER_ID}.request_timeout_seconds" "$OLLAMA_TIMEOUT"
  printf '%s\t%s\n' "providers.${OLLAMA_PROVIDER_ID}.stale_timeout_seconds" "$OLLAMA_TIMEOUT"
  for m in "${OLLAMA_MODELS[@]}"; do
    alias="$(_ollama_alias "$m")"
    printf '%s\t%s\n' "providers.${OLLAMA_PROVIDER_ID}.models.${m}.context_length" "$OLLAMA_CTX"
    printf '%s\t%s\n' "platforms.api_server.model_routes.${alias}.model" "$m"
    printf '%s\t%s\n' "platforms.api_server.model_routes.${alias}.provider" "$OLLAMA_PROVIDER_ID"
    # Clave ficticia: sin ella el cliente usaría la de OpenRouter contra Ollama.
    printf '%s\t%s\n' "platforms.api_server.model_routes.${alias}.api_key" "no-key-required"
    # 'false' = pensamiento desactivado ('none' se guardaría como null).
    printf '%s\t%s\n' "agent.reasoning_overrides.${m}" "false"
  done
}

# Tareas auxiliares a la IA local (decisión del usuario, 2026-10-18): TODAS las
# de HERMES_AUX_TASKS. Cada una con provider 'custom' + base_url + api_key
# ficticia (agent/auxiliary_client.py _resolve_task_provider_model: una base_url
# explícita con provider 'custom' se respeta tal cual, sin depender de que el
# nombre 'providers.ollama-local' se resuelva), modelo gemma4:e2b, pensamiento
# desactivado ('none': el valor por defecto de esos campos es una cadena, así que
# 'hermes config set' la conserva literal y no la convierte en null) y tiempo de
# espera largo. Los campos 'timeout' y 'reasoning_effort' solo existen en el
# bloque por defecto de algunas tareas (hermes_cli/config_defaults.py): 'review'
# no tiene ninguno y 'memory_query_rewrite' no tiene 'reasoning_effort'.
_ollama_aux_pairs() {
  local ip="$1" t base="http://${1}:${OLLAMA_PORT}/v1" pre
  for t in "${HERMES_AUX_TASKS[@]}"; do
    pre="auxiliary.${t}"
    printf '%s\t%s\n' "${pre}.provider" "custom"
    printf '%s\t%s\n' "${pre}.model" "$OLLAMA_AUX_MODEL"
    printf '%s\t%s\n' "${pre}.base_url" "$base"
    printf '%s\t%s\n' "${pre}.api_key" "no-key-required"
    [[ "$t" == "review" ]] || printf '%s\t%s\n' "${pre}.timeout" "$OLLAMA_AUX_TIMEOUT"
    case "$t" in review|memory_query_rewrite) ;; *) printf '%s\t%s\n' "${pre}.reasoning_effort" "none" ;; esac
  done
  # La compresión de un contexto largo puede pasar minutos sin emitir nada.
  printf '%s\t%s\n' "auxiliary.compression.no_progress_timeout" "900"
}

# Bloque de nivel superior $2 (p. ej. 'auxiliary', 'fallback_providers') del
# YAML en $1, tal cual está escrito (vacío si no existe).
_ollama_yaml_block() {
  awk -v k="$2" '
    $0 ~ ("^" k ":") { on = 1; print; next }
    on && /^[^[:space:]#-]/ { on = 0 }
    on { print }
  ' <<<"$1"
}

# Resumen "tarea: proveedor/modelo" del bloque auxiliary (solo tareas escritas).
_ollama_aux_summary() {
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

# Tareas auxiliares que YA apuntan a Ollama (base_url con :11434/v1), una por
# línea: en una re-ejecución solo a ellas se les actualiza la URL.
_ollama_aux_already_local() {
  awk '
    /^auxiliary:/ { on = 1; next }
    on && /^[^[:space:]#]/ { on = 0 }
    on && /^  [A-Za-z_]+:[[:space:]]*$/ { task = $1; sub(/:$/, "", task); next }
    on && task != "" && /^    base_url:.*:11434\/v1/ { print task }
  ' <<<"$1"
}

# ¿config.yaml ya tiene la sección providers.ollama-local?
_ollama_config_has_provider() {
  local content
  content="$(sudo -n cat -- "$(_hermes_config_path)" 2>/dev/null)" || return 1
  grep -Eq "^  ${OLLAMA_PROVIDER_ID}:" <<<"$content"
}

# ¿Hay respaldo automático configurado? 'fallback_providers' con entradas (la
# lista no vacía se guarda como 'fallback_providers:' a secas; vacía, '[]') o la
# clave heredada 'fallback_model' (Hermes v0.22.2 aún la lee: hermes_cli/
# fallback_cmd.py _read_chain y _write_chain, que la elimina al escribir; la CLI
# 'hermes fallback clear' cubre ambas).
_ollama_config_has_fallback() {
  local content
  content="$(sudo -n cat -- "$(_hermes_config_path)" 2>/dev/null)" || return 1
  grep -Eq '^fallback_providers:[[:space:]]*$' <<<"$content" && return 0
  local line v
  line="$(grep -E -m1 '^fallback_model:' <<<"$content")" || return 1
  v="${line#fallback_model:}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    ""|"#"*)
      # Valor en las líneas siguientes (mapa o lista) o nulo: hay entradas si el bloque tiene más de una línea.
      [[ "$(_ollama_yaml_block "$content" fallback_model | wc -l)" -gt 1 ]] ;;
    null|Null|NULL|"~"|"{}"|"[]") return 1 ;;
    *) return 0 ;;
  esac
}

# Prueba desde DENTRO del contenedor de Hermes que alcanza a Ollama (el firewall
# deja pasar solo esa IP y puerto). Imprime el código HTTP.
_ollama_probe_from_hermes() {
  local ip="$1" uid="$2" gid="$3"
  hli_docker exec -u "${uid}:${gid}" hermes "$HERMES_PY" -c \
    "import urllib.request as u; print(u.urlopen('http://${ip}:${OLLAMA_PORT}/api/tags', timeout=8).status)" 2>/dev/null || true
}

# Deja en el archivo root-only $OLLAMA_AUX_PREV_FILE los valores de 'auxiliary'
# previos a la migración (solo la primera vez: una re-ejecución no debe pisar el
# registro original con valores ya locales). Deja en AUX_PREV_NOTE el resumen.
_ollama_record_aux_previous() {
  local content="$1" block summary
  AUX_PREV_NOTE=""
  block="$(_ollama_yaml_block "$content" auxiliary)"
  summary="$(_ollama_aux_summary "$content")"
  if sudo -n test -f "$OLLAMA_AUX_PREV_FILE" 2>/dev/null; then
    AUX_PREV_NOTE="Se conserva el registro anterior de las tareas auxiliares en ${OLLAMA_AUX_PREV_FILE}."
    return 0
  fi
  if ! _hermes_root_write "$OLLAMA_AUX_PREV_FILE" "# Valores de 'auxiliary' de Hermes ANTES de pasarlas a la IA local (HLI 2, módulo ollama), $(date +%F).
# Para revertir una tarea: hermes config set auxiliary.<tarea>.provider/.model con estos valores
# y vaciar .base_url y .api_key. Solo root.
${block:-# (sin bloque auxiliary: valores por defecto de Hermes, provider auto)}"; then
    AUX_PREV_NOTE="AVISO: no se pudo guardar el registro de las tareas auxiliares previas en ${OLLAMA_AUX_PREV_FILE}."
    return 1
  fi
  if [[ -n "$summary" ]]; then
    AUX_PREV_NOTE="Valores previos de las tareas auxiliares (guardados en ${OLLAMA_AUX_PREV_FILE}, solo root): $(printf '%s' "$summary" | tr '\n' ';')"
  else
    AUX_PREV_NOTE="Tareas auxiliares previas: ninguna escrita en config.yaml (provider auto = el modelo principal); registro en ${OLLAMA_AUX_PREV_FILE}."
  fi
}

# Agrega el proveedor a config.yaml SIN reescribir el archivo: 'hermes config
# set' dentro del contenedor, con el uid/gid del agente. Retorna 0 aunque algo
# falle (el módulo informa y el usuario puede completar a mano).
_ollama_integrate_hermes() {
  local ip="$1" uid gid lan_ip key full=1 failed=0 k v body drop_fallback=0 content block t
  uid="$(id -u "$SERVER_USER")" gid="$(id -g "$SERVER_USER")"
  INTEGRATION_NOTE="" AUX_PREV_NOTE="" FALLBACK_NOTE="" AUX_MOVED=0
  local -a pairs=()

  if ! _hermes_config_valid; then
    INTEGRATION_NOTE="No se integró con Hermes: no hay un config.yaml utilizable en ${APPDATA_ROOT}/hermes. Vuelva a correr el módulo 'hermes' y luego este."
    return 0
  fi
  content="$(sudo -n cat -- "$(_hermes_config_path)" 2>/dev/null)" || content=""
  if _ollama_config_has_provider; then full=0; fi

  # Privacidad: el respaldo automático es global y mandaría a OpenRouter un chat
  # local que falle (ver el encabezado de este archivo). Cambiar un
  # comportamiento en vivo exige un "Sí" explícito: el botón por defecto es "No".
  if _ollama_config_has_fallback; then
    if confirm "Hermes tiene un respaldo automático (fallback_providers) hacia OpenRouter. Es GLOBAL: no se puede excluir a Ollama. Si un chat local falla (tiempo agotado, error del servidor, respuesta vacía), Hermes reintentaría ese mensaje con OpenRouter y la conversación saldría de su casa sin aviso.\n\nSe recomienda quitarlo. Antes de hacerlo se guardan las entradas (solo root) en ${OLLAMA_FALLBACK_REMOVED_FILE} para poder restituirlas con 'hermes fallback add'.\n\nContra: si OpenRouter falla, el chat con el modelo por defecto da error en vez de probar otro.\n\n¿Quitar el respaldo automático?" "no"; then
      drop_fallback=1
    fi
  fi

  # Registro previo de 'auxiliary' ANTES de tocar nada (solo en la primera
  # migración, que es cuando se mueven las tareas).
  if [[ "$full" -eq 1 ]]; then
    _ollama_record_aux_previous "$content" || true
  fi

  if [[ "$drop_fallback" -eq 1 ]]; then
    block="$(_ollama_yaml_block "$content" fallback_providers)"$'\n'"$(_ollama_yaml_block "$content" fallback_model)"
    if _hermes_root_write "$OLLAMA_FALLBACK_REMOVED_FILE" "# Respaldo automático de Hermes quitado por el módulo ollama (HLI 2), $(date +%F).
# Para restituirlo: hermes fallback add (pide proveedor y modelo de cada entrada). Solo root.
${block}"; then
      FALLBACK_NOTE="Respaldo automático quitado; las entradas quedaron en ${OLLAMA_FALLBACK_REMOVED_FILE} (solo root): $(printf '%s' "$block" | grep -E '^[[:space:]-]*(provider|model):' | tr -s ' ' | tr '\n' ';')"
    else
      # Sin copia no se quita nada: la acción no sería reversible.
      drop_fallback=0
      FALLBACK_NOTE="No se pudo guardar una copia de las entradas del respaldo, así que NO se quitó."
    fi
  fi

  hli_busy "Configurando Hermes con la CLI (unas decenas de comandos; puede tardar varios minutos)..."
  mapfile -t pairs < <(_ollama_config_pairs "$ip" "$full")
  if [[ "$full" -eq 1 ]]; then
    mapfile -t -O "${#pairs[@]}" pairs < <(_ollama_aux_pairs "$ip")
    AUX_MOVED=1
  else
    # Re-ejecución: solo se actualiza la URL de las tareas que ya eran locales.
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      pairs+=("auxiliary.${t}.base_url"$'\t'"http://${ip}:${OLLAMA_PORT}/v1")
    done < <(_ollama_aux_already_local "$content")
  fi
  for k in "${pairs[@]}"; do
    v="${k#*$'\t'}"; k="${k%%$'\t'*}"
    [[ -n "$k" ]] || continue
    hli_docker exec -u "${uid}:${gid}" hermes "$HERMES_BIN" config set "$k" "$v" >/dev/null 2>&1 || failed=1
  done

  if [[ "$drop_fallback" -eq 1 ]]; then
    printf 'y\n' | hli_docker exec -i -u "${uid}:${gid}" hermes "$HERMES_BIN" fallback clear >/dev/null 2>&1 || failed=1
  fi

  if [[ "$failed" -eq 1 ]]; then
    INTEGRATION_NOTE="No se pudo escribir toda la configuración de Hermes con su CLI. Revise ${APPDATA_ROOT}/hermes/config.yaml (providers.${OLLAMA_PROVIDER_ID}, platforms.api_server.model_routes, agent.reasoning_overrides y auxiliary.*) y reinicie el contenedor 'hermes'."
    return 0
  fi

  hli_docker restart hermes >/dev/null 2>&1 || true
  lan_ip="$(_hermes_lan_ip)"
  if ! _hermes_private_lan_ip "$lan_ip"; then
    INTEGRATION_NOTE="Hermes quedó configurado y reiniciado, pero no se pudo determinar la IP de la LAN para verificarlo. Compruebe /v1/models a mano."
    return 0
  fi
  if ! _hermes_wait_health "http://${lan_ip}:8642/health"; then
    INTEGRATION_NOTE="Se configuró Hermes y se reinició, pero http://${lan_ip}:8642/health no respondió a tiempo. Revise los logs (sudo docker logs --tail 50 hermes) y config.yaml."
    return 0
  fi

  key="$(secret_get hermes API_SERVER_KEY 2>/dev/null)" || key=""
  body=""
  [[ -z "$key" ]] || body="$(_ollama_http_body "http://${lan_ip}:8642/v1/models" "$key")"
  key=""
  local m missing=""
  for m in "${OLLAMA_MODELS[@]}"; do
    [[ "$body" == *"$(_ollama_alias "$m")"* ]] || missing+="$(_ollama_alias "$m") "
  done
  if [[ -n "$missing" ]]; then
    INTEGRATION_NOTE="Hermes responde, pero /v1/models NO lista: ${missing}. Los modelos pueden aparecer igual en el selector de la app (que usa /api/model/options); si no, revise 'platforms.api_server.model_routes' en config.yaml."
  fi

  local code
  code="$(_ollama_probe_from_hermes "$ip" "$uid" "$gid")"
  if [[ "$code" != "200" ]]; then
    INTEGRATION_NOTE+="${INTEGRATION_NOTE:+ }Desde el contenedor de Hermes NO se alcanzó http://${ip}:${OLLAMA_PORT}/api/tags (respuesta: '${code:-ninguna}'). Revise la excepción de firewall: sudo cat ${HERMES_EGRESS_ALLOW_FILE} y sudo iptables -S HLI2-HERMES-FWD."
  fi
  if [[ "$drop_fallback" -eq 0 ]] && _ollama_config_has_fallback; then
    FALLBACK_NOTE="${FALLBACK_NOTE:+$FALLBACK_NOTE }AVISO: el respaldo automático hacia OpenRouter sigue activo: si un chat local FALLA (Ollama caído, tiempo agotado, respuesta vacía), la conversación puede reenviarse a OpenRouter y filtrarse."
  fi
  return 0
}

# Texto de privacidad del mensaje final: qué queda local y las excepciones
# explícitas. Sin Hermes no hay nada que declarar de sus tareas.
_ollama_privacy_text() {
  local moved="$1" fb="$2" t="" tasks="${HERMES_AUX_TASKS[*]}"
  t="Privacidad (alcance real, no es total):\n- Local, sin salir de la casa: los chats que usted elija con ${OLLAMA_MODELS[0]} y, en todos los chats, las ${#HERMES_AUX_TASKS[@]} tareas auxiliares de Hermes (${tasks}) con ${OLLAMA_AUX_MODEL}.\n- Excepciones: (1) los chats con el modelo por defecto van a OpenRouter, por diseño. (2) Las herramientas web (buscar, abrir páginas) envían consultas y piden páginas a Internet por naturaleza, también desde un chat local. (3) Si Ollama falla por conexión caída o error de pago/cuota, Hermes cae por diseño al modelo principal de OpenRouter también en las tareas auxiliares; no hay una opción documentada para impedirlo. (4) Respaldo automático: ${fb:-no hay respaldo configurado}."
  if [[ "$moved" -eq 1 ]]; then
    t+="\n- Visión: gemma4:e2b admite imágenes según ollama.com/library/gemma4 ('Text, Image input'), pero con menor calidad que un modelo grande; no se verificó que Hermes la detecte con un endpoint propio. Si el análisis de imágenes falla, revierta 'vision' a su valor previo. voice_chat y tts_audio_tags son tareas de texto y también pasaron al modelo local."
  fi
  printf '%s' "$t"
}

# --- Principal -----------------------------------------------------------------------

_ollama_main() {
  _ollama_detect || return 1

  local dns_arg=""
  if [[ "$O_MODE" == "hermes" ]]; then
    # Excepción de firewall ANTES de crear el contenedor, y script al día (el
    # instalado por una versión anterior de 'hermes' no lee la lista).
    _hermes_allow_add "${O_IP}:${OLLAMA_PORT}/tcp" "$O_SUBNET" \
      || { msg "No se pudo guardar la excepción de firewall en ${HERMES_EGRESS_ALLOW_FILE}. Se cancela el despliegue de Ollama."; return 1; }
    _hermes_install_egress "$O_SUBNET" "${O_DNS//,/ }" || return 1
    dns_arg="$O_DNS"
  fi

  dokploy_preflight || return 1
  _ollama_prepare_dirs || { msg "No se pudo preparar ${APPDATA_ROOT}/ollama."; return 1; }

  local project_json environment_id compose_file composeId
  project_json="$(dokploy_project_find_or_create)" || { msg "No se pudo crear/encontrar el proyecto 'homelab' en Dokploy."; return 1; }
  environment_id="$(dokploy_environment_default_id "$project_json")" || { msg "No se pudo resolver el ambiente por defecto del proyecto 'homelab' en Dokploy."; return 1; }

  compose_file="$(mktemp)"
  if [[ "$O_MODE" == "hermes" ]]; then
    compose_render_ollama hermes "$O_NET" "$O_IP" "$dns_arg" > "$compose_file" || { rm -f "$compose_file"; msg "No se pudo renderizar el compose de Ollama."; return 1; }
  else
    compose_render_ollama standalone > "$compose_file" || { rm -f "$compose_file"; msg "No se pudo renderizar el compose de Ollama."; return 1; }
  fi

  if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "ollama" "$compose_file" "")"; then
    rm -f "$compose_file"
    msg "Falló el despliegue de Ollama vía la API de Dokploy. Revise las credenciales y el panel."
    return 1
  fi
  rm -f "$compose_file"

  if ! service_wait_active ollama 300; then
    msg "El contenedor 'ollama' no llegó a 'activo' dentro de los 300 segundos de espera (la primera vez descarga la imagen). Revise el panel de Dokploy y los logs (sudo docker logs ollama)."
    return 1
  fi
  _ollama_check_networks "$([[ "$O_MODE" == "hermes" ]] && echo hermes-net || echo ollama-net)"

  if ! _ollama_wait_ready; then
    msg "El contenedor 'ollama' está corriendo pero el servidor no respondió a tiempo. Revise los logs (sudo docker logs --tail 50 ollama)."
    return 1
  fi
  _ollama_pull_models || return 1

  INTEGRATION_NOTE="" AUX_PREV_NOTE="" FALLBACK_NOTE="" AUX_MOVED=0
  local where
  if [[ "$O_MODE" == "hermes" ]]; then
    _ollama_integrate_hermes "$O_IP"
    where="Conectado a Hermes (proveedor '${OLLAMA_PROVIDER_ID}', http://${O_IP}:${OLLAMA_PORT}/v1)."
  else
    where="Ollama quedó en su propia red, sin integración: Hermes no está instalado (o no se encontró su red). Cuando instale Hermes, vuelva a correr este módulo para conectarlos."
  fi

  mark_done ollama

  local aliases="" m privacy=""
  for m in "${OLLAMA_MODELS[@]}"; do aliases+="$(_ollama_alias "$m") "; done
  if [[ "$O_MODE" == "hermes" ]]; then
    privacy="$(_ollama_privacy_text "$AUX_MOVED" "$FALLBACK_NOTE")"
  else
    privacy="Privacidad: Ollama no tiene puertos en el host y no está conectado a nada; sin Hermes no hay chats que proteger."
  fi
  msg "Ollama desplegado (composeId=${composeId}) con los modelos ${OLLAMA_MODELS[*]}.\n\n${where}${INTEGRATION_NOTE:+\n\nATENCIÓN: ${INTEGRATION_NOTE}}\n\nCómo usarlo: en hermes-android elija el modelo por conversación (selector de modelo del chat): gemma4:e4b es el cerebro local; los alias ${aliases% } aparecen en /v1/models. El modelo por defecto de Hermes sigue siendo el de OpenRouter.\n\nLatencia esperada (CPU, medida en este equipo): lectura de ~54 tokens/s y escritura de 12-16 tokens/s con gemma4:e4b. El primer mensaje de cada conversación puede tardar varios minutos (Hermes envía instrucciones y herramientas, decenas de miles de tokens, que hay que leer); los siguientes son más rápidos porque Ollama reutiliza el contexto ya leído. El 'pensamiento' del modelo está desactivado para ahorrar tiempo.\n\n${privacy}${AUX_PREV_NOTE:+\n\n${AUX_PREV_NOTE}}\n\nMedición: sudo docker exec ollama ollama ps (modelo cargado, memoria y CONTEXT). Límites: 8 CPU y 20 GB de RAM."
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _ollama_main
fi
