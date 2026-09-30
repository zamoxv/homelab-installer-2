#!/usr/bin/env bash
# Runner de tests de HLI 2. Sin dependencias externas: bash + las
# herramientas reales que ya usa el propio HLI 2 (jq, sed, grep...) + los
# stubs de tests/stubs para todo lo que sería privilegiado/de red/destructivo
# (sudo, docker, curl, dialog, lsblk...).
#
# Uso: tests/run.sh [patrón]
#   Sin argumentos: corre todos los tests/test_*.sh.
#   Con un patrón: solo los archivos cuyo nombre lo contiene (ej.
#   'tests/run.sh vaultwarden' corre solo tests/test_vaultwarden.sh).
set -uo pipefail

# Como root, 'chmod 000' no restringe nada: el harness dejaría de modelar el
# límite de permisos entre el usuario y root (y bugs como leer /etc/hli2 sin
# sudo pasarían inadvertidos). Nunca correr los tests como root.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERROR: no corra los tests como root (el harness depende de permisos reales)." >&2
  exit 1
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
ORIGINAL_PATH="$PATH"
PATTERN="${1:-}"

# shellcheck source=lib/harness.sh
source "$TESTS_DIR/lib/harness.sh"

# Cada test (PASS/FAIL + nombre) se apila acá, una línea por test, en vez de
# intentar sumar contadores numéricos entre subshells (un subshell no puede
# devolverle variables a su padre) — así el conteo final es un simple 'grep
# -c' sobre este archivo, sin coordinación entre procesos.
RESULTS_FILE="$(mktemp)"
trap 'rm -f "$RESULTS_FILE"' EXIT

for test_file in "$TESTS_DIR"/test_*.sh; do
  [[ -f "$test_file" ]] || continue
  base="$(basename "$test_file")"
  if [[ -n "$PATTERN" && "$base" != *"$PATTERN"* ]]; then
    continue
  fi

  echo "== $base =="

  # Subshell: aísla las funciones test_* de un archivo de las de otro (si
  # dos archivos definieran una función con el mismo nombre por error, no se
  # pisan entre sí).
  (
    source "$test_file"
    for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
      PATH="$ORIGINAL_PATH"
      if harness_run_test "$fn"; then
        echo "PASS $base::$fn" >> "$RESULTS_FILE"
      else
        echo "FAIL $base::$fn" >> "$RESULTS_FILE"
      fi
    done
  )
done

TOTAL="$(wc -l < "$RESULTS_FILE" | tr -d ' ')"
PASSED="$(grep -c '^PASS ' "$RESULTS_FILE" || true)"
FAILED="$(grep -c '^FAIL ' "$RESULTS_FILE" || true)"

echo
echo "======================================"
echo "Total: $TOTAL   OK: $PASSED   FAIL: $FAILED"
if [[ "${FAILED:-0}" -gt 0 ]]; then
  echo "Fallaron:"
  grep '^FAIL ' "$RESULTS_FILE" | sed 's/^FAIL /  - /'
  echo "======================================"
  exit 1
fi
echo "======================================"
exit 0
