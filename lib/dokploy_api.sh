#!/usr/bin/env bash
# Cliente mínimo de la API HTTP de Dokploy (curl + jq). Única puerta de
# entrada para crear/actualizar/desplegar compose vía Dokploy: ningún módulo
# arma URLs ni parsea JSON de Dokploy por su cuenta.
#
# Fuente/verificación (2026-09-29, docs.dokploy.com):
#   - Auth: header "x-api-key: <token>" (token generado en el panel,
#     /settings/profile -> API/CLI). https://docs.dokploy.com/docs/api
#   - Base: http://<ip>:<puerto>/api
#   - compose.create / compose.update / compose.deploy / compose.one:
#     https://docs.dokploy.com/docs/api/reference-compose
#     compose.create   POST  { name, environmentId, composeType?, appName?,
#                               composeFile?, sourceType? }
#     compose.update   POST  { composeId, composeFile?, sourceType?,
#                               composeType?, appName?, environmentId?, ... }
#     compose.deploy   POST  { composeId, title?, description?, freshVolumes? }
#     compose.one      GET   ?composeId=...
#     compose.delete   POST  { composeId, deleteVolumes }
#   - project.all / project.create / project.one:
#     https://docs.dokploy.com/docs/api/reference-project
#     project.all      GET   (sin parámetros)
#     project.create   POST  { name, description?, env? }
#     project.one      GET   ?projectId=...
#   - environment.byProjectId / environment.one:
#     https://docs.dokploy.com/docs/api/environment
#     environment.byProjectId  GET  ?projectId=...
#     environment.one          GET  ?environmentId=...
#   - domain.create / domain.byComposeId (v2.3, Vaultwarden/OpenCloud vía
#     Traefik): https://docs.dokploy.com/docs/api/reference-domain
#     domain.create      POST  { host, composeId?, applicationId?,
#                                 serviceName?, port?, https?, certificateType? }
#     domain.byComposeId GET   ?composeId=...
#
# INCERTIDUMBRE documentada (la doc pública no renderiza el JSON de
# respuesta completo, solo status codes): no está confirmado si
# project.create devuelve el "environmentId" del ambiente por defecto
# embebido en la respuesta, ni si environment.one/compose.one exponen la
# lista de composes existentes de un ambiente de forma directa. Este cliente
# resuelve el environmentId con environment.byProjectId (documentado) y, para
# encontrar un compose existente por nombre, usa compose.one contra un
# composeId candidato guardado en el ESTADO LOCAL de HLI 2 (ver
# dokploy_compose_state_get/set más abajo) en vez de listar composes del lado
# de Dokploy — así la idempotencia no depende de un endpoint de listado no
# verificado. VALIDAR contra un servidor real antes de confiar a ciegas.
set -euo pipefail

# 'HLI2_DOKPLOY_ENV_FILE'/'HLI2_DOKPLOY_STATE_FILE' (no los nombres pelados):
# ver el comentario sobre namespacing en lib/core.sh (LOG_DIR/STATE_DIR) —
# mismo motivo acá, para que un test los apunte a un archivo/dir de scratch
# sin arriesgar que un "DOKPLOY_ENV_FILE" ambiental cualquiera secuestre en
# silencio dónde vive el token real en producción.
DOKPLOY_ENV_FILE="${HLI2_DOKPLOY_ENV_FILE:-/etc/hli2/dokploy.env}"
DOKPLOY_STATE_FILE="${HLI2_DOKPLOY_STATE_FILE:-$STATE_DIR/dokploy-compose-ids}"

# --- Configuración (token/URL) ---------------------------------------------

# ¿Hay credenciales guardadas? No valida que funcionen (eso lo hace el
# primer llamado real); solo confirma que el archivo existe y tiene los dos
# campos. Vía priv_file_exists (lib/secrets.sh): $DOKPLOY_ENV_FILE vive en
# /etc/hli2, 0700 root:root — un '[[ -f ]]' sin privilegios daría "no existe"
# SIEMPRE (el usuario sin privilegios que corre bootstrap.sh ni siquiera
# puede atravesar ese directorio), no solo cuando de verdad no hay
# credenciales. Mismo hallazgo/corrección que secret_file_exists.
dokploy_api_configured() {
  priv_file_exists "$DOKPLOY_ENV_FILE" || return 1
  local url token
  url="$(_dokploy_env_get DOKPLOY_URL)"
  token="$(_dokploy_env_get DOKPLOY_TOKEN)"
  [[ -n "$url" && -n "$token" ]]
}

