#!/usr/bin/env bash
# Tests del registro LOCAL de servicios (lib/services.sh, lib/backup.sh,
# lib/restore.sh, ui/menu.sh): servicios propios del usuario en
# $HLI2_LOCAL_SERVICES_DIR (en producción /etc/hli2.d/services). El harness
# apunta el directorio al scratch y usa el uid del usuario del test como
# "root" (HLI2_LOCAL_SERVICES_EXPECT_UID). Nunca se toca /etc.

source "$TESTS_DIR/lib/backup_helpers.sh"

# ¿miapp aparece en el listado de servicios?
_ls_listed() {
  ( source "$REPO_ROOT/lib/core.sh"; service_list ) | grep -qx "${1:-miapp}"
}

# --- Carga ----------------------------------------------------------------------------

test_local_service_is_listed_and_readable_with_local_marker() {
  _ls_write miapp sqlite
  _ls_listed || { fail "el servicio local debe aparecer en service_list"; return 1; }
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"
    echo "c=$(service_get miapp CONTAINER)"
    echo "k=$(service_get miapp BACKUP_KIND)"
    echo "d=$(service_get miapp DATA)"
    echo "n=$(service_display_name miapp)"
    echo "j=$(service_display_name jellyfin)" ) )"
  assert_contains "$out" "c=miapp-db-1" || return 1
  assert_contains "$out" "k=sqlite" || return 1
  assert_contains "$out" "d=$APPDATA_ROOT/miapp/db" || return 1
  assert_contains "$out" "n=Mi App (local)" || return 1
  assert_contains "$out" "j=Jellyfin" || return 1
  assert_not_contains "$out" "Jellyfin (local)" "los incluidos no llevan la marca" || return 1
}

test_without_local_registry_only_shipped_services_exist() {
  rm -rf "$(dirname "$HLI2_LOCAL_SERVICES_DIR")"
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; service_list ) )"
  assert_contains "$out" "jellyfin" || return 1
  assert_not_contains "$out" "miapp" || return 1
}

# --- Rechazos ---------------------------------------------------------------------------

test_local_service_not_owned_by_root_is_rejected() {
  _ls_write miapp
  # En producción el dueño esperado es root (0); el usuario del test no lo es.
  if ( export HLI2_LOCAL_SERVICES_EXPECT_UID=0; source "$REPO_ROOT/lib/core.sh"; service_list | grep -qx miapp ); then
    fail "un archivo que no es de root no debe cargarse"; return 1
  fi
}

test_local_service_group_or_other_writable_is_rejected() {
  _ls_write miapp
  chmod 0664 "$HLI2_LOCAL_SERVICES_DIR/miapp.conf"
  ! _ls_listed || { fail "escribible por el grupo: debe rechazarse"; return 1; }
  chmod 0646 "$HLI2_LOCAL_SERVICES_DIR/miapp.conf"
  ! _ls_listed || { fail "escribible por otros: debe rechazarse"; return 1; }
  chmod 0644 "$HLI2_LOCAL_SERVICES_DIR/miapp.conf"
  _ls_listed || { fail "con 0644 debe aceptarse"; return 1; }
}

test_local_service_in_writable_directory_is_rejected() {
  _ls_write miapp
  chmod 0775 "$HLI2_LOCAL_SERVICES_DIR"
  ! _ls_listed || { fail "directorio escribible por el grupo: debe rechazarse"; return 1; }
  chmod 0755 "$HLI2_LOCAL_SERVICES_DIR"
  chmod 0777 "$(dirname "$HLI2_LOCAL_SERVICES_DIR")"
  ! _ls_listed || { fail "padre escribible por otros: debe rechazarse"; return 1; }
  chmod 0755 "$(dirname "$HLI2_LOCAL_SERVICES_DIR")"
}

test_local_service_symlink_is_rejected() {
  _ls_write real
  ln -s real.conf "$HLI2_LOCAL_SERVICES_DIR/miapp.conf"
  ! _ls_listed miapp || { fail "un enlace simbólico no debe cargarse"; return 1; }
}

