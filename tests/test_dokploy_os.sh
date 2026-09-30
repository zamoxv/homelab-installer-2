#!/usr/bin/env bash
# Validado en la X230: en Ubuntu 26.04 el instalador oficial de Dokploy
# falla (no existe Docker 28.5.0 para ese sistema) y Docker 29 rompe su
# Traefik. El módulo debe BLOQUEAR los sistemas no soportados.
#
# No se prueba end-to-end: llegar al chequeo de SO exige simular una máquina
# sin Docker, y la lista de rastros de Docker (lib/core.sh) NO es
# configurable a propósito (es un chequeo de seguridad). Se prueba la
# función que decide y que el camino "instalar de todos modos" ya no existe.

# Carga las funciones del módulo sin ejecutar _dokploy_main: $0 apunta a una
# ruta inexistente dentro de modules/ (el guardia BASH_SOURCE[0] == $0 no se
# cumple, y la ruta relativa a lib/ sigue resolviendo).
_load_dokploy_functions() {
  bash -c 'source "$1"; shift; "$@"' \
    "$REPO_ROOT/modules/__test_nunca_existe__.sh" \
    "$REPO_ROOT/modules/dokploy.sh" "$@"
}

test_dokploy_os_support_matrix() {
  _load_dokploy_functions _dp_os_supported ubuntu 24.04 \
    || { fail "Ubuntu 24.04 debería estar soportado"; return 1; }
  _load_dokploy_functions _dp_os_supported ubuntu 22.04 \
    || { fail "Ubuntu 22.04 debería estar soportado"; return 1; }
  _load_dokploy_functions _dp_os_supported ubuntu 26.04 \
    && { fail "Ubuntu 26.04 NO debería estar soportado"; return 1; }
  _load_dokploy_functions _dp_os_supported debian 13 \
    && { fail "Debian 13 NO debería estar soportado"; return 1; }
  return 0
}

test_dokploy_unsupported_os_has_no_override() {
  if grep -q 'Instalar de todos modos' "$REPO_ROOT/modules/dokploy.sh"; then
    fail "el módulo todavía permite instalar en un sistema no soportado"
    return 1
  fi
}