# Valor de una clave del env file, sin sourcearlo (evita ejecutar contenido
# arbitrario si el archivo estuviera corrupto/manipulado). Lectura vía
# priv_file_read (lib/secrets.sh: sudo -n cat, mismo motivo que arriba) y
# comparación EXACTA de la clave con 'case' (no una regex de 'sed' armada
# con la clave) — valor = todo lo que sigue al PRIMER '=' de la línea.
_dokploy_env_get() {
  local key="$1" content line
  content="$(priv_file_read "$DOKPLOY_ENV_FILE")" || return 1
  while IFS= read -r line; do
    case "$line" in
      "${key}="*)
        printf '%s' "${line#"${key}="}"
        return 0
        ;;
    esac
  done <<<"$content"
  return 1
}

_dokploy_api_base() {
  local url
  url="$(_dokploy_env_get DOKPLOY_URL)" || return 1
  [[ -n "$url" ]] || return 1
  echo "${url%/}/api"
}

# Formato permitido del token: solo caracteres propios de un token de API.
# Excluye comillas, barra invertida, espacios y saltos de línea, que podrían
# inyectar directivas en la configuración de curl leída por STDIN (-K -) o
# variables extra en $DOKPLOY_ENV_FILE.
_dokploy_token_valid() {
  [[ "$1" =~ ^[A-Za-z0-9._~+/=-]+$ ]]
}

_dokploy_api_token() {
  local t
  t="$(_dokploy_env_get DOKPLOY_TOKEN)" || return 1
  [[ -n "$t" ]] || return 1
  _dokploy_token_valid "$t" || return 1
  echo "$t"
}

# Pide IP/puerto/token por TUI y los guarda en $DOKPLOY_ENV_FILE, root-only
# (0600), sin loguear nunca el token. Sobrescribe credenciales previas.
#
# El archivo se CREA ya con el modo final (0600, root:root) ANTES de
# escribirle nada, con 'install -m ... /dev/null' — nunca "mkdir + tee +
# chown/chmod después": ese orden deja una VENTANA en la que el archivo
# recién creado por 'tee' existe con el modo por defecto del proceso (según
# umask, típicamente 0644: legible por cualquier usuario) hasta que el
# chmod posterior corre. 'tee' sobre un archivo YA existente solo trunca y
# escribe: no reabre con un modo nuevo, así que el 0600 de la creación se
# mantiene durante toda la escritura, sin ventana insegura. El directorio
# también se crea con su modo final de una sola vez ('install -d').
dokploy_api_setup() {
  local ip port url token dp_port

  dp_port="$(service_get dokploy PORT)" || dp_port="3000"
  ip=$(input_box "Dokploy — API" "IP del panel de Dokploy:" "$(get_ip || true)") || return 1
  [[ -n "$ip" ]] || { msg "IP vacía: se cancela la configuración de la API de Dokploy."; return 1; }
  port=$(input_box "Dokploy — API" "Puerto del panel de Dokploy:" "${dp_port:-3000}") || return 1
  [[ -n "$port" ]] || port="$dp_port"

  msg "Ahora se pide el token de la API de Dokploy.\n\nGenerelo en el panel: Configuración -> Perfil (/settings/profile) -> sección API/CLI.\n\nEl token se guarda solo en este servidor (root, permisos 600) y nunca se muestra ni se registra en los logs."
  token=$(password_box "Dokploy — API" "Token de la API (x-api-key):") || return 1
  [[ -n "$token" ]] || { msg "Token vacío: se cancela la configuración de la API de Dokploy."; return 1; }
  _dokploy_token_valid "$token" || { msg "El token contiene caracteres no válidos (se admiten letras, números y ._~+/=-).\n\nCopie el token nuevamente desde el panel de Dokploy."; return 1; }

  url="http://${ip}:${port}"

  sudo install -d -m 0700 -o root -g root "$(dirname "$DOKPLOY_ENV_FILE")"
  sudo install -m 0600 -o root -g root /dev/null "$DOKPLOY_ENV_FILE"
  {
    echo "DOKPLOY_URL=${url}"
    echo "DOKPLOY_TOKEN=${token}"
  } | sudo tee "$DOKPLOY_ENV_FILE" >/dev/null

  # Nunca se imprime $token, ni siquiera en el log (log() escribe a un
  # archivo que puede leer cualquiera con acceso a $LOG_DIR).
  log "Credenciales de la API de Dokploy guardadas en $DOKPLOY_ENV_FILE (URL=$url)"
  return 0
}

# --- Llamada HTTP genérica --------------------------------------------------

_dokploy_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    _dokploy_err "falta 'jq' (necesario para hablar con la API de Dokploy). Instalelo (el módulo 'base' lo instala) e intente de nuevo."
    return 1
  }
}

