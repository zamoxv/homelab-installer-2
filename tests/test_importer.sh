#!/usr/bin/env bash
# Tests v2.3.1 del importador (modules/import-v1.sh, lib/importer.sh) y del
# diagnóstico de módulos (hli_error, trap ERR, hli_require_sudo).

# Crea un backup v1 mínimo (solo Jellyfin) en $1 y un 'tar' envoltorio que
# registra en $2 cada invocación de extracción (-x). Imprime nada.
_mk_backup() {
  local tar_out="$1" shim_dir="$2" src="$STUB_SAFE_ROOT/src-v1"
  mkdir -p "$src/jellyfin/lib" "$shim_dir"
  echo "x" > "$src/config.yml"
  echo "datos" > "$src/jellyfin/lib/data.txt"
  ( cd "$src" && tar -czf "$tar_out" config.yml jellyfin )
  local real_tar
  real_tar="$(command -v tar)"
  cat > "$shim_dir/tar" <<SHIM
#!/usr/bin/env bash
case "\$*" in *-x*) echo "EXTRACT \$*" >> "$STUB_SAFE_ROOT/tar-extract.log" ;; esac
exec "$real_tar" "\$@"
SHIM
  chmod +x "$shim_dir/tar"
}

test_import_running_service_stops_imports_and_redeploys() {
  local tarf="$STUB_SAFE_ROOT/backup.tar.gz"
  _mk_backup "$tarf" "$STUB_SAFE_ROOT/shim"
  export PATH="$STUB_SAFE_ROOT/shim:$PATH"
  export STUB_COMPOSE_ONE_OK=1
  echo "jellyfin cid-existing" > "$DOKPLOY_STATE_FILE"
  echo "$tarf" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'yes\nyes\n' > "$DIALOG_YESNO_QUEUE"   # importar Jellyfin; detenerlo

  bash "$REPO_ROOT/modules/import-v1.sh" || { fail "import-v1 falló"; return 1; }

  assert_file_contains "$STUB_CALL_LOG" "está corriendo. ¿Detenerlo, importar su configuración y volver a desplegarlo?" "pregunta de detener" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'docker\tstop\tjellyfin' "stop del contenedor" || return 1
  assert_file_contains "$STUB_CALL_LOG" "rsync" "se copió la configuración" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" '"composeId": "cid-existing"' "redespliegue con el composeId guardado" || return 1
  assert_file_contains "$STUB_CALL_LOG" "compose.deploy" "compose.deploy llamado" || return 1
  assert_file_contains "$STATE_FILE" "import-v1" "módulo marcado" || return 1
}

test_import_redeploy_failure_is_reported() {
  local tarf="$STUB_SAFE_ROOT/backup.tar.gz"
  _mk_backup "$tarf" "$STUB_SAFE_ROOT/shim"
  export PATH="$STUB_SAFE_ROOT/shim:$PATH"
  # Sin composeId registrado: el redespliegue no puede hacerse.
  echo "$tarf" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'yes\nyes\n' > "$DIALOG_YESNO_QUEUE"

  bash "$REPO_ROOT/modules/import-v1.sh" || { fail "import-v1 falló"; return 1; }

  assert_file_contains "$STUB_CALL_LOG" "ya está importada, pero no se pudo volver a desplegar" "aviso claro" || return 1
  assert_file_contains "$LOG_DIR/import-v1.log" "no se pudo volver a desplegar" "rastro en el log" || return 1
}

test_import_answer_no_skips_and_never_extracts() {
  local tarf="$STUB_SAFE_ROOT/backup.tar.gz"
  _mk_backup "$tarf" "$STUB_SAFE_ROOT/shim"
  export PATH="$STUB_SAFE_ROOT/shim:$PATH"
  echo "$tarf" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"   # importar; NO detenerlo

  bash "$REPO_ROOT/modules/import-v1.sh" || { fail "import-v1 falló"; return 1; }

  assert_file_contains "$STUB_CALL_LOG" "se omite la importación" "mensaje explícito de omisión" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'docker\tstop' "no debe detener nada" || return 1
  if [[ -s "$STUB_SAFE_ROOT/tar-extract.log" ]]; then
    fail "se extrajo el backup aunque no se iba a importar nada"
    return 1
  fi
}