test_local_services_directory_symlink_is_rejected() {
  _ls_write miapp
  local real="$HLI2_TEST_SCRATCH/other-services"
  mv "$HLI2_LOCAL_SERVICES_DIR" "$real"
  ln -s "$real" "$HLI2_LOCAL_SERVICES_DIR"
  ! _ls_listed || { fail "el directorio como enlace simbólico debe rechazarse"; return 1; }
}

test_local_service_bad_file_name_is_rejected() {
  _ls_write miapp
  cp "$HLI2_LOCAL_SERVICES_DIR/miapp.conf" "$HLI2_LOCAL_SERVICES_DIR/Bad_Name.conf"
  cp "$HLI2_LOCAL_SERVICES_DIR/miapp.conf" "$HLI2_LOCAL_SERVICES_DIR/-lead.conf"
  cp "$HLI2_LOCAL_SERVICES_DIR/miapp.conf" "$HLI2_LOCAL_SERVICES_DIR/with space.conf"
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; service_list ) )"
  assert_contains "$out" "miapp" || return 1
  assert_not_contains "$out" "Bad_Name" || return 1
  assert_not_contains "$out" "-lead" || return 1
  assert_not_contains "$out" "with space" || return 1
}

# Sustituye la línea SERVICE_DATA de miapp y comprueba que se rechaza.
_ls_expect_rejected_data() {
  local data="$1" why="$2"
  _ls_write miapp
  sed -i "s|^SERVICE_DATA=.*|SERVICE_DATA=($data)|" "$HLI2_LOCAL_SERVICES_DIR/miapp.conf"
  ! _ls_listed || { fail "SERVICE_DATA $why: debe rechazarse"; return 1; }
}

test_local_service_data_outside_appdata_root_is_rejected() {
  _ls_expect_rejected_data '"/etc/hli2.d"' "fuera de APPDATA_ROOT" || return 1
  _ls_expect_rejected_data '"/srv"' "= /srv" || return 1
  _ls_expect_rejected_data '"/etc/ssh"' "en /etc" || return 1
  _ls_expect_rejected_data '"$APPDATA_ROOT-evil/x"' "con prefijo parecido" || return 1
}

test_local_service_data_equal_to_appdata_root_or_with_dotdot_is_rejected() {
  _ls_expect_rejected_data '"$APPDATA_ROOT"' "= APPDATA_ROOT" || return 1
  _ls_expect_rejected_data '"$APPDATA_ROOT/miapp/../../etc"' "con .." || return 1
  _ls_expect_rejected_data '"$APPDATA_ROOT/../etc/x"' "con .. al inicio" || return 1
  _ls_expect_rejected_data '"relativa/ruta"' "relativa" || return 1
  _ls_expect_rejected_data '"$APPDATA_ROOT/con espacio"' "con espacio" || return 1
}

test_local_service_invalid_fields_are_rejected() {
  local f="$HLI2_LOCAL_SERVICES_DIR/miapp.conf"
  _ls_write miapp; sed -i 's|^SERVICE_CONTAINER=.*|SERVICE_CONTAINER="a b;rm"|' "$f"
  ! _ls_listed || { fail "contenedor inválido"; return 1; }
  _ls_write miapp; sed -i 's|^SERVICE_KIND=.*|SERVICE_KIND="native"|' "$f"
  ! _ls_listed || { fail "KIND distinto de container"; return 1; }
  _ls_write miapp; sed -i 's|^SERVICE_BACKUP_KIND=.*|SERVICE_BACKUP_KIND="db-dump-dokploy"|' "$f"
  ! _ls_listed || { fail "BACKUP_KIND no permitido"; return 1; }
  _ls_write miapp; echo 'SERVICE_BACKUP_EXCLUDE=("/srv/appdata/jellyfin/config")' >> "$f"
  ! _ls_listed || { fail "exclusión de datos ajenos"; return 1; }
  _ls_write miapp; echo 'SERVICE_BACKUP_EXCLUDE=("$APPDATA_ROOT/miapp/db")' >> "$f"
  _ls_listed || { fail "excluir sus propios datos es válido"; return 1; }
}