# Llama a la API: dokploy_api_call <METODO> <ruta-sin-slash-inicial> [json-body]
# Imprime el cuerpo de la respuesta por stdout. Falla (return 1) y escribe un
# mensaje por stderr si: no hay credenciales, falla la red, el status HTTP no
# es 2xx, o el cuerpo 2xx no es JSON válido (ver validación al final). NUNCA
# imprime el token, ni en éxito ni en error.
#
# El token NUNCA viaja como argumento de línea de comandos de 'curl': un
# proceso hijo expone su argv completo a cualquier usuario local vía
# 'ps'/'/proc/<pid>/cmdline', así que un "-H x-api-key: <token>" ahí sería
# legible por cualquiera en la máquina mientras la llamada está en vuelo. En
# cambio, el header con el token se pasa por STDIN a curl como un archivo de
# configuración ('-K -': "lee opciones de config desde stdin", sintaxis
# soportada desde curl 7.10, muy anterior a cualquier versión relevante acá)
# — eso no aparece en el argv del proceso. El MÉTODO y la URL no son
# secretos y siguen yendo por argv normal.
#
# El BODY (desde v2.3 puede traer secretos embebidos: el campo "env" de
# compose.create/update con ADMIN_TOKEN/INITIAL_ADMIN_PASSWORD, ver
# dokploy_compose_create_or_update) tampoco va nunca por argv: se escribe a
# un archivo temporal (creado por 'mktemp', 0600 por defecto — solo lo lee
# el propio usuario) y se pasa a curl como '--data @<archivo>'. El argv de
# curl solo contiene la RUTA del archivo, nunca su contenido. El archivo se
# borra explícitamente en CADA punto de salida de la función (éxito o
# error) — NUNCA con 'trap ... RETURN': se probó a mano (bash 5) que ese
# trap NO es local a la función donde se define, sino un único trap GLOBAL
# del shell que una llamada anidada (cualquier otra función que también
# arme un 'trap ... RETURN', ej. dokploy_compose_create_or_update) pisa sin
# avisar — con eso, el 'rm' de acá terminaría corriendo en el momento
# equivocado (o nunca) según qué se haya llamado en el medio. Mismo motivo
# ya documentado en modules/jellyfin.sh sobre por qué IMPORT_WORK_DIR usa un
# trap EXIT a nivel de módulo en vez de un 'trap ... RETURN' por función.
# Error del cliente de la API: siempre a stderr (lo ve el usuario) y además
# al log de instalación, porque en los módulos interactivos la siguiente
# ventana de dialog tapa el mensaje. $1 va al log; $2 (opcional, p. ej. el
# cuerpo de la respuesta) SOLO a stderr: puede contener secretos (el campo
# "env" de un compose) y el log no es root-only.
_dokploy_err() {
  local message="$1"
  local detail="${2:-}"
  echo "ERROR: ${message}${detail:+ $detail}" >&2
  log "ERROR API Dokploy: ${message}" 2>/dev/null || true
}

dokploy_api_call() {
  local method="$1" path="$2" body="${3:-}"
  local base token url resp http_code out curl_args=() body_file=""

  _dokploy_require_jq || return 1
  base="$(_dokploy_api_base)" || { _dokploy_err "la API de Dokploy no está configurada (falta $DOKPLOY_ENV_FILE). Corra la configuración primero."; return 1; }
  token="$(_dokploy_api_token)" || { _dokploy_err "falta el token de la API de Dokploy en $DOKPLOY_ENV_FILE, o tiene un formato no válido. Vuelva a configurar la API."; return 1; }
  url="${base}/${path}"

  curl_args=(-sS --connect-timeout 10 --max-time 60 -w $'\n%{http_code}' -K - -X "$method")
  if [[ -n "$body" ]]; then
    body_file="$(mktemp)"
    printf '%s' "$body" > "$body_file"
    curl_args+=(-H "Content-Type: application/json" --data "@${body_file}")
  fi

  if ! resp="$(curl "${curl_args[@]}" "$url" <<<"header = \"x-api-key: ${token}\"" 2>/dev/null)"; then
    rm -f "$body_file"
    _dokploy_err "fallo de red llamando a Dokploy ($method $path)."
    return 1
  fi
  rm -f "$body_file"

  http_code="${resp##*$'\n'}"
  out="${resp%$'\n'*}"

  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    _dokploy_err "Dokploy rechazó el token de la API (HTTP $http_code): puede haber sido revocado o regenerado. Configúrelo de nuevo en Herramientas -> 'Configurar API de Dokploy'."
    return 1
  fi
  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    _dokploy_err "Dokploy respondió HTTP ${http_code:-desconocido} en $method $path." "Respuesta: ${out:0:500}"
    return 1
  fi

  # Todo 2xx con cuerpo no vacío debería ser JSON (toda la API de Dokploy lo
  # es). Un cuerpo no vacío que NO parsea como JSON (HTML de un proxy/error,
  # texto plano, respuesta cortada) se rechaza acá, en el único lugar común a
  # TODAS las llamadas, en vez de dejar que cada 'jq -r' que sigue falle más
  # abajo con un mensaje confuso o (peor) extraiga 'null'/vacío en silencio.
  # Un cuerpo vacío (204 sin contenido) es válido y no se valida como JSON.
  if [[ -n "$out" ]] && ! jq -e . >/dev/null 2>&1 <<<"$out"; then
    _dokploy_err "Dokploy devolvió un cuerpo que no es JSON válido en $method $path." "Respuesta: ${out:0:300}"
    return 1
  fi

  printf '%s' "$out"
}