test_import_unknown_state_is_a_separate_message() {
  local tarf="$STUB_SAFE_ROOT/backup.tar.gz"
  _mk_backup "$tarf" "$STUB_SAFE_ROOT/shim"
  export PATH="$STUB_SAFE_ROOT/shim:$PATH"
  export STUB_SUDO_FAIL_N=1
  echo "$tarf" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'yes\nyes\n' > "$DIALOG_YESNO_QUEUE"

  bash "$REPO_ROOT/modules/import-v1.sh" || { fail "import-v1 falló"; return 1; }

  assert_file_contains "$STUB_CALL_LOG" "No se pudo consultar el estado de Docker (¿sudo sin contraseña en caché?). Se omite Jellyfin por seguridad." "mensaje de desconocido" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "está corriendo" "no mezclar con 'activo'" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'docker\tstop' "no debe detener nada" || return 1
  if [[ -s "$STUB_SAFE_ROOT/tar-extract.log" ]]; then
    fail "se extrajo el backup con el estado desconocido"
    return 1
  fi
}

# Copia mínima del repo en el scratch con un módulo de prueba que falla.
_mk_repo_copy() {
  local copy="$STUB_SAFE_ROOT/repo"
  mkdir -p "$copy"
  cp -r "$REPO_ROOT/lib" "$REPO_ROOT/modules" "$REPO_ROOT/services" "$REPO_ROOT/compose" "$REPO_ROOT/config" "$copy/"
  printf '%s' "$copy"
}

test_err_trap_logs_line_number_in_module_log() {
  local copy
  copy="$(_mk_repo_copy)"
  cat > "$copy/modules/zz-fail.sh" <<'EOF'
#!/usr/bin/env bash
# HLI-MODULE: zz-fail
# HLI-TUI: yes
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"
if false; then :; fi
false || true
[[ -d /nonexistent ]] && echo no
echo "antes"
mi_comando_inexistente_con_arg_secreto hunter2
echo "no debe llegar"
EOF
  bash "$copy/modules/zz-fail.sh" >/dev/null 2>&1 && { fail "el módulo debía fallar"; return 1; }

  assert_file_contains "$LOG_DIR/zz-fail.log" "Error en zz-fail línea 10: mi_comando_inexistente_con_arg_secreto (código 127)" "línea y comando en el log del módulo" || return 1
  assert_file_contains "$LOG_DIR/install.log" "Error en zz-fail línea 10" "también en install.log" || return 1
  assert_file_not_contains "$LOG_DIR/zz-fail.log" "hunter2" "nunca los argumentos" || return 1
  local n
  n="$(grep -c 'Error en zz-fail' "$LOG_DIR/zz-fail.log")"
  assert_eq "1" "$n" "solo la falla real: nada de disparos espurios en condicionales/||/&&" || return 1
}

test_hli_error_writes_stderr_and_module_log() {
  local err
  err="$( ( set -euo pipefail; HLI2_MODULE_NAME=demo; source "$REPO_ROOT/lib/core.sh"; hli_error "algo salió mal" ) 2>&1 >/dev/null )"
  assert_contains "$err" "ERROR: algo salió mal" "stderr" || return 1
  assert_file_contains "$LOG_DIR/demo.log" "ERROR: algo salió mal" "log del módulo" || return 1
  assert_file_contains "$LOG_DIR/install.log" "ERROR: algo salió mal" "install.log" || return 1
}

test_require_sudo_never_asks_without_tty() {
  ( set -euo pipefail; export STUB_SUDO_FAIL_N=1; source "$REPO_ROOT/lib/core.sh" ) </dev/null
  assert_file_not_contains "$STUB_CALL_LOG" $'sudo\t-v' "sin tty no hay 'sudo -v'" || return 1
}

