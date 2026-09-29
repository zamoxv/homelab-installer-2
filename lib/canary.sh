#!/usr/bin/env bash
# Validación "canario" (obligatoria, una sola vez) de que Dokploy NO borra
# datos fuera de su propio directorio de código al recrear un compose vía la
# API. Motivo: hay evidencia de que Dokploy solo limpia SU carpeta de código
# del compose, pero no está probado para un bind mount de ruta absoluta
# arbitraria (/srv/appdata/...) como los que usan Jellyfin/qBittorrent/
# AdGuard. Si esto fallara, un simple "update + redeploy" podría borrar el
# appdata real de un servicio. Por eso se prueba con un compose descartable
# ANTES de tocar cualquier servicio real, y el resultado (éxito) queda en el
# estado persistente para no repetir la prueba en cada corrida.
set -euo pipefail

CANARY_APP_NAME="hli2-canary"
CANARY_DIR="$APPDATA_ROOT/_hli2_canary"
CANARY_SENTINEL="$CANARY_DIR/sentinel"
CANARY_STATE_KEY_PREFIX="dokploy-canary"

# Clave de estado del canario para el Dokploy ACTUAL (URL + versión, si se
# puede determinar). No es una constante fija: si se apunta a otra URL de
# Dokploy, o el mismo Dokploy se actualiza de versión, esto da una clave
# distinta y la validación se vuelve a correr — un servidor nuevo o un
# Dokploy actualizado no hereda "ya validado" de otra instalación/versión
# que nunca se probó. Si la versión no se puede determinar, la clave queda
# atada solo a la URL (nunca "sin clave": eso equivaldría a compartir el
# resultado entre CUALQUIER Dokploy, que es justo lo que se quiere evitar).
_canary_target_key() {
  local url version raw hash
  url="$(_dokploy_api_base 2>/dev/null)" || url="url-desconocida"
  version=""
  if [[ "$(hli_docker_presence 2>/dev/null || echo unknown)" == "present" ]]; then
    version="$(hli_docker service inspect dokploy --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null)" || version=""
  fi
  raw="${url}|${version}"
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$raw" | sha256sum | awk '{print $1}')" || true
  else
    hash="$(printf '%s' "$raw" | cksum | awk '{print $1"-"$2}')" || true
  fi
  [[ -n "$hash" ]] || hash="sin-hash-$$"
  printf '%s-%s' "$CANARY_STATE_KEY_PREFIX" "$hash"
}

dokploy_canary_already_validated() {
  is_done "$(_canary_target_key)"
}

_canary_compose_yaml() {
  cat <<EOF
services:
  ${CANARY_APP_NAME}:
    image: busybox
    container_name: ${CANARY_APP_NAME}
    command: ["sh", "-c", "sleep 3600"]
    volumes:
      - ${CANARY_DIR}:/data
EOF
}