# --- Colisiones ---------------------------------------------------------------------------

test_local_service_colliding_with_shipped_id_is_ignored_and_logged() {
  _ls_write jellyfin
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"
    echo "cnt=$(service_list | grep -cx jellyfin)"
    echo "name=$(service_get jellyfin NAME)"
    echo "data=$(service_get jellyfin DATA | head -1)"
    service_local_report ) )"
  assert_contains "$out" "cnt=1" "un solo jellyfin" || return 1
  assert_contains "$out" "name=Jellyfin" "gana el incluido" || return 1
  assert_contains "$out" "data=$APPDATA_ROOT/jellyfin/config" || return 1
  assert_contains "$out" "coincide con un servicio incluido" "el informe lo explica" || return 1
  # El backup lo deja en su log.
  _bk_prepare
  _bk_run run || { fail "el backup debió terminar bien"; return 1; }
  assert_file_contains "$LOG_DIR/backup.log" "servicio local 'jellyfin' ignorado" || return 1
}

# --- Backup -------------------------------------------------------------------------------

test_local_service_data_and_registry_dir_are_in_backup_paths() {
  _bk_prepare
  _ls_write miapp
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; _backup_collect
    printf 'full:%s\n' "${BK_PATHS[@]}"; printf 'cloud:%s\n' "${BK_CLOUD_PATHS[@]}" ) )"
  assert_contains "$out" "full:$APPDATA_ROOT/miapp/db" || return 1
  assert_contains "$out" "cloud:$APPDATA_ROOT/miapp/db" "también va a la copia externa" || return 1
  assert_contains "$out" "full:$(dirname "$HLI2_LOCAL_SERVICES_DIR")" "/etc/hli2.d viaja en el backup" || return 1
  assert_contains "$out" "cloud:$(dirname "$HLI2_LOCAL_SERVICES_DIR")" || return 1
}

test_local_service_backup_goes_in_the_same_run_and_snapshots() {
  _bk_prepare
  _ls_write miapp
  _bk_run run || { fail "el backup debió terminar bien"; return 1; }
  local full cloud
  full="$(_bk_snapshot_line full)"; cloud="$(_bk_snapshot_line cloud)"
  _bk_has_arg "$full" "$APPDATA_ROOT/miapp/db" || { fail "la foto full debe incluirlo: $full"; return 1; }
  _bk_has_arg "$cloud" "$APPDATA_ROOT/miapp/db" || { fail "la foto cloud debe incluirlo: $cloud"; return 1; }
  assert_eq "2" "$(_bk_calls '^restic\t(.*\t)?backup\t' | wc -l | tr -d ' ')" "solo dos fotos (sin backup aparte)" || return 1
}

test_local_service_of_kind_sqlite_stops_and_starts_its_container() {
  _bk_prepare
  _ls_write miapp sqlite
  _bk_run run || { fail "el backup debió terminar bien"; return 1; }
  [[ -n "$(_bk_calls '^docker\tstop\t.*\tmiapp-db-1$')" ]] || { fail "no detuvo el contenedor local"; return 1; }
  [[ -n "$(_bk_calls '^docker\tstart\tmiapp-db-1$')" ]] || { fail "no volvió a iniciar el contenedor local"; return 1; }
}

test_local_service_of_kind_files_does_not_stop_its_container() {
  _bk_prepare
  _ls_write miapp files
  _bk_run run || { fail "el backup debió terminar bien"; return 1; }
  [[ -z "$(_bk_calls '^docker\t(stop|start)\t.*miapp')" ]] || { fail "kind files no debe detener nada"; return 1; }
}

# --- Restauración (la de "todo" en equipo nuevo está en tests/test_restore.sh) ---