# import-v1: detener -> copiar -> redesplegar, en ese orden.
test_import_v1_order_is_stop_then_copy_then_redeploy() {
  local tarf="$STUB_SAFE_ROOT/backup.tar.gz"
  _mk_backup "$tarf" "$STUB_SAFE_ROOT/shim"
  export PATH="$STUB_SAFE_ROOT/shim:$PATH"
  export STUB_COMPOSE_ONE_OK=1
  echo "jellyfin cid-existing" > "$DOKPLOY_STATE_FILE"
  echo "$tarf" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'yes\nyes\n' > "$DIALOG_YESNO_QUEUE"   # importar; detener

  bash "$REPO_ROOT/modules/import-v1.sh" || { fail "import-v1 falló"; return 1; }

  local stop_line copy_line deploy_line
  stop_line="$(grep -nF $'docker\tstop\tjellyfin' "$STUB_CALL_LOG" | head -n1 | cut -d: -f1)"
  copy_line="$(grep -nF 'rsync' "$STUB_CALL_LOG" | head -n1 | cut -d: -f1)"
  deploy_line="$(grep -nF 'compose.deploy' "$STUB_CALL_LOG" | head -n1 | cut -d: -f1)"
  [[ -n "$stop_line" && -n "$copy_line" && -n "$deploy_line" ]] || { fail "faltan llamadas (stop=$stop_line copy=$copy_line deploy=$deploy_line)"; return 1; }
  (( stop_line < copy_line )) || { fail "detener debe ir antes de copiar"; return 1; }
  (( copy_line < deploy_line )) || { fail "copiar debe ir antes de redesplegar"; return 1; }
  assert_file_not_contains "$STUB_CALL_LOG" $'docker\tstart' "nada que re-arrancar tras un redespliegue correcto" || return 1
}

# Si el redespliegue falla, el contenedor detenido se vuelve a arrancar.
test_import_v1_restarts_container_if_redeploy_fails() {
  local tarf="$STUB_SAFE_ROOT/backup.tar.gz"
  _mk_backup "$tarf" "$STUB_SAFE_ROOT/shim"
  export PATH="$STUB_SAFE_ROOT/shim:$PATH"
  export STUB_COMPOSE_ONE_OK=1 STUB_CURL_FAIL_DEPLOY=1
  echo "jellyfin cid-existing" > "$DOKPLOY_STATE_FILE"
  echo "$tarf" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'yes\nyes\n' > "$DIALOG_YESNO_QUEUE"

  bash "$REPO_ROOT/modules/import-v1.sh" || { fail "import-v1 falló"; return 1; }

  assert_file_contains "$STUB_CALL_LOG" $'docker\tstop\tjellyfin' "se detuvo" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'docker\tstart\tjellyfin' "se volvió a arrancar" || return 1
  assert_file_contains "$STUB_CALL_LOG" "ya está importada, pero no se pudo volver a desplegar" "aviso claro" || return 1
}

# Decisión 2026-10-05: los módulos de servicio NO ofrecen importar un backup
# del v1 (solo la herramienta import-v1).
test_service_modules_do_not_offer_v1_import() {
  local m
  for m in jellyfin qbittorrent; do
    : > "$STUB_CALL_LOG"
    harness_mark_canary_done
    bash "$REPO_ROOT/modules/$m.sh" || { fail "$m.sh falló"; return 1; }
    assert_file_not_contains "$STUB_CALL_LOG" "backup del HLI v1" "$m no debe ofrecer importar" || return 1
    assert_file_not_contains "$STUB_CALL_LOG" $'dialog\t--title\tConfirmar' "$m no debe preguntar nada" || return 1
    assert_file_not_contains "$STUB_CALL_LOG" $'docker\tstop' "$m no debe detener nada" || return 1
  done
  if grep -qE "importer_(pending|apply_pending|extract|gate)|_offer_import" "$REPO_ROOT/modules/jellyfin.sh" "$REPO_ROOT/modules/qbittorrent.sh" "$REPO_ROOT/modules/adguard.sh"; then
    fail "quedó cableado de importación en los módulos de servicio"
    return 1
  fi
}

