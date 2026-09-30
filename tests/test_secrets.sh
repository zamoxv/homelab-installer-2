#!/usr/bin/env bash
# Tests unitarios de lib/secrets.sh: guardar/leer secretos, que el contenido
# nunca pase por el argv de 'sudo' (va por stdin a 'tee'), y (ronda 2 de
# revisión de seguridad) que la lectura funcione de verdad aunque
# /etc/hli2 sea root-only (0700 root:root en producción) e ILEGIBLE para el
# usuario sin privilegios que corre bootstrap.sh — CRÍTICO 1.
#
# El harness (tests/lib/harness.sh) deja $SECRETS_DIR (== $STUB_ROOT_AREA)
# en modo 000 al terminar el setup, y el stub de 'sudo' lo destraba/retraba
# SOLO durante cada llamada privilegiada (ver tests/stubs/sudo) — así un
# acceso PLANO (sin sudo) genuinamente falla, y solo secret_get/
# secret_file_exists (que pasan por sudo -n test/cat) pueden leer.

test_secrets_write_and_read_roundtrip() {
  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    secret_file_exists demo && { echo "no debería existir todavía"; exit 1; }
    secret_file_write demo "ADMIN_TOKEN=super-secreto-123"
    secret_file_exists demo || { echo "debería existir después de escribirlo"; exit 1; }
    val="$(secret_get demo ADMIN_TOKEN)"
    [[ "$val" == "super-secreto-123" ]] || { echo "valor leído no coincide: [$val]"; exit 1; }
  ) || return 1

  assert_file_not_contains "$STUB_CALL_LOG" "super-secreto-123" \
    "el contenido del secreto nunca debe estar en argv de sudo/tee" || return 1
}

test_secrets_file_permissions_0600() {
  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    secret_file_write demo "X=1"
  ) || return 1

  # Vía 'sudo -n stat' (privilegiado): $SECRETS_DIR queda 000 apenas termina
  # secret_file_write (ver harness/stub), así que un 'stat' PLANO acá
  # también fallaría — se verifica el modo con el mismo mecanismo
  # privilegiado que usa el código real.
  local f="$SECRETS_DIR/demo.env" mode
  mode="$(sudo -n stat -c '%a' -- "$f")" || { echo "no se pudo leer el modo (¿sudo -n roto?)"; return 1; }
  assert_eq "600" "$mode" "modo del archivo de secretos" || return 1
}

test_secrets_multiple_keys_one_file() {
  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    secret_file_write demo $'A=1\nB=2'
    a="$(secret_get demo A)"
    b="$(secret_get demo B)"
    [[ "$a" == "1" && "$b" == "2" ]] || { echo "A=[$a] B=[$b]"; exit 1; }
  ) || return 1
}

# CRÍTICO 1 (ronda 2 de revisión): prueba, en un mismo test, las DOS caras
# del bug/fix:
#   (a) un acceso PLANO sin privilegios al archivo de secretos FALLA de
#       verdad (simula /etc/hli2 0700 root:root real) — esto es lo que la
#       ronda 1 de tests NUNCA pudo ver (los archivos quedaban dueños del
#       propio usuario del test, siempre legibles por él).
#   (b) secret_get/secret_file_exists SÍ funcionan igual, porque pasan por
#       'sudo -n test'/'sudo -n cat' (priv_file_exists/priv_file_read).
# Si se revirtiera el fix (volver secret_get/secret_file_exists a
# '[[ -f ]]'/'sed' sin sudo), la parte (b) de este test pasaría a fallar —
# ver el "antes/después" corrido a mano en el informe de esta tarea.
test_secrets_unreadable_without_sudo_but_readable_via_secret_get() {
  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    secret_file_write vaultwarden "ADMIN_TOKEN=el-secreto-real"
  ) || { echo "no se pudo escribir el secreto de prueba"; return 1; }

  local f="$SECRETS_DIR/vaultwarden.env"

  # (a) Acceso PLANO (sin sudo, tal cual lo haría un '[[ -f ]]'/'cat' viejo):
  # debe fallar. Si esto NO falla, el harness no está simulando el bug real
  # y el resto del test no prueba nada.
  if [[ -f "$f" ]]; then
    fail "el harness no está simulando /etc/hli2 root-only: un '[[ -f ]]' plano SÍ vio el archivo (STUB_ROOT_AREA no quedó realmente bloqueado)"
    return 1
  fi
  if cat "$f" >/dev/null 2>&1; then
    fail "un 'cat' plano (sin sudo) pudo leer el archivo de secretos; debería fallar (permiso denegado)"
    return 1
  fi

  # (b) Vía la función real del proyecto (usa 'sudo -n' por dentro): debe
  # funcionar y devolver el valor correcto.
  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    secret_file_exists vaultwarden || { echo "secret_file_exists debería ver el archivo vía sudo"; exit 1; }
    val="$(secret_get vaultwarden ADMIN_TOKEN)"
    [[ "$val" == "el-secreto-real" ]] || { echo "secret_get no devolvió el valor correcto: [$val]"; exit 1; }
  ) || return 1
}