dokploy_api_get() { dokploy_api_call GET "$1"; }
dokploy_api_post() { dokploy_api_call POST "$1" "$2"; }

# --- Configurar + verificar (única implementación) --------------------------
#
# Flujo completo de "pedir credenciales de la API de Dokploy y no darlas por
# buenas hasta confirmar que funcionan": muestra las instrucciones paso a
# paso (crear la cuenta de administrador PRIMERO — el primer visitante del
# panel se queda con ella —, después generar el token), pide IP/puerto/token
# (dokploy_api_setup) y verifica con 'project.all'. Si la verificación
# falla, explica el motivo y ofrece reintentar (sin perder la configuración
# anterior hasta confirmar una nueva) o cancelar.
#
# ÚNICA implementación: la usan tanto modules/dokploy-api.sh (herramienta
# "Configurar/cambiar token" del menú) como modules/dokploy.sh (al terminar
# una instalación nueva, y cuando Dokploy ya está instalado pero la API
# todavía no está configurada) — antes esta lógica (backup, pedir, verificar,
# restaurar) vivía duplicada a mano dentro de modules/dokploy-api.sh.
#
# Backup/restauración: si ya había credenciales guardadas, se respaldan
# ANTES del primer intento (una sola vez, no en cada reintento) y se
# restauran si el usuario termina cancelando (ya sea en el propio
# dokploy_api_setup, o después de un fallo de verificación). Si no había
# credenciales previas y se termina cancelando, no queda ningún archivo de
# credenciales (nunca se deja a medio escribir).
#
# Devuelve 0 solo si quedaron guardadas credenciales que Dokploy aceptó
# (verificadas con 'project.all'). Devuelve 1 en cualquier otro caso
# (usuario canceló el ingreso de datos, o rechazó reintentar tras un fallo
# de verificación) — en ese caso puede haber quedado la configuración
# ANTERIOR restaurada (si había) o ninguna (si no había). El llamador decide
# si eso es motivo de abortar su propio flujo o no (ver modules/dokploy.sh:
# un fallo acá nunca aborta una instalación de Dokploy que ya terminó bien).
# Restaura (o limpia) $DOKPLOY_ENV_FILE a partir de $_DOKPLOY_CFGV_BACKUP,
# fijada por dokploy_api_configure_verified antes de registrar el trap EXIT
# de abajo. Nombre con prefijo propio (no una variable 'local' común) a
# propósito: un trap EXIT corre en el entorno del shell en el momento de
# salir, no necesariamente todavía "dentro" del scope léxico de la función
# que lo armó, así que no hay que depender de que 'local backup' siga
# resuelta por scoping dinámico — se usa una variable de módulo explícita.
_dokploy_cfgv_restore_on_abort() {
  if [[ -n "${_DOKPLOY_CFGV_BACKUP:-}" ]]; then
    sudo cp "$_DOKPLOY_CFGV_BACKUP" "$DOKPLOY_ENV_FILE" 2>/dev/null || true
    sudo rm -f "$_DOKPLOY_CFGV_BACKUP" 2>/dev/null || true
  fi
}

