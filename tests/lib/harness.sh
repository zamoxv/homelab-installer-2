#!/usr/bin/env bash
# Runner mínimo de tests para HLI 2, sin dependencias externas (bash puro +
# las herramientas de tests/stubs). Cada archivo tests/test_*.sh define una o
# más funciones test_* que este harness descubre y corre en un subshell
# aislado, con su propio directorio de scratch y su propia copia del PATH
# apuntando a tests/stubs ANTES que el PATH real.
set -uo pipefail
# (sin 'set -e' acá: el runner necesita seguir corriendo tests aunque uno
# falle, para reportar el resumen final)

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
STUBS_DIR="$TESTS_DIR/stubs"

TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

# --- Aserciones (para usar DENTRO de una función test_*) --------------------
# Todas escriben el motivo del fallo por stdout y devuelven 1: el caller
# (harness_run_test) decide qué hacer con eso.

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [[ "$expected" != "$actual" ]]; then
    echo "assert_eq falló${msg:+ ($msg)}: esperado=[$expected] actual=[$actual]"
    return 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "assert_contains falló${msg:+ ($msg)}: no se encontró [$needle]"
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "assert_not_contains falló${msg:+ ($msg)}: SÍ apareció [$needle] (no debía)"
    return 1
  fi
}

assert_file_contains() {
  local file="$1" needle="$2" msg="${3:-}"
  if [[ ! -f "$file" ]]; then
    echo "assert_file_contains falló${msg:+ ($msg)}: no existe el archivo $file"
    return 1
  fi
  if ! grep -qF -- "$needle" "$file"; then
    echo "assert_file_contains falló${msg:+ ($msg)}: [$needle] no está en $file"
    return 1
  fi
}

assert_file_not_contains() {
  local file="$1" needle="$2" msg="${3:-}"
  [[ -f "$file" ]] || return 0
  if grep -qF -- "$needle" "$file"; then
    echo "assert_file_not_contains falló${msg:+ ($msg)}: [$needle] SÍ está en $file (no debía)"
    return 1
  fi
}

fail() {
  echo "$*"
  return 1
}