# Espera hasta $2 segundos (default 60) a que el contenedor $1 esté
# corriendo. Devuelve 0 si quedó "running", 1 si se agotó el tiempo o Docker
# no responde (fallar cerrado: nunca asumir éxito sin confirmarlo).
_canary_wait_running() {
  local name="$1" timeout="${2:-60}" waited=0
  while [[ "$waited" -lt "$timeout" ]]; do
    if [[ "$(hli_docker_presence)" == "present" ]] \
       && [[ "$(hli_docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

# Único punto de limpieza del compose canario: se llama desde TODAS las
# ramas de fallo de dokploy_canary_validate (antes solo las de después del
# bucle lo hacían; la falla del propio deploy/redeploy no borraba nada y
# podía dejar un compose "hli2-canary" huérfano en Dokploy). Busca el
# composeId por nombre en el estado local si no se lo pasan (puede no
# haberse capturado si el fallo ocurrió en el primer intento), y jamás falla
# el flujo de error del llamador aunque el borrado mismo falle (best-effort,
# ya se está abortando).
_canary_cleanup() {
  local composeId="${1:-}"
  [[ -n "$composeId" ]] || composeId="$(dokploy_compose_id_for "$CANARY_APP_NAME" 2>/dev/null)" || composeId=""
  [[ -n "$composeId" ]] && { dokploy_compose_delete "$composeId" true || true; }
  [[ -n "${compose_file:-}" ]] && rm -f "$compose_file"
}

# Corre la validación completa. Devuelve 0 solo si se pudo confirmar que el
# bind mount sobrevivió intacto a dos redeploys; en cualquier otro caso
# devuelve 1 con un mensaje explicativo por stdout (el llamador lo muestra
# con msg() y aborta v2.2 sin desplegar ningún servicio real). Idempotente
# por CLAVE DE DESTINO (_canary_target_key: URL + versión de Dokploy), no
# global: si ya se validó antes para este mismo Dokploy, no repite la
# prueba; un servidor/versión distinto sí la vuelve a correr.
dokploy_canary_validate() {
  local target_key
  target_key="$(_canary_target_key)"

  if is_done "$target_key"; then
    echo "La validación canaria ya se corrió con éxito antes para este Dokploy (URL/versión); se omite."
    return 0
  fi

  local project_json environment_id
  project_json="$(dokploy_project_find_or_create)" || { echo "No se pudo crear/encontrar el proyecto 'homelab' en Dokploy."; return 1; }
  environment_id="$(dokploy_environment_default_id "$project_json")" || { echo "No se pudo resolver el environmentId por defecto del proyecto 'homelab'."; return 1; }

  sudo mkdir -p "$CANARY_DIR"
  local sentinel_content="hli2-canary-$(date +%s)-$$"
  printf '%s' "$sentinel_content" | sudo tee "$CANARY_SENTINEL" >/dev/null
  local before_sum
  before_sum="$(sudo sha256sum "$CANARY_SENTINEL" | awk '{print $1}')" || true

  local compose_file composeId=""
  compose_file="$(mktemp)"
  _canary_compose_yaml > "$compose_file"

  local i
  for i in 1 2 3; do
    # 1: creación inicial; 2 y 3: dos redeploys (lo pedido: "redeploy twice").
    if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "$CANARY_APP_NAME" "$compose_file")"; then
      echo "Falló el deploy #$i del compose canario vía la API de Dokploy."
      _canary_cleanup "$composeId"
      return 1
    fi
    if ! _canary_wait_running "$CANARY_APP_NAME" 90; then
      echo "El contenedor canario no quedó 'running' tras el deploy #$i (timeout)."
      _canary_cleanup "$composeId"
      return 1
    fi
  done
  rm -f "$compose_file"

  if [[ ! -f "$CANARY_SENTINEL" ]]; then
    echo "CRÍTICO: el archivo centinela desapareció tras los redeploys. Dokploy SÍ toca el bind mount fuera de su carpeta de código. Se aborta v2.2: no es seguro desplegar Jellyfin/qBittorrent/AdGuard así."
    _canary_cleanup "$composeId"
    return 1
  fi

  local after_sum
  # '|| true': si sha256sum fallara acá (permisos, carrera), after_sum queda
  # vacío -> el chequeo de abajo lo trata como "distinto de before_sum" ->
  # aborta por seguridad de todos modos (fail-closed), en vez de matar el
  # script entero por pipefail antes de poder avisar con el mensaje CRÍTICO.
  after_sum="$(sudo sha256sum "$CANARY_SENTINEL" | awk '{print $1}')" || true
  if [[ "$before_sum" != "$after_sum" ]]; then
    echo "CRÍTICO: el archivo centinela existe pero su contenido CAMBIÓ tras los redeploys. Se aborta v2.2 por seguridad."
    _canary_cleanup "$composeId"
    return 1
  fi

  if ! dokploy_compose_delete "$composeId" true; then
    echo "AVISO: la validación canaria fue exitosa, pero no se pudo borrar el compose de prueba ('$CANARY_APP_NAME') en Dokploy. Bórrelo a mano desde el panel."
  fi
  sudo rm -rf "$CANARY_DIR"

  mark_done "$target_key"
  echo "Validación canaria OK: el bind mount sobrevivió intacto a dos redeploys."
  return 0
}

# Paso común a los tres módulos de servicio (jellyfin/qbittorrent/adguard)
# ANTES de desplegar nada real: asegura credenciales de la API de Dokploy
# (pide si faltan) y corre/confirma la validación canaria. Devuelve 1 (y ya
# avisó con msg()) si cualquiera de las dos cosas falla: ningún módulo de
# servicio debe seguir a un compose.create/update real sin esto.
dokploy_preflight() {
  if ! dokploy_api_configured; then
    msg "Todavía no hay credenciales guardadas para la API de Dokploy.\n\nSe piden ahora (una sola vez)."
    dokploy_api_setup || { msg "No se configuró la API de Dokploy. Se cancela el despliegue."; return 1; }
  fi

  local out rc=0
  out="$(dokploy_canary_validate)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    msg "La validación canaria de Dokploy (obligatoria antes del primer despliegue real) FALLÓ:\n\n$out\n\nNo se desplegará ningún servicio hasta resolver esto. Revise la API/URL/token y el estado de Dokploy."
    return 1
  fi
  return 0
}
