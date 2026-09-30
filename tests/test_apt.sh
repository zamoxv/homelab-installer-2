#!/usr/bin/env bash
# apt siempre en modo no interactivo.
#
# Bug real encontrado en la X230 (Ubuntu 26.04): bootstrap.sh exporta
# DEBIAN_FRONTEND=noninteractive, pero 'sudo' descarta las variables de
# entorno (env_reset), así que 'sudo apt upgrade' abrió la pregunta de
# keyboard-configuration en un módulo que corre en segundo plano (sin
# teclado) y la instalación quedó colgada. Toda llamada a apt tiene que pasar
# la variable a través de sudo con 'env' (lo que hace hli_apt).

# Ninguna llamada directa 'sudo apt'/'sudo apt-get' fuera de hli_apt.
test_apt_no_direct_sudo_apt_calls() {
  local hits
  hits="$(grep -rnE 'sudo +(-n +)?apt(-get)? ' \
    "$REPO_ROOT/bootstrap.sh" "$REPO_ROOT/lib" "$REPO_ROOT/modules" \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  if [[ -n "$hits" ]]; then
    fail "llamadas a apt que no pasan DEBIAN_FRONTEND a través de sudo:"$'\n'"$hits"
    return 1
  fi
}

# End-to-end: el módulo base real invoca apt-get vía 'sudo env
# DEBIAN_FRONTEND=noninteractive ...', con la entrada cerrada.
test_apt_base_module_is_noninteractive() {
  bash "$REPO_ROOT/modules/base.sh" || return 1

  local apt_calls bad
  apt_calls="$(grep -P '^sudo\t.*apt-get' "$STUB_CALL_LOG" || true)"
  [[ -n "$apt_calls" ]] || { fail "base no invocó apt-get"; return 1; }

  bad="$(grep -v 'DEBIAN_FRONTEND=noninteractive' <<<"$apt_calls" || true)"
  if [[ -n "$bad" ]]; then
    fail "apt-get sin DEBIAN_FRONTEND=noninteractive:"$'\n'"$bad"
    return 1
  fi
}