dokploy_api_configure_verified() {
  # Fail-closed (hallazgo de revisión): un 'sudo -n' que no funciona (sesión
  # cacheada por bootstrap.sh vencida o nunca iniciada) hace que
  # priv_file_exists() devuelva 1 por EL MISMO camino que "el archivo
  # genuinamente no existe" (ver el comentario de priv_file_exists en
  # lib/secrets.sh: no hay forma de distinguir los dos casos por código de
  # retorno). Si eso pasara acá y se lo tratara como "no hay nada que
  # respaldar", dokploy_api_setup pisaría unas credenciales FUNCIONANDO sin
  # haberlas respaldado, y un fallo de verificación posterior borraría el
  # archivo entero (cero credenciales, ni las viejas ni las nuevas) en vez
  # de restaurarlas — pérdida irrecuperable. Por eso se exige 'sudo -n true'
  # ACÁ, antes de preguntar nada ni tocar el archivo, y se aborta con un
  # mensaje claro si no funciona: nunca seguir adelante sin poder confirmar
  # primero si hay algo que proteger.
  if ! sudo -n true 2>/dev/null; then
    msg "No se pudo verificar sudo para configurar la API de Dokploy (la sesión cacheada por bootstrap.sh no está disponible o venció).\n\nPor seguridad, no se continúa: sin esto no se puede confirmar si hay credenciales existentes para respaldarlas antes de pedir unas nuevas.\n\nReintente (puede hacer falta volver a autenticar sudo)."
    return 1
  fi

  local dp_port default_ip
  dp_port="$(service_get dokploy PORT 2>/dev/null)" || dp_port="3000"
  default_ip="$(get_ip 2>/dev/null || true)"

  msg "Antes de configurar la API de Dokploy:\n\n1. Abra http://${default_ip:-<ip-del-servidor>}:${dp_port} en un navegador.\n\n2. Si todavía no lo hizo, CREE LA CUENTA DE ADMINISTRADOR ahora: el primer visitante que entra al panel se convierte en administrador, así que cualquiera que llegue antes se queda con esa cuenta.\n\n3. Ya dentro del panel: Configuración -> Perfil (/settings/profile) -> sección API/CLI -> genere un token.\n\nA continuación se piden la IP, el puerto y ese token."

  local backup=""
  if priv_file_exists "$DOKPLOY_ENV_FILE" 2>/dev/null; then
    backup="${DOKPLOY_ENV_FILE}.anterior"
    sudo install -m 0600 -o root -g root /dev/null "$backup"
    sudo cp "$DOKPLOY_ENV_FILE" "$backup"
  fi

  # Red de seguridad ante una interrupción (Ctrl+C, señal, caída de dialog)
  # ENTRE que se hizo el backup y que se confirma éxito/fracaso: sin esto,
  # una salida abrupta a mitad de dokploy_api_setup (que ya pudo haber
  # sobrescrito $DOKPLOY_ENV_FILE con datos a medio ingresar) dejaría el
  # archivo en un estado inconsistente y el '.anterior' huérfano. Es un
  # trap EXIT (dispara una sola vez, al terminar ESTE proceso bash, sea
  # cual sea el motivo) — nunca 'trap ... RETURN' (ese SÍ es global al
  # shell completo y un problema real ya documentado en dokploy_api_call /
  # dokploy_compose_create_or_update). Un trap EXIT acá es seguro porque
  # esta función siempre corre como el punto de entrada casi-de-nivel-
  # superior de un script bash PROPIO (modules/dokploy-api.sh completo, o
  # modules/dokploy.sh vía run_module: cada módulo es un proceso bash
  # nuevo) — nada más en ese mismo proceso arma otro trap EXIT que lo
  # pudiera pisar. Se limpia (trap - EXIT) en cada punto de retorno normal
  # de más abajo: a partir de ahí el resultado (éxito, restauración,
  # cancelación) ya quedó aplicado a mano, y dejar el trap armado
  # repetiría esa acción (con datos potencialmente obsoletos) cuando el
  # proceso termine más tarde por una razón totalmente ajena.
  _DOKPLOY_CFGV_BACKUP="$backup"
  trap _dokploy_cfgv_restore_on_abort EXIT

  while true; do
    if ! dokploy_api_setup; then
      trap - EXIT
      if [[ -n "$backup" ]]; then
        sudo cp "$backup" "$DOKPLOY_ENV_FILE"
        sudo rm -f "$backup"
        msg "No se cambió la configuración de la API de Dokploy. Se conservó la anterior."
      else
        msg "No se configuró la API de Dokploy."
      fi
      _DOKPLOY_CFGV_BACKUP=""
      return 1
    fi

    hli_busy "Verificando la conexión con Dokploy..."
    if dokploy_api_get "project.all" >/dev/null 2>&1; then
      trap - EXIT
      [[ -n "$backup" ]] && sudo rm -f "$backup"
      _DOKPLOY_CFGV_BACKUP=""
      log "API de Dokploy configurada y verificada (project.all respondió)."
      msg "Conexión con Dokploy verificada. Las credenciales quedaron guardadas."
      return 0
    fi

    if confirm "Dokploy no aceptó la dirección o el token ingresados.\n\nRevise la dirección del panel y copie el token de nuevo desde Configuración -> Perfil -> API/CLI.\n\n¿Reintentar?"; then
      continue
    fi

    trap - EXIT
    if [[ -n "$backup" ]]; then
      sudo cp "$backup" "$DOKPLOY_ENV_FILE"
      sudo rm -f "$backup"
      msg "Se canceló la configuración de la API de Dokploy. Se conservó la anterior."
    else
      sudo rm -f "$DOKPLOY_ENV_FILE"
      msg "Se canceló la configuración de la API de Dokploy. No quedaron credenciales guardadas."
    fi
    _DOKPLOY_CFGV_BACKUP=""
    return 1
  done
}

