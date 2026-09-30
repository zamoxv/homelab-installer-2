#!/usr/bin/env bash
# Sourceada por cada stub de tests/stubs/. Provee el logging común y el
# chequeo de "ruta seguro" que usan sudo/tee/etc. antes de tocar cualquier
# archivo de verdad.
set -uo pipefail

: "${STUB_CALL_LOG:=/dev/null}"

# Registra una invocación: una línea "CMD<TAB>arg1<TAB>arg2<TAB>...". Los
# argumentos de este proyecto no traen tabs, así que es seguro usarlo como
# separador sin ambigüedad al parsear después con 'grep -P "\t"'/'cut -f'.
log_call() {
  local cmd="$1"
  shift
  { printf '%s' "$cmd"; printf '\t%s' "$@"; printf '\n'; } >> "$STUB_CALL_LOG"
}

# ¿Es $1 una ruta absoluta que cae DENTRO de $STUB_SAFE_ROOT? Se usa antes de
# ejecutar de verdad cualquier operación de archivo dentro de los stubs
# 'sudo'/similares: si algún argumento con forma de ruta NO cae ahí (ej.
# /etc/fstab, una ruta real del sistema), la operación se descarta siempre
# (nunca se ejecuta de verdad), sin importar qué test se esté corriendo.
_stub_path_is_safe() {
  local path="$1"
  [[ -n "${STUB_SAFE_ROOT:-}" ]] || return 1
  [[ "$path" == "$STUB_SAFE_ROOT"* ]]
}

# ¿Son TODOS los argumentos con forma de ruta (empiezan con '/', y no son
# '/dev/null' que es un destino inocuo) seguros según _stub_path_is_safe?
# Los que no empiezan con '/' (flags, nombres de usuario/grupo para
# chown...) se ignoran para este chequeo.
_stub_all_paths_safe() {
  local a
  for a in "$@"; do
    case "$a" in
      /dev/null) continue ;;
      /*)
        _stub_path_is_safe "$a" || return 1
        ;;
    esac
  done
  return 0
}

# --- Simulación de "root-only, no atravesable sin sudo" ---------------------
#
# $STUB_ROOT_AREA (fijado por tests/lib/harness.sh, ej. el scratch que hace
# de "/etc/hli2") se deja en modo 000 al final de harness_setup_env: ni
# siquiera el usuario del test (que es su dueño) puede atravesarlo sin
# privilegios reales — así un '[[ -f ]]'/'cat' SIN pasar por el stub de
# 'sudo' falla de verdad, reproduciendo el bug real (CRÍTICO 1, ronda 2 de
# revisión: /etc/hli2 0700 root:root, ilegible para el usuario normal que
# corre bootstrap.sh). El stub de 'sudo' es la única "puerta": antes de
# tocar algo ahí adentro se restaura el acceso del propio dueño (el usuario
# del test, que SÍ puede volver a chmodear lo que ya es suyo — eso no
# requiere privilegios, a diferencia de LEER un 000), hace la operación real,
# y vuelve a trabarlo a 000 antes de salir. Nunca usar 'exec' alrededor de
# esto: 'exec' reemplaza el proceso y el 're-lock' de abajo nunca correría.
_stub_unlock_root_area() {
  [[ -n "${STUB_ROOT_AREA:-}" && -d "$STUB_ROOT_AREA" ]] || return 0
  chmod u+rwx "$STUB_ROOT_AREA" 2>/dev/null || true
}

_stub_relock_root_area() {
  [[ -n "${STUB_ROOT_AREA:-}" && -d "$STUB_ROOT_AREA" ]] || return 0
  chmod 000 "$STUB_ROOT_AREA" 2>/dev/null || true
}