test_local_service_is_a_valid_restore_target_and_path_is_allowed() {
  _bk_prepare
  _ls_write miapp
  ( source "$REPO_ROOT/lib/core.sh"
    restore_valid_target miapp || exit 1
    _restore_dst_allowed "$APPDATA_ROOT/miapp/db" || exit 2
    _restore_dst_allowed "$APPDATA_ROOT/otro/db" && exit 3
    exit 0 ) || { fail "destino local no aceptado (código $?)"; return 1; }
  # Un local rechazado no es destino ni ruta permitida.
  chmod 0666 "$HLI2_LOCAL_SERVICES_DIR/miapp.conf"
  if ( source "$REPO_ROOT/lib/core.sh"; restore_valid_target miapp ); then fail "rechazado no debe ser destino"; return 1; fi
  if ( source "$REPO_ROOT/lib/core.sh"; _restore_dst_allowed "$APPDATA_ROOT/miapp/db" ); then fail "ruta de un rechazado no debe permitirse"; return 1; fi
}

# --- Dashboard ---------------------------------------------------------------------------------

test_dashboard_lists_the_local_service_with_marker() {
  _ls_write miapp
  export STUB_TEXTBOX_LOG="$HLI2_TEST_SCRATCH/textbox.log"; : > "$STUB_TEXTBOX_LOG"
  ( source "$REPO_ROOT/lib/core.sh"; source "$REPO_ROOT/ui/menu.sh"; show_dashboard ) >/dev/null 2>&1 || true
  assert_file_contains "$STUB_TEXTBOX_LOG" "Mi App (local)" "el dashboard lo muestra" || return 1
  assert_file_contains "$STUB_TEXTBOX_LOG" "Jellyfin" || return 1
}

# --- Rutas canónicas, filtro de contenido y solapes ------------------------------------------

test_service_path_ok_rejects_dot_segments_and_non_canonical_forms() {
  local p
  ( source "$REPO_ROOT/lib/core.sh"
    for p in /srv/appdata/x/y /srv/appdata/a.b/c; do _service_path_ok "$p" || { echo "debía aceptar $p"; exit 1; }; done
    for p in /srv/appdata/. /srv/appdata/x/. /srv/appdata/x/./y /srv/appdata/.. /srv/appdata/x/../y \
             /srv/appdata/x/ /srv/appdata//x /srv /./srv/x; do
      if _service_path_ok "$p"; then echo "debía rechazar $p"; exit 1; fi
    done ) || return 1
  _ls_expect_rejected_data '"$APPDATA_ROOT/."' "terminada en /." || return 1
  _ls_expect_rejected_data '"$APPDATA_ROOT/miapp/."' "terminada en /x/." || return 1
  _ls_expect_rejected_data '"$APPDATA_ROOT/miapp/"' "con barra final" || return 1
}

# Agrega la línea $1 a miapp.conf y comprueba que se rechaza sin ejecutar nada.
_ls_expect_rejected_line() {
  local line="$1" why="$2"
  _ls_write miapp
  rm -f "$HLI2_TEST_SCRATCH/pwned"
  printf '%s\n' "$line" >> "$HLI2_LOCAL_SERVICES_DIR/miapp.conf"
  ! _ls_listed || { fail "$why: debe rechazarse"; return 1; }
  [[ ! -e "$HLI2_TEST_SCRATCH/pwned" ]] || { fail "$why: se ejecutó código"; return 1; }
}