# --- Proyecto ("homelab") ---------------------------------------------------

DOKPLOY_PROJECT_NAME="homelab"

# Imprime el JSON del proyecto "homelab" si existe, vacío + return 1 si no.
dokploy_project_find() {
  local all
  all="$(dokploy_api_get "project.all")" || return 1
  jq -e --arg name "$DOKPLOY_PROJECT_NAME" 'map(select(.name == $name)) | first // empty' <<<"$all"
}

# Encuentra o crea el proyecto "homelab". Idempotente. Imprime el JSON del
# proyecto.
dokploy_project_find_or_create() {
  local existing
  existing="$(dokploy_project_find)" && [[ -n "$existing" ]] && { printf '%s' "$existing"; return 0; }

  local body
  body="$(jq -n --arg name "$DOKPLOY_PROJECT_NAME" --arg desc "Servicios de HLI 2 (homelab)" '{name: $name, description: $desc}')"
  local created
  created="$(dokploy_api_post "project.create" "$body")" || return 1
  # project.create devuelve { project: {...}, environment: {...} } (router
  # project.ts de Dokploy): se devuelve la fila del proyecto, con la misma
  # forma plana que entrega project.all.
  jq -e '.project // .' <<<"$created" || { _dokploy_err "project.create devolvió una respuesta sin proyecto."; return 1; }
}

# environmentId por defecto de un proyecto (primer ambiente que devuelva
# environment.byProjectId). Falla cerrado (return 1, nada por stdout) si el
# proyecto no tiene ningún ambiente: sin environmentId no hay dónde crear el
# compose, y asumir uno inventado rompería silenciosamente en Dokploy.
dokploy_environment_default_id() {
  local project_json="$1" project_id envs id
  project_id="$(jq -r '.projectId // .id // empty' <<<"$project_json" 2>/dev/null)" || project_id=""
  [[ -n "$project_id" ]] || { _dokploy_err "no se pudo leer el projectId del proyecto 'homelab'."; return 1; }

  envs="$(dokploy_api_get "environment.byProjectId?projectId=${project_id}")" || return 1
  id="$(jq -r '(.[0].environmentId // .[0].id) // empty' <<<"$envs" 2>/dev/null)" || id=""
  if [[ -z "$id" ]]; then
    _dokploy_err "el proyecto 'homelab' (projectId=$project_id) no tiene ningún ambiente (environment.byProjectId vino vacío). No se puede crear el compose sin environmentId."
    return 1
  fi
  printf '%s' "$id"
}

# --- Compose -----------------------------------------------------------------

# El estado local (no la API) guarda "<appName> <composeId>" por línea: sirve
# para encontrar un compose ya creado sin depender de un endpoint de listado
# no verificado en la documentación pública. Se revalida igual con
# compose.one antes de usarlo (ver dokploy_compose_id_for): si Dokploy ya no
# lo tiene (se borró a mano en el panel), se trata como "no existe" y se
# vuelve a crear, nunca se asume válido a ciegas.
_dokploy_compose_state_get() {
  local app_name="$1"
  [[ -f "$DOKPLOY_STATE_FILE" ]] || return 1
  awk -v a="$app_name" '$1 == a {print $2; found=1} END{exit !found}' "$DOKPLOY_STATE_FILE"
}

_dokploy_compose_state_set() {
  local app_name="$1" compose_id="$2" tmp
  sudo mkdir -p "$(dirname "$DOKPLOY_STATE_FILE")"
  sudo touch "$DOKPLOY_STATE_FILE"
  tmp="$(mktemp)"
  { awk -v a="$app_name" '$1 != a' "$DOKPLOY_STATE_FILE" 2>/dev/null; echo "$app_name $compose_id"; } > "$tmp"
  sudo cp "$tmp" "$DOKPLOY_STATE_FILE"
  rm -f "$tmp"
}

