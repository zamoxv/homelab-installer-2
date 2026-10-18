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

# Nombre real de la red de Hermes (…hermes-net); vacío y return 1 si no hay
# exactamente una.
_ollama_hermes_network() {
  local names n found="" count=0
  names="$(hli_docker network ls --format '{{.Name}}' 2>/dev/null)" || return 1
  while IFS= read -r n; do
    [[ "$n" == *hermes-net ]] || continue
    found="$n"; count=$(( count + 1 ))
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
  net="$(_ollama_hermes_network)" || net=""
  if [[ -z "$subnet" || -z "$dns" || -z "$net" ]]; then
    msg "Hermes figura como instalado, pero no se encontró su red de Docker o su script de aislamiento (/usr/local/sbin/hli2-hermes-egress). Ollama se despliega por separado, en su propia red, y NO se integra con Hermes. Vuelva a correr el módulo 'hermes' y luego este."
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

# Pares "clave valor" para 'hermes config set'. Con el proveedor ya presente en
# config.yaml solo se actualizan las URL (la IP pudo cambiar): no se pisan los
# tiempos de espera ni nada que el usuario haya editado.
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

# ¿config.yaml ya tiene la sección providers.ollama-local?
_ollama_config_has_provider() {
  local content
  content="$(sudo -n cat -- "$(_hermes_config_path)" 2>/dev/null)" || return 1
  grep -Eq "^  ${OLLAMA_PROVIDER_ID}:" <<<"$content"
}

# ¿Hay entradas en fallback_providers? (lista no vacía: 'fallback_providers:' a
# secas; vacía se guarda como 'fallback_providers: []').
_ollama_config_has_fallback() {
  local content
  content="$(sudo -n cat -- "$(_hermes_config_path)" 2>/dev/null)" || return 1
  grep -Eq '^fallback_providers:[[:space:]]*$' <<<"$content"
}

# Prueba desde DENTRO del contenedor de Hermes que alcanza a Ollama (el firewall
# deja pasar solo esa IP y puerto). Imprime el código HTTP.
_ollama_probe_from_hermes() {
  local ip="$1" uid="$2" gid="$3"
  hli_docker exec -u "${uid}:${gid}" hermes "$HERMES_PY" -c \
    "import urllib.request as u; print(u.urlopen('http://${ip}:${OLLAMA_PORT}/api/tags', timeout=8).status)" 2>/dev/null || true
}

# Agrega el proveedor a config.yaml SIN reescribir el archivo: 'hermes config
# set' dentro del contenedor, con el uid/gid del agente. Retorna 0 aunque algo
# falle (el módulo informa y el usuario puede completar a mano).
_ollama_integrate_hermes() {
  local ip="$1" uid gid lan_ip key full=1 failed=0 k v body drop_fallback=0
  uid="$(id -u "$SERVER_USER")" gid="$(id -g "$SERVER_USER")"
  INTEGRATION_NOTE=""

  if ! _hermes_config_valid; then
    INTEGRATION_NOTE="No se integró con Hermes: no hay un config.yaml utilizable en ${APPDATA_ROOT}/hermes. Vuelva a correr el módulo 'hermes' y luego este."
    return 0
  fi
  if _ollama_config_has_provider; then full=0; fi

  # Privacidad: el respaldo automático es global y mandaría a OpenRouter un
  # chat local que falle (ver el encabezado de este archivo).
  if _ollama_config_has_fallback; then
    if confirm "Hermes tiene un respaldo automático (fallback_providers) hacia OpenRouter. Es GLOBAL: no se puede excluir a Ollama. Si un chat local falla (tiempo agotado, error del servidor, respuesta vacía), Hermes reintentaría ese mensaje con OpenRouter y la conversación saldría de su casa sin aviso.\n\n¿Quitar el respaldo automático? (Recomendado. Contra: si OpenRouter falla, el chat con el modelo por defecto da error en vez de probar otro. Se restituye con 'hermes fallback add'.)"; then
      drop_fallback=1
    fi
  fi

  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] || continue
    hli_docker exec -u "${uid}:${gid}" hermes "$HERMES_BIN" config set "$k" "$v" >/dev/null 2>&1 || failed=1
  done < <(_ollama_config_pairs "$ip" "$full")

  if [[ "$drop_fallback" -eq 1 ]]; then
    printf 'y\n' | hli_docker exec -i -u "${uid}:${gid}" hermes "$HERMES_BIN" fallback clear >/dev/null 2>&1 || failed=1
  fi

  if [[ "$failed" -eq 1 ]]; then
    INTEGRATION_NOTE="No se pudo escribir toda la configuración de Hermes con su CLI. Revise ${APPDATA_ROOT}/hermes/config.yaml (providers.${OLLAMA_PROVIDER_ID}, platforms.api_server.model_routes y agent.reasoning_overrides) y reinicie el contenedor 'hermes'."
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
  if [[ "$drop_fallback" -eq 1 ]]; then
    INTEGRATION_NOTE+="${INTEGRATION_NOTE:+ }Se quitó el respaldo automático de Hermes."
  elif _ollama_config_has_fallback; then
    INTEGRATION_NOTE+="${INTEGRATION_NOTE:+ }AVISO: el respaldo automático hacia OpenRouter sigue activo: un chat local que falle podría reintentarse con OpenRouter."
  fi
  return 0
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

  INTEGRATION_NOTE=""
  local where
  if [[ "$O_MODE" == "hermes" ]]; then
    _ollama_integrate_hermes "$O_IP"
    where="Conectado a Hermes (proveedor '${OLLAMA_PROVIDER_ID}', http://${O_IP}:${OLLAMA_PORT}/v1)."
  else
    where="Ollama quedó en su propia red, sin integración: Hermes no está instalado (o no se encontró su red). Cuando instale Hermes, vuelva a correr este módulo para conectarlos."
  fi

  mark_done ollama

  local aliases="" m
  for m in "${OLLAMA_MODELS[@]}"; do aliases+="$(_ollama_alias "$m") "; done
  msg "Ollama desplegado (composeId=${composeId}) con los modelos ${OLLAMA_MODELS[*]}.\n\n${where}${INTEGRATION_NOTE:+\n\nATENCIÓN: ${INTEGRATION_NOTE}}\n\nCómo usarlo: en hermes-android elija el modelo por conversación (selector de modelo del chat): gemma4:e4b es el cerebro local; los alias ${aliases% } aparecen en /v1/models. El modelo por defecto de Hermes sigue siendo el de OpenRouter.\n\nLatencia esperada (CPU, medida en este equipo): lectura de ~54 tokens/s y escritura de 12-16 tokens/s con gemma4:e4b. El primer mensaje de cada conversación puede tardar varios minutos (Hermes envía instrucciones y herramientas, decenas de miles de tokens, que hay que leer); los siguientes son más rápidos porque Ollama reutiliza el contexto ya leído. El 'pensamiento' del modelo está desactivado para ahorrar tiempo.\n\nPrivacidad: Ollama no tiene puertos en el host y solo Hermes lo alcanza (una única excepción de firewall). Los chats locales no salen de la casa mientras no haya respaldo automático hacia OpenRouter; el módulo ofrece quitarlo porque es global.\n\nMedición: sudo docker exec ollama ollama ps (modelo cargado, memoria y CONTEXT). Límites: 8 CPU y 20 GB de RAM."
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _ollama_main
fi