test_local_service_content_lint_rejects_anything_executable() {
  local P="$HLI2_TEST_SCRATCH/pwned"
  _ls_expect_rejected_line "touch $P" "comando suelto" || return 1
  _ls_expect_rejected_line "SERVICE_PORT=\"\$(touch $P)\"" 'sustitución $()' || return 1
  _ls_expect_rejected_line "SERVICE_PORT=\"\`touch $P\`\"" "comillas invertidas" || return 1
  _ls_expect_rejected_line "SERVICE_PORT=\"\"; touch $P" "punto y coma" || return 1
  _ls_expect_rejected_line "SERVICE_PORT=\"\" & touch $P" "ampersand" || return 1
  _ls_expect_rejected_line "SERVICE_PORT=\"\" | touch $P" "tubería" || return 1
  _ls_expect_rejected_line "SERVICE_PORT=\"\" > $P" "redirección >" || return 1
  _ls_expect_rejected_line "SERVICE_PORT=\"\" < /etc/passwd" "redirección <" || return 1
  _ls_expect_rejected_line 'SERVICE_URL_SCHEME="$HOME"' 'variable $HOME' || return 1
  _ls_expect_rejected_line 'SERVICE_URL_SCHEME="$APPDATA_ROOTx"' 'variable $APPDATA_ROOTx' || return 1
  _ls_expect_rejected_line 'SERVICE_URL_SCHEME=http' "valor sin comillas" || return 1
  _ls_expect_rejected_line 'export SERVICE_PORT=""' "línea que no es una asignación" || return 1
  _ls_expect_rejected_line 'SERVICE_URL_SCHEME="a\"b"' "barra invertida" || return 1
  # Comentarios, líneas en blanco y ${APPDATA_ROOT} sí se aceptan.
  _ls_write miapp
  printf '\n# comentario con $ y ; sin efecto\nSERVICE_BACKUP_EXCLUDE=("${APPDATA_ROOT}/miapp/db")\n' >> "$HLI2_LOCAL_SERVICES_DIR/miapp.conf"
  _ls_listed || { fail "comentarios y \${APPDATA_ROOT} deben aceptarse"; return 1; }
}

test_local_service_data_overlapping_shipped_or_system_paths_is_rejected() {
  _ls_expect_rejected_data '"$APPDATA_ROOT/jellyfin/config"' "igual a un servicio incluido" || return 1
  _ls_expect_rejected_data '"$APPDATA_ROOT/jellyfin"' "padre de datos de un servicio incluido" || return 1
  _ls_expect_rejected_data '"$APPDATA_ROOT/jellyfin/config/sub"' "dentro de datos de un servicio incluido" || return 1
  _ls_write miapp
  sed -i 's|^SERVICE_DATA=.*|SERVICE_DATA=("$APPDATA_ROOT/bk/x")|' "$HLI2_LOCAL_SERVICES_DIR/miapp.conf"
  if ( source "$REPO_ROOT/lib/core.sh"; BACKUP_ROOT="$APPDATA_ROOT/bk"; service_list | grep -qx miapp ); then
    fail "dentro de BACKUP_ROOT debe rechazarse"; return 1
  fi
  if ( source "$REPO_ROOT/lib/core.sh"; STATE_DIR="$APPDATA_ROOT/bk"; service_list | grep -qx miapp ); then
    fail "dentro de STATE_DIR debe rechazarse"; return 1
  fi
  if ( source "$REPO_ROOT/lib/core.sh"; SECRETS_DIR="$APPDATA_ROOT/bk/x"; service_list | grep -qx miapp ); then
    fail "igual a SECRETS_DIR debe rechazarse"; return 1
  fi
}

test_service_display_name_falls_back_to_the_id() {
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; service_display_name no-existe ) )"
  assert_contains "$out" "no-existe" || return 1
}

test_backup_excludes_restore_leftovers_in_the_registry_parent() {
  _bk_prepare
  _ls_write miapp
  local out reg
  reg="$(dirname "$HLI2_LOCAL_SERVICES_DIR")"
  out="$( ( source "$REPO_ROOT/lib/core.sh"; _backup_collect; printf '%s\n' "${BK_EXCLUDE_ARGS[@]}" ) )"
  assert_contains "$out" "--exclude=$reg/*.hli2-restore-tmp" || return 1
  assert_contains "$out" "--exclude=$reg/*.hli2-before-restore-*" || return 1
}