# composeId existente y válido para $app_name, o vacío (return 1) si no hay
# ninguno registrado o el registrado ya no existe en Dokploy.
dokploy_compose_id_for() {
  local app_name="$1" composeId
  composeId="$(_dokploy_compose_state_get "$app_name")" || return 1
  [[ -n "$composeId" ]] || return 1
  dokploy_api_get "compose.one?composeId=${composeId}" >/dev/null 2>&1 || return 1
  printf '%s' "$composeId"
}

# Crea (o actualiza si ya existe) el compose $app_name en $environment_id con
# el contenido de $compose_file, y lo despliega. Idempotente. Imprime el
# composeId final.
#
# $4 (opcional) = contenido del campo "env" de Dokploy: variables
# "CLAVE=valor" (una por línea) que Dokploy sustituye en el compose vía
# ${CLAVE} al desplegar (mismo mecanismo que un archivo .env junto al
# docker-compose.yml). Es el canal para secretos (ADMIN_TOKEN de
# Vaultwarden, INITIAL_ADMIN_PASSWORD de OpenCloud...): el compose
# versionado solo contiene "${CLAVE}" como referencia, nunca el valor real
# (ver services/vaultwarden.conf y compose/vaultwarden/docker-compose.yml).
# Campo "env" documentado en compose.update (docs.dokploy.com/docs/api/
# reference-compose, 2026-09-29); se asume el mismo campo válido también en
# compose.create (no confirmado explícitamente en la doc pública — INCERTIDUMBRE
# a validar en el servidor real, igual que otros campos de este cliente).
dokploy_compose_create_or_update() {
  local environment_id="$1" app_name="$2" compose_file="$3" env_content="${4:-}"
  local compose_content composeId body resp env_file rc=0

  [[ -f "$compose_file" ]] || { _dokploy_err "no existe el compose renderizado: $compose_file"; return 1; }
  compose_content="$(cat "$compose_file")"

  # 'env_content' puede traer un secreto (ADMIN_TOKEN, INITIAL_ADMIN_PASSWORD...):
  # se lo pasa a 'jq' con '--rawfile' desde un archivo temporal (0600 por
  # 'mktemp'), NUNCA con '--arg' desde la variable — '--arg' pondría el
  # secreto directo en el argv del proceso 'jq' (visible por 'ps'/'/proc'
  # mientras corre), exactamente lo que este proyecto evita para el token de
  # la API de Dokploy (ver el comentario de dokploy_api_call). El archivo se
  # borra EXPLÍCITAMENTE al final (rc + un solo punto de salida), nunca con
  # 'trap ... RETURN': se comprobó a mano que ese trap es GLOBAL al shell
  # (una función anidada que arma su propio 'trap ... RETURN', como
  # dokploy_api_call, lo pisa sin avisar) — ver el comentario de
  # dokploy_api_call para el detalle de la prueba.
  env_file="$(mktemp)"
  printf '%s' "$env_content" > "$env_file"

  composeId="$(dokploy_compose_id_for "$app_name")" || composeId=""

  if [[ -n "$composeId" ]]; then
    body="$(jq -n --arg id "$composeId" --arg cf "$compose_content" --rawfile env "$env_file" \
      '{composeId: $id, composeFile: $cf, sourceType: "raw", composeType: "docker-compose"} + (if $env != "" then {env: $env} else {} end)')"
    dokploy_api_post "compose.update" "$body" >/dev/null || rc=1
  else
    body="$(jq -n --arg name "$app_name" --arg env_id "$environment_id" --arg cf "$compose_content" --rawfile env "$env_file" \
      '{name: $name, appName: $name, environmentId: $env_id, composeType: "docker-compose", sourceType: "raw", composeFile: $cf} + (if $env != "" then {env: $env} else {} end)')"
    if resp="$(dokploy_api_post "compose.create" "$body")"; then
      composeId="$(jq -r '.composeId // .id // empty' <<<"$resp" 2>/dev/null)" || composeId=""
      if [[ -z "$composeId" ]]; then
        _dokploy_err "compose.create no devolvió composeId para '$app_name'." "Respuesta: ${resp:0:300}"
        rc=1
      else
        _dokploy_compose_state_set "$app_name" "$composeId"
        # Si el 'env' no se pudo mandar en compose.create (campo no
        # soportado ahí), reintentarlo con un compose.update inmediato:
        # nunca dejar un compose recién creado sin sus variables de entorno
        # si el llamador pidió alguna.
        if [[ -n "$env_content" ]]; then
          body="$(jq -n --arg id "$composeId" --rawfile env "$env_file" '{composeId: $id, env: $env}')"
          dokploy_api_post "compose.update" "$body" >/dev/null || rc=1
        fi
      fi
    else
      rc=1
    fi
  fi

  rm -f "$env_file"
  [[ "$rc" -eq 0 ]] || return 1
  printf '%s' "$composeId"
}