# S1: carpeta del componente sin archivos reales -> ni pregunta ni detiene.
test_import_component_without_data_is_not_offered() {
  local src="$STUB_SAFE_ROOT/src-empty" tarf="$STUB_SAFE_ROOT/empty.tar.gz"
  mkdir -p "$src/adguard" "$src/jellyfin/lib"
  echo x > "$src/config.yml"
  ( cd "$src" && tar -czf "$tarf" config.yml adguard jellyfin )
  echo "$tarf" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'yes\nyes\nyes\n' > "$DIALOG_YESNO_QUEUE"

  bash "$REPO_ROOT/modules/import-v1.sh" || { fail "import-v1 falló"; return 1; }

  assert_file_not_contains "$STUB_CALL_LOG" "¿Importar AdGuard" "no debe preguntar por AdGuard sin su yaml" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "¿Importar Jellyfin" "no debe preguntar por Jellyfin sin archivos"
  assert_file_contains "$STUB_CALL_LOG" "AdGuard Home: no viene en el backup" "el resumen informa el componente ausente" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'docker\tstop' "no debe detener nada" || return 1
}

# W1: importer_extract deja el directorio en la global (visible para el trap
# EXIT del llamador) y no imprime nada por stdout.
test_importer_extract_sets_global_work_dir() {
  local tarf="$STUB_SAFE_ROOT/backup.tar.gz" out
  _mk_backup "$tarf" "$STUB_SAFE_ROOT/shim"
  out="$( ( set -euo pipefail; source "$REPO_ROOT/lib/core.sh"; importer_extract "$tarf"; [[ -f "$IMPORT_WORK_DIR/config.yml" ]] && echo "DIR_OK:$IMPORT_WORK_DIR" ; importer_exit_cleanup; [[ ! -d "${IMPORT_WORK_DIR:-}" ]] && echo CLEANED ) )"
  assert_contains "$out" "DIR_OK:" "global fijada" || return 1
  assert_contains "$out" "CLEANED" "importer_exit_cleanup borra el directorio" || return 1
}

# W2: red de seguridad de contenedores detenidos.
test_exit_cleanup_restarts_only_still_stopped_containers() {
  ( set -euo pipefail; source "$REPO_ROOT/lib/core.sh"
    importer_stopped_add jellyfin; importer_stopped_add adguard
    importer_stopped_clear jellyfin
    importer_exit_cleanup )
  assert_file_contains "$STUB_CALL_LOG" $'docker\tstart\tadguard' "adguard sigue detenido: se arranca" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'docker\tstart\tjellyfin' "jellyfin ya se desplegó: no se toca" || return 1
}

test_importer_cleanup_removes_work_dir_and_err_file() {
  local w="$STUB_SAFE_ROOT/work1"
  mkdir -p "$w"; : > "$w.err"; : > "$w.err.done"
  ( set -euo pipefail; source "$REPO_ROOT/lib/core.sh"; importer_cleanup "$w" )
  [[ ! -e "$w" && ! -e "$w.err" && ! -e "$w.err.done" ]] || { fail "quedaron restos"; return 1; }
}

# Si el reinicio de un contenedor detenido falla (p. ej. sudo sin caché tras
# una espera larga), debe quedar registrado con el comando para hacerlo a
# mano: nunca un servicio caído en silencio.
test_exit_cleanup_logs_failed_restart() {
  ( source "$REPO_ROOT/lib/core.sh"
    importer_stopped_add adguard
    STUB_DOCKER_FAIL_START=1 importer_exit_cleanup ) 2>/dev/null
  assert_file_contains "$LOG_DIR/install.log" "sudo docker start adguard" "reinicio fallido registrado" || return 1
}

# Bajo 'set -e', un reinicio fallido no debe cortar la trampa de salida: los
# demás contenedores registrados se intentan igual.
test_exit_cleanup_continues_after_failed_restart() {
  local out
  # Proceso bash aparte: el harness corre cada test en un contexto (if/||)
  # donde bash ignora 'set -e' incluso si un subshell lo vuelve a activar, y
  # el error a detectar solo ocurre con 'set -e' activo (como en un módulo).
  out="$(REPO_ROOT="$REPO_ROOT" STUB_DOCKER_FAIL_START=1 bash -c '
    set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    importer_stopped_add uno
    importer_stopped_add dos
    importer_exit_cleanup
    echo TRAMPA_COMPLETA' 2>/dev/null)"
  assert_contains "$out" "TRAMPA_COMPLETA" "la limpieza termina aunque falle un reinicio" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'docker\tstart\tdos' "se intenta el segundo contenedor" || return 1
}