# --- Entorno de test aislado --------------------------------------------------
#
# Crea un directorio de scratch nuevo y exporta TODAS las variables
# overridables del código real, con el prefijo 'HLI2_' que el propio código
# exige desde la ronda 2 de revisión de seguridad (ver lib/core.sh,
# lib/dokploy_api.sh, lib/dns.sh, lib/secrets.sh: un nombre genérico como
# "STATE_DIR" ya NO alcanza para redirigir nada, a propósito, para que una
# variable ambiental cualquiera no pueda secuestrar esas rutas en
# producción). Además exporta un alias SIN el prefijo (mismo valor) para que
# los propios tests puedan referenciar "$STATE_DIR", "$SECRETS_DIR", etc. en
# sus asserts sin tener que repetir el prefijo por todos lados — esos alias
# no los lee ningún código de producción, son pura comodidad del test.
#
# STUB_SAFE_ROOT: los stubs de tests/stubs/sudo solo ejecutan de verdad
# operaciones de archivo (mkdir/tee/install/cp/cat/test) cuando TODOS los
# argumentos con forma de ruta caen bajo este directorio; para cualquier
# otra ruta (ej. /etc/fstab, real del sistema) las descartan siempre. Es una
# defensa en profundidad: protege aunque un test se olvide de apuntar
# alguna variable a su scratch dir.
#
# STUB_ROOT_AREA: el subdirectorio que simula "/etc/hli2 real" (0700
# root:root, NO atravesable por el usuario sin privilegios). Se deja en modo
# 000 al final de este setup — ver el comentario de _stub_unlock_root_area/
# _stub_relock_root_area en tests/stubs/sudo para cómo el propio stub de
# 'sudo' lo destraba/vuelve a trabar alrededor de cada operación
# privilegiada, simulando que solo 'sudo' (nunca un acceso plano) puede
# entrar ahí. Sin esto, un '[[ -f ]]'/'cat' SIN privilegios sobre un archivo
# de test seguiría funcionando igual que uno CON privilegios (mismo dueño:
# el usuario del test) y la ronda 1 de tests jamás podría haber visto el bug
# de lectura root-only (CRÍTICO 1 de la ronda 2 de revisión).
harness_setup_env() {
  local scratch
  scratch="$(mktemp -d)"
  # 'export' de acá abajo tiene que pegarle al shell que LLAMA a esta
  # función, no a un subshell descartable: por eso harness_run_test invoca
  # esta función directamente ('harness_setup_env', sin '$(...)'), nunca
  # capturando su salida por command substitution (eso correría todo el
  # cuerpo en un subshell y los 'export' se perderían al salir de él).
  # HLI2_TEST_SCRATCH es la única forma en que el resultado (la ruta del
  # scratch) sale de acá hacia el llamador.
  export HLI2_TEST_SCRATCH="$scratch"

  # Nunca sourcear el config/default.conf real del repo en un test: sus
  # asignaciones son incondicionales y pisarían APPDATA_ROOT/MEDIA_ROOT/
  # BACKUP_ROOT/MEDIA_GROUP exportados más abajo (ver el comentario de
  # HLI2_CONFIG_FILE en lib/core.sh). '/dev/null' no es un archivo regular
  # ('[[ -f ]]' lo ve como falso), así que no se sourcea nada.
  export HLI2_CONFIG_FILE="/dev/null"

  export STUB_SAFE_ROOT="$scratch"
  export STUB_CALL_LOG="$scratch/calls.log"
  export STUB_HTTP_BODIES_LOG="$scratch/http-bodies.log"
  : > "$STUB_CALL_LOG"
  : > "$STUB_HTTP_BODIES_LOG"

  export STATE_DIR="$scratch/state"
  export STATE_FILE="$STATE_DIR/state"
  export LOG_DIR="$scratch/log"
  export APPDATA_ROOT="$scratch/appdata"
  export BACKUP_ROOT="$scratch/backups"
  export MEDIA_ROOT="$scratch/media"
  export SECRETS_DIR="$scratch/etc-hli2"
  export DOKPLOY_ENV_FILE="$scratch/etc-hli2/dokploy.env"
  export DOKPLOY_STATE_FILE="$scratch/state/dokploy-compose-ids"
  export DNS_PORT_STATE_DIR="$scratch/state"

  # Overrides que SÍ lee el código de producción (mismos valores que los
  # alias de arriba, con el prefijo HLI2_ que lib/core.sh, lib/secrets.sh,
  # lib/dokploy_api.sh y lib/dns.sh exigen).
  export HLI2_STATE_DIR="$STATE_DIR"
  export HLI2_STATE_FILE="$STATE_FILE"
  export HLI2_LOG_DIR="$LOG_DIR"
  export HLI2_SECRETS_DIR="$SECRETS_DIR"
  export HLI2_DOKPLOY_ENV_FILE="$DOKPLOY_ENV_FILE"
  export HLI2_DOKPLOY_STATE_FILE="$DOKPLOY_STATE_FILE"
  export HLI2_DNS_PORT_STATE_DIR="$DNS_PORT_STATE_DIR"

  # Área "root-only" simulada (ver comentario de arriba). Misma carpeta que
  # ya contenía los secretos/credenciales (SECRETS_DIR == dirname de
  # DOKPLOY_ENV_FILE), igual que en producción (todo bajo /etc/hli2).
  export STUB_ROOT_AREA="$SECRETS_DIR"

  # SERVER_USER/MEDIA_GROUP: el usuario/grupo REAL que corre los tests, así
  # 'id'/'getent' (reales, no stubbeados) funcionan sin necesitar
  # privilegios ni datos falsos.
  export SERVER_USER="$USER"
  export MEDIA_GROUP
  MEDIA_GROUP="$(id -gn)"

  mkdir -p "$STATE_DIR" "$LOG_DIR" "$APPDATA_ROOT" "$SECRETS_DIR" "$(dirname "$DOKPLOY_ENV_FILE")"
  touch "$STATE_FILE"

  # Colas de respuestas para el stub de 'dialog' (ver tests/stubs/dialog):
  # un archivo por tipo de widget, una respuesta por línea, consumidas en
  # orden (FIFO) y file-based (sobreviven entre invocaciones del stub,
  # que es un proceso nuevo cada vez).
  export DIALOG_INPUTBOX_QUEUE="$scratch/dialog-inputbox.queue"
  export DIALOG_PASSWORDBOX_QUEUE="$scratch/dialog-passwordbox.queue"
  export DIALOG_YESNO_QUEUE="$scratch/dialog-yesno.queue"
  export DIALOG_MENU_QUEUE="$scratch/dialog-menu.queue"
  : > "$DIALOG_INPUTBOX_QUEUE"
  : > "$DIALOG_PASSWORDBOX_QUEUE"
  : > "$DIALOG_YESNO_QUEUE"
  : > "$DIALOG_MENU_QUEUE"

  # Credenciales de la API de Dokploy YA configuradas (dokploy_api_configured
  # == true): evita que dokploy_preflight dispare dokploy_api_setup (que
  # pediría IP/puerto/token por TUI, ruido innecesario para estos tests).
  # Se escriben ACÁ (fuera del stub de 'sudo', directo como el usuario del
  # test) y recién DESPUÉS se traba el área — así, de ahí en más, hasta
  # ESTE archivo sembrado por el propio harness queda genuinamente
  # inaccesible sin pasar por 'sudo', igual que en producción.
  {
    echo "DOKPLOY_URL=http://test-dokploy:3000"
    echo "DOKPLOY_TOKEN=test-token-abc123"
  } > "$DOKPLOY_ENV_FILE"
  chmod 0600 "$DOKPLOY_ENV_FILE"

  chmod 000 "$STUB_ROOT_AREA"
}