dokploy_compose_deploy() {
  local composeId="$1" body
  body="$(jq -n --arg id "$composeId" '{composeId: $id}')"
  dokploy_api_post "compose.deploy" "$body" >/dev/null
}

# Crea/actualiza (con 'env' opcional, ver dokploy_compose_create_or_update) +
# despliega en un paso. Imprime el composeId.
dokploy_compose_deploy_full() {
  local environment_id="$1" app_name="$2" compose_file="$3" env_content="${4:-}" composeId
  if [[ "$app_name" == "${CANARY_APP_NAME:-hli2-canary}" ]]; then
    hli_busy "Prueba de persistencia: verificando que Dokploy conserve los datos de /srv/appdata entre despliegues (se despliega 3 veces un contenedor de prueba)..."
  else
    hli_busy "Desplegando ${app_name} en Dokploy..."
  fi
  composeId="$(dokploy_compose_create_or_update "$environment_id" "$app_name" "$compose_file" "$env_content")" || return 1
  dokploy_compose_deploy "$composeId" || return 1
  printf '%s' "$composeId"
}

dokploy_compose_delete() {
  local composeId="$1" delete_volumes="${2:-true}" body
  body="$(jq -n --arg id "$composeId" --argjson dv "$delete_volumes" '{composeId: $id, deleteVolumes: $dv}')"
  dokploy_api_post "compose.delete" "$body" >/dev/null
}

# --- Dominios (Traefik vía Dokploy) -----------------------------------------
#
# Fuente (2026-09-29, docs.dokploy.com/docs/api/reference-domain +
# docs.dokploy.com/docs/core/docker-compose/domains): domain.create admite
# {host, composeId, serviceName, port, https, certificateType}; para un
# compose, el servicio debe estar en la red externa "dokploy-network" (la
# crea Dokploy) para que su Traefik lo alcance — ver el bloque "networks" en
# compose/vaultwarden/docker-compose.yml y compose/opencloud/docker-compose.yml.
# INCERTIDUMBRE: la doc pública no confirma el shape exacto de la respuesta
# de domain.create ni de domain.byComposeId (no se pudo probar contra un
# Dokploy real desde acá) — validar en el servidor real antes de asumir que
# el parseo de abajo es correcto.
#
# Encuentra un dominio ya creado para $1 (composeId) + $2 (serviceName) + $3
# (host). Imprime domainId si existe, vacío + return 1 si no (o si
# domain.byComposeId falla, ej. por no estar soportado en esta versión de
# Dokploy: se trata como "no hay dominio" y se intenta crear, nunca se
# asume éxito sin confirmar).
_dokploy_domain_find() {
  local compose_id="$1" service_name="$2" host="$3" all
  all="$(dokploy_api_get "domain.byComposeId?composeId=${compose_id}")" || return 1
  jq -r --arg svc "$service_name" --arg host "$host" \
    'map(select(.serviceName == $svc and .host == $host)) | first.domainId // first.id // empty' \
    <<<"$all" 2>/dev/null
}

# Crea (si no existe ya) el dominio $3 (host) para el servicio $2 dentro del
# compose $1, apuntando al puerto $4. $5 = "true"/"false" (https), $6 =
# certificateType ("letsencrypt" | "none" | "custom"; default "none": sin
# resolución pública todavía, ver v2.4 en el roadmap). Idempotente por
# (composeId, serviceName, host). Best-effort: si domain.byComposeId no está
# disponible, igual intenta domain.create (Dokploy puede rechazar un
# duplicado por su cuenta; no es motivo para abortar el despliegue del
# servicio en sí).
dokploy_domain_ensure() {
  local compose_id="$1" service_name="$2" host="$3" port="$4" https="${5:-false}" cert_type="${6:-none}"
  local existing body

  existing="$(_dokploy_domain_find "$compose_id" "$service_name" "$host")" || existing=""
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi

  body="$(jq -n --arg host "$host" --arg cid "$compose_id" --arg svc "$service_name" \
    --argjson port "$port" --argjson https "$https" --arg cert "$cert_type" \
    '{host: $host, composeId: $cid, serviceName: $svc, port: $port, https: $https, certificateType: $cert}')"
  dokploy_api_post "domain.create" "$body" >/dev/null
}