# Marca la validación canaria de Dokploy como ya hecha para el target actual
# (mismo cálculo que _canary_target_key en lib/canary.sh), así
# dokploy_preflight no intenta correr el compose descartable de la
# validación canaria (que necesitaría emular todo un ciclo de
# deploy/redeploy contra la API falsa). Debe llamarse DESPUÉS de
# harness_setup_env y con el mismo PATH (stubs) ya activo, para que el
# hash coincida exactamente con el que calculará el módulo real más tarde.
harness_mark_canary_done() {
  (
    set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    key="$(_canary_target_key)"
    mark_done "$key"
  )
}

# --- Descubrimiento y ejecución de tests -------------------------------------

# Corre la función de test $1 (ya debe estar definida en el shell actual) en
# un entorno aislado (harness_setup_env) y con PATH de stubs primero.
# Imprime PASS/FAIL y devuelve el código de la función.
harness_run_test() {
  local test_fn="$1" scratch rc=0 output

  harness_setup_env
  scratch="$HLI2_TEST_SCRATCH"
  export PATH="$STUBS_DIR:$PATH"

  output="$("$test_fn" 2>&1)" || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    echo "  OK   $test_fn"
  else
    echo "  FAIL $test_fn"
    while IFS= read -r line; do echo "         $line"; done <<<"$output"
    echo "         (scratch: $scratch)"
  fi

  # STUB_ROOT_AREA puede haber quedado en modo 000 (ver harness_setup_env):
  # restaurar permisos ANTES de borrar, o 'rm -rf' no puede ni atravesarlo
  # para limpiar su contenido (aunque el usuario del test sea el dueño).
  chmod -R u+rwx "$scratch" 2>/dev/null || true
  rm -rf "$scratch"
  return "$rc"
}
