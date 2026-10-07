#!/usr/bin/env bash
# Tests de la restauración (lib/restore.sh, subcomandos 'restore' y 'snapshots'
# de bin/hli2-backup, modules/backup-restore.sh y la recuperación ante un
# desastre de backup-setup) con restic/docker/sudo/dialog simulados. Mismo
# criterio que tests/test_backup.sh: el entrypoint corre como proceso aparte
# (para probar el trap EXIT/TERM) y como el usuario del test, con root simulado
# por el stub de 'sudo'. Los helpers de entorno vienen de tests/lib/backup_helpers.sh.

source "$TESTS_DIR/lib/backup_helpers.sh"

# Ids de fotos: el corto (8 hex) es lo que ve el usuario; el largo, lo que usa restic.
_RS_FULL_NEW="ab12cd01"
_RS_FULL_OLD="ab12cd00"
_RS_CLOUD="ab12cd02"
_rs_long() { printf '%s%s' "$1" "0123456789abcdef0123456789abcdef0123456789abcdef"; }

# Entorno de restauración: lista de fotos, contenido de las fotos (fixture), datos
# "actuales" distintos de los de la foto y una copia del código con la ruta de
# smb.conf redirigida al scratch (services/smbd.conf trae /etc/samba/smb.conf, y
# los tests nunca tocan rutas reales).
_rs_prepare() {
  _bk_prepare
  local F="$HLI2_TEST_SCRATCH/fixture" R="$HLI2_TEST_SCRATCH/fixture-r2"
  export RS_SAMBA="$HLI2_TEST_SCRATCH/etc-samba/smb.conf"
  mkdir -p "$(dirname "$RS_SAMBA")"

  cat > "$HLI2_TEST_SCRATCH/snapshots.json" <<EOF
[
 {"id":"$(_rs_long "$_RS_FULL_OLD")","short_id":"$_RS_FULL_OLD","time":"2026-10-04T04:00:00.123456789+02:00","tags":["full"],"hostname":"h1"},
 {"id":"$(_rs_long "$_RS_FULL_NEW")","short_id":"$_RS_FULL_NEW","time":"2026-10-05T04:00:12.5+02:00","tags":["full"],"hostname":"h1"},
 {"id":"$(_rs_long "$_RS_CLOUD")","short_id":"$_RS_CLOUD","time":"2026-10-05T04:00:30+02:00","tags":["cloud"],"hostname":"h1"},
 {"id":"zz","short_id":"zz","time":"2026-10-06T04:00:00+02:00","tags":["full"]},
 {"id":"$(_rs_long ab12cd03)","short_id":"ab12cd03","time":"ayer; rm -rf /","tags":["full"]}
]
EOF
  export STUB_RESTIC_SNAPSHOTS_FILE="$HLI2_TEST_SCRATCH/snapshots.json"

  # Contenido de las fotos.
  local d
  for d in vaultwarden/data jellyfin/config opencloud/config opencloud/data homeassistant/config adguard/conf adguard/work qbittorrent/config; do
    mkdir -p "$F$APPDATA_ROOT/$d" "$R$APPDATA_ROOT/$d"
    echo "snapshot-$d" > "$F$APPDATA_ROOT/$d/file.txt"
    echo "snapshot-$d" > "$R$APPDATA_ROOT/$d/file.txt"
    # Dato actual: distinto, con un archivo de más que la foto NO tiene.
    echo "current-$d" > "$APPDATA_ROOT/$d/file.txt"
    echo "extra" > "$APPDATA_ROOT/$d/extra.txt"
  done
  rm -rf "$R$APPDATA_ROOT/opencloud/data"        # R2 no lleva los archivos de OpenCloud
  mkdir -p "$F$(dirname "$RS_SAMBA")" "$R$(dirname "$RS_SAMBA")"
  echo "snapshot-smb" > "$F$RS_SAMBA"; echo "snapshot-smb" > "$R$RS_SAMBA"
  echo "current-smb" > "$RS_SAMBA"
  # La caché de Jellyfin nunca está en la foto y no se toca.
  mkdir -p "$APPDATA_ROOT/jellyfin/cache"; echo "cache" > "$APPDATA_ROOT/jellyfin/cache/c.txt"
  export STUB_RESTIC_FIXTURE="$F" STUB_RESTIC_FIXTURE_R2="$R"

  # Copia del código con smb.conf en el scratch (también la usan los módulos: el
# stub de sudo solo copia archivos que estén dentro del scratch).
  RS_CODE="$HLI2_TEST_SCRATCH/code"
  mkdir -p "$RS_CODE"/{bin,lib,services,config,modules}
  cp "$REPO_ROOT"/modules/*.sh "$RS_CODE/modules/"
  cp "$REPO_ROOT/bin/hli2-backup" "$RS_CODE/bin/"
  cp "$REPO_ROOT"/lib/*.sh "$RS_CODE/lib/"
  cp "$REPO_ROOT"/services/*.conf "$RS_CODE/services/"
  cp "$REPO_ROOT/config/default.conf" "$RS_CODE/config/"
  local conf
  conf="$(<"$RS_CODE/services/smbd.conf")"
  printf '%s\n' "${conf//\/etc\/samba\/smb.conf/$RS_SAMBA}" > "$RS_CODE/services/smbd.conf"
}

_rs_run() { bash "$RS_CODE/bin/hli2-backup" "$@"; }
_rs_status() { grep "^$1=" "$BACKUP_STATE_DIR/restore-status" | head -1 | cut -d= -f2-; }
_rs_content() { cat "$1" 2>/dev/null || echo "<no existe>"; }

# Contenido de un archivo del área root-only simulada (destraba y vuelve a trabar).
_rs_secret() {
  local v
  chmod u+rwx "$SECRETS_DIR"
  v="$(cat "$SECRETS_DIR/$1" 2>/dev/null || echo "<no existe>")"
  chmod 000 "$SECRETS_DIR"
  printf '%s' "$v"
}
_rs_secret_exists() {
  local rc=0
  chmod u+rwx "$SECRETS_DIR"
  [[ -e "$SECRETS_DIR/$1" ]] || rc=1
  chmod 000 "$SECRETS_DIR"
  return "$rc"
}

_rs_secret_has_old() {
  local rc=1 f
  chmod u+rwx "$SECRETS_DIR"
  for f in "$SECRETS_DIR/$1".hli2-before-restore-*; do [[ -e "$f" ]] && rc=0; done
  chmod 000 "$SECRETS_DIR"
  return "$rc"
}

# Secretos "actuales" del sistema y los distintos que trae la foto.
_rs_secrets() {
  local F="$HLI2_TEST_SCRATCH/fixture" R="$HLI2_TEST_SCRATCH/fixture-r2" base
  _bk_r2
  _bk_root_write vaultwarden.env "VW=OLD"
  for base in "$F" "$R"; do
    mkdir -p "$base$SECRETS_DIR/sub"
    echo "VW=FROM-SNAPSHOT" > "$base$SECRETS_DIR/vaultwarden.env"
    echo "RESTIC=FROM-SNAPSHOT" > "$base$SECRETS_DIR/restic.env"
    echo "DOKPLOY=FROM-SNAPSHOT" > "$base$SECRETS_DIR/dokploy.env"
    echo "PW=FROM-SNAPSHOT" > "$base$SECRETS_DIR/restic-password"
    echo "STAGE=1" > "$base$SECRETS_DIR/.restic-password.123"
    echo "notas" > "$base$SECRETS_DIR/notes.txt"
    echo "x" > "$base$SECRETS_DIR/sub/a.env"
  done
}

# Copias previas '<ruta>.hli2-before-restore-*' (una por línea).
_rs_olds() { local f; for f in "$1".hli2-before-restore-*; do [[ -e "$f" ]] && echo "$f"; done; return 0; }

_rs_no_privileged_calls() {
  [[ -z "$(_bk_calls '^(docker|restic)\t')" ]] || { fail "no debió tocar docker ni restic"; return 1; }
  [[ -z "$(_bk_calls '^sudo\t(-n\t)?(mv|rm|mkdir)\t')" ]] || { fail "no debió modificar el disco"; return 1; }
}

# --- Validación de argumentos (vienen del usuario y llegan a root) --------------------------

test_restore_rejects_malformed_arguments_without_touching_anything() {
  _rs_prepare
  local ok_id="$_RS_FULL_NEW" rc args
  local -a cases=(
    "--source local --snapshot $ok_id --target ../x"
    "--source local --snapshot $ok_id --target vaultwarden;id"
    "--source local --snapshot $ok_id --target /etc/hli2"
    "--source local --snapshot $ok_id --target tailscale"
    "--source local --snapshot $ok_id --target dokploy"
    "--source local --snapshot $ok_id --target nope"
    "--source local --snapshot $ok_id --target ALL"
    "--source local --snapshot --force --target all"
    "--source local --snapshot latest --target all"
    "--source local --snapshot ABCDEF01 --target all"
    "--source local --snapshot abc --target all"
    "--source local --snapshot ab12cd01/../x --target all"
    "--source local --snapshot g1234567 --target all"
    "--source s3 --snapshot $ok_id --target all"
    "--source local;ls --snapshot $ok_id --target all"
    "--source local --snapshot $ok_id"
    "--snapshot $ok_id --target all"
    "--source local --snapshot $ok_id --target"
    "--source local --source r2 --snapshot $ok_id --target all"
    "--source local --snapshot $ok_id --target all --delete"
    "--source=local --snapshot $ok_id --target all"
    ""
  )
  for args in "${cases[@]}"; do
    rc=0
    # shellcheck disable=SC2086
    _rs_run restore $args >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 2 ]] || { fail "debió rechazarse con código 2 (rc=$rc): [$args]"; return 1; }
  done
  # Con comillas: un valor con espacios o con una opción dentro viaja como UN argumento.
  for args in "ab12cd01 --foo" "ab12cd01 " " ab12cd01" $'ab12cd01\nrm'; do
    rc=0
    _rs_run restore --source local --snapshot "$args" --target all >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 2 ]] || { fail "snapshot con espacios/opciones debió rechazarse: [$args] rc=$rc"; return 1; }
  done
  rc=0
  _rs_run restore --source local --snapshot "$ok_id" --target "vaultwarden --force" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] || { fail "target con una opción dentro debió rechazarse"; return 1; }
  _rs_no_privileged_calls || return 1
}

test_restore_snapshots_subcommand_validates_source() {
  _rs_prepare
  local rc
  for args in "--source ../x" "--source s3" "" "--source" "--source local extra" "--tag full"; do
    rc=0
    # shellcheck disable=SC2086
    _rs_run snapshots $args >/dev/null 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]] || { fail "debió rechazarse: [$args]"; return 1; }
  done
  _rs_no_privileged_calls || return 1
}

test_backup_run_rejects_unknown_flags_and_no_retention_skips_forget() {
  _bk_prepare
  _bk_r2
  local rc=0
  _bk_run run --bogus >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] || { fail "run --bogus debió dar 2 (rc=$rc)"; return 1; }
  [[ -z "$(_bk_calls '^(docker|restic)\t')" ]] || { fail "no debió tocar nada"; return 1; }
  _bk_run run --no-retention || { fail "run --no-retention falló"; return 1; }
  [[ -z "$(_bk_calls '^restic\t(.*\t)?forget\t')" ]] || { fail "--no-retention no debe borrar fotos"; return 1; }
  [[ -n "$(_bk_calls '^restic\t(.*\t)?copy\t')" ]] || { fail "la copia a R2 sí se hace"; return 1; }
  assert_eq "ok" "$(_bk_status result)" || return 1
}

# --- Lista de fotos --------------------------------------------------------------------------------

test_restore_snapshots_lists_newest_first_for_the_right_tag() {
  _rs_prepare
  local out
  out="$(_rs_run snapshots --source local)" || { fail "snapshots local falló"; return 1; }
  assert_eq "2" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "solo las fotos 'full' válidas" || return 1
  assert_eq "$_RS_FULL_NEW" "$(printf '%s\n' "$out" | sed -n 1p | cut -f1)" "la más nueva primero" || return 1
  assert_eq "$_RS_FULL_OLD" "$(printf '%s\n' "$out" | sed -n 2p | cut -f1)" || return 1
  assert_contains "$out" "2026-10-05T04:00:12.5+02:00" "fecha completa para que el módulo la formatee" || return 1
  assert_not_contains "$out" "$_RS_CLOUD" "las fotos cloud no se ofrecen en la copia local" || return 1
  assert_not_contains "$out" "rm -rf" "fechas sin la forma esperada se descartan" || return 1
  [[ -n "$(_bk_calls '^restic\t(.*\t)?snapshots\t.*--tag\tfull')" ]] || { fail "debió pedir el tag full"; return 1; }
  # Sin tocar el log ni el estado: la lista sale solo por stdout.
  [[ ! -s "$LOG_DIR/backup.log" ]] || { fail "snapshots no debe escribir en el log: $(cat "$LOG_DIR/backup.log")"; return 1; }
}

test_restore_snapshots_from_r2_uses_cloud_tag_and_env_credentials() {
  _rs_prepare
  _bk_r2
  local out
  out="$(_rs_run snapshots --source r2)" || { fail "snapshots r2 falló"; return 1; }
  assert_eq "$_RS_CLOUD" "$(printf '%s' "$out" | cut -f1)" || return 1
  [[ -n "$(_bk_calls '^restic\t(.*\t)?snapshots\t.*--tag\tcloud')" ]] || { fail "debió pedir el tag cloud"; return 1; }
  assert_contains "$(_bk_calls '^restic-env\t')" "REPO=s3:https://${_BK_ACCOUNT}.r2.cloudflarestorage.com/bkt" || return 1
  assert_not_contains "$(cat "$STUB_CALL_LOG")" "$_BK_SECRET_VAL" "el secreto de R2 nunca va en argv" || return 1
}

test_restore_snapshots_from_r2_requires_r2_configured() {
  _rs_prepare
  if _rs_run snapshots --source r2 >/dev/null 2>&1; then fail "debió fallar sin R2 configurado"; return 1; fi
}

# --- Restauración de un servicio ----------------------------------------------------------------

test_restore_service_replaces_data_exactly_and_restarts_container() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data" olds
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden || { fail "la restauración debió terminar bien"; return 1; }

  assert_eq "snapshot-vaultwarden/data" "$(_rs_content "$d/file.txt")" "datos de la foto" || return 1
  [[ ! -e "$d/extra.txt" ]] || { fail "la carpeta debe quedar IDÉNTICA a la foto (no una mezcla)"; return 1; }
  [[ ! -e "$d.hli2-restore-tmp" ]] || { fail "quedó la carpeta de paso"; return 1; }
  olds="$(_rs_olds "$d")"
  assert_eq "1" "$(printf '%s' "$olds" | grep -c .)" "una copia previa conservada" || return 1
  assert_eq "current-vaultwarden/data" "$(_rs_content "$(printf '%s\n' "$olds" | head -1)/file.txt")" || return 1
  [[ -f "$(printf '%s\n' "$olds" | head -1)/extra.txt" ]] || { fail "la copia previa conserva lo anterior"; return 1; }
  # Otros servicios, intactos.
  assert_eq "current-jellyfin/config" "$(_rs_content "$APPDATA_ROOT/jellyfin/config/file.txt")" || return 1

  # Restic: foto verificada con su tag y restaurada con el id completo, a la carpeta de paso.
  local snap restore
  snap="$(_bk_calls '^restic\t(.*\t)?snapshots\t')"
  _bk_has_arg "$snap" "--tag" && _bk_has_arg "$snap" "full" && _bk_has_arg "$snap" "$_RS_FULL_NEW" || { fail "no verificó la foto con su tag: $snap"; return 1; }
  restore="$(_bk_calls '^restic\t(.*\t)?restore\t')"
  _bk_has_arg "$restore" "$(_rs_long "$_RS_FULL_NEW")" || { fail "debió usar el id completo: $restore"; return 1; }
  _bk_has_arg "$restore" "--target" && _bk_has_arg "$restore" "$d.hli2-restore-tmp" || { fail "debió restaurar a la carpeta de paso: $restore"; return 1; }
  _bk_has_arg "$restore" "--include" && _bk_has_arg "$restore" "$d" || { fail "debió incluir la ruta del servicio: $restore"; return 1; }
  assert_eq "1" "$(_bk_calls '^restic\t(.*\t)?restore\t' | wc -l | tr -d ' ')" || return 1

  # Contenedor: detenido antes de restaurar (con la lista de recuperación ya escrita) y levantado después.
  local stop rest start
  stop="$(_bk_line_no '^docker\tstop\t.*vaultwarden$')"
  rest="$(_bk_line_no '^restic\t(.*\t)?restore\t')"
  start="$(_bk_line_no '^docker\tstart\tvaultwarden$')"
  [[ -n "$stop" && -n "$rest" && -n "$start" ]] || { fail "faltan llamadas (stop=$stop restore=$rest start=$start)"; return 1; }
  (( stop < rest && rest < start )) || { fail "orden incorrecto: stop=$stop restore=$rest start=$start"; return 1; }
  assert_contains "$(_bk_calls '^recovery-at-stop\t')" "yes" "la lista de recuperación existía al detener" || return 1
  [[ ! -s "$BACKUP_STATE_DIR/recovery-containers" ]] || { fail "la lista de recuperación no se limpió"; return 1; }
  [[ -z "$(_bk_calls '^docker\t(stop|start)\t.*(jellyfin|adguard|homeassistant|opencloud|qbittorrent)')" ]] || { fail "solo debe tocar el contenedor del servicio"; return 1; }

  assert_eq "ok" "$(_rs_status result)" || return 1
  assert_eq "$_RS_FULL_NEW" "$(_rs_status snapshot)" || return 1
  assert_eq "vaultwarden" "$(_rs_status target)" || return 1
  assert_eq "local" "$(_rs_status source)" || return 1
  assert_contains "$(_rs_status snapshot_time)" "2026-10-05T04:00:12.5" || return 1
  assert_contains "$(_rs_status message)" "hli2-before-restore" "avisa dónde quedó lo anterior" || return 1
  assert_eq "644" "$(stat -c %a "$BACKUP_STATE_DIR/restore-status")" "estado legible por el usuario" || return 1
  assert_contains "$(cat "$LOG_DIR/backup.log")" "Fin de la restauración: ok" "queda en el log del backup" || return 1
}

test_restore_keeps_only_the_last_before_restore_copy() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data" n
  mkdir -p "$d.hli2-before-restore-20200101-000000"
  echo "muy vieja" > "$d.hli2-before-restore-20200101-000000/file.txt"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden || return 1
  n="$(_rs_olds "$d" | grep -c .)"
  assert_eq "1" "$n" "se conserva solo la última copia previa" || return 1
  [[ ! -e "$d.hli2-before-restore-20200101-000000" ]] || { fail "la copia anterior debió borrarse"; return 1; }
}

test_restore_discard_old_removes_the_previous_copy() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden --discard-old || return 1
  assert_eq "" "$(_rs_olds "$d")" "con --discard-old no queda copia previa" || return 1
  assert_eq "snapshot-vaultwarden/data" "$(_rs_content "$d/file.txt")" || return 1
}

test_restore_service_that_does_not_exist_yet_restores_data_for_a_new_machine() {
  _rs_prepare
  rm -rf "$APPDATA_ROOT/vaultwarden"        # equipo nuevo: ni la carpeta del servicio
  export STUB_DOCKER_NOT_FOUND="vaultwarden"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden || { fail "debió restaurar los datos"; return 1; }
  assert_eq "snapshot-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
  [[ -z "$(_bk_calls '^docker\t(stop|start)\t')" ]] || { fail "no hay contenedor que detener ni iniciar"; return 1; }
  assert_eq "vaultwarden" "$(_rs_status modules)" "avisa qué módulo ejecutar" || return 1
  assert_eq "warning" "$(_rs_status result)" || return 1
  assert_contains "$(_rs_status message)" "faltan contenedores" || return 1
}

test_restore_without_docker_restores_data_and_asks_for_dokploy() {
  _rs_prepare
  local out
  out="$( (
    source "$REPO_ROOT/lib/core.sh"
    hli_docker_presence() { echo absent; }
    RS_TARGET=all RS_MODULES=""
    _restore_stop_containers
    echo "rc=$? modules=$RS_MODULES"
  ) )"
  assert_contains "$out" "rc=0" || return 1
  assert_contains "$out" "modules=dokploy adguard" "Dokploy primero, luego los servicios" || return 1
  assert_contains "$out" "opencloud" || return 1
  out="$( (
    source "$REPO_ROOT/lib/core.sh"
    hli_docker_presence() { echo unknown; }
    RS_TARGET=all RS_MODULES=""
    _restore_stop_containers && echo "rc=0" || echo "rc=1"
  ) )"
  assert_contains "$out" "rc=1" "con un estado de Docker incierto no se restaura (falla cerrado)" || return 1
  [[ -z "$(_bk_calls '^docker\tstop\t')" ]] || { fail "no debió detener nada"; return 1; }
}

test_restore_docker_state_error_aborts_before_touching_data() {
  _rs_prepare
  export STUB_DOCKER_INSPECT_ERROR="vaultwarden"
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden; then fail "debió abortar"; return 1; fi
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?restore\t')" ]] || { fail "no debió restaurar"; return 1; }
  assert_eq "error" "$(_rs_status result)" || return 1
}

test_restore_container_that_wont_stop_aborts_and_restarts_the_rest() {
  _rs_prepare
  export STUB_DOCKER_FAIL_STOP="jellyfin"
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target all; then fail "debió abortar"; return 1; fi
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" "nada restaurado" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?restore\t')" ]] || { fail "no debió restaurar con un contenedor sin detener"; return 1; }
  local c
  # Se detuvieron (en orden) adguard, homeassistant y jellyfin (falla): esos vuelven.
  for c in adguard homeassistant jellyfin; do
    [[ -n "$(_bk_calls "^docker\tstart\t$c\$")" ]] || { fail "no reinició $c"; return 1; }
  done
  for c in opencloud qbittorrent vaultwarden; do
    [[ -z "$(_bk_calls "^docker\tstart\t$c\$")" ]] || { fail "$c nunca se detuvo: no hay que iniciarlo"; return 1; }
  done
  assert_eq "error" "$(_rs_status result)" || return 1
}

# --- Seguridad ante fallos: nada a medio escribir ---------------------------------------------------

test_restore_restic_failure_leaves_original_intact_and_restarts() {
  _rs_prepare
  export STUB_RESTIC_FAIL="restore"
  local d="$APPDATA_ROOT/vaultwarden/data"
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden; then fail "debió fallar"; return 1; fi
  assert_eq "current-vaultwarden/data" "$(_rs_content "$d/file.txt")" "datos originales" || return 1
  [[ -f "$d/extra.txt" ]] || { fail "el dato original debe seguir completo"; return 1; }
  [[ ! -e "$d.hli2-restore-tmp" ]] || { fail "quedó la carpeta de paso"; return 1; }
  assert_eq "" "$(_rs_olds "$d")" "no se apartó nada" || return 1
  [[ -n "$(_bk_calls '^docker\tstart\tvaultwarden$')" ]] || { fail "el contenedor debe volver a iniciar"; return 1; }
  assert_eq "error" "$(_rs_status result)" || return 1
  assert_contains "$(_rs_status message)" "vaultwarden" || return 1
}

test_restore_swap_failure_rolls_back_and_keeps_original() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data"
  export STUB_SUDO_MV_FAIL_TARGET="$d"      # falla (una vez) el 'mv' que coloca lo restaurado
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden; then fail "debió fallar"; return 1; fi
  assert_eq "current-vaultwarden/data" "$(_rs_content "$d/file.txt")" "se devolvió lo original" || return 1
  [[ -f "$d/extra.txt" ]] || { fail "el dato original debe seguir completo"; return 1; }
  [[ ! -e "$d.hli2-restore-tmp" ]] || { fail "quedó la carpeta de paso"; return 1; }
  assert_eq "" "$(_rs_olds "$d")" "no queda una copia previa huérfana" || return 1
  [[ -n "$(_bk_calls '^docker\tstart\tvaultwarden$')" ]] || { fail "el contenedor debe volver a iniciar"; return 1; }
  assert_eq "error" "$(_rs_status result)" || return 1
}

test_restore_service_with_several_paths_is_all_or_nothing() {
  _rs_prepare
  local c="$APPDATA_ROOT/adguard/conf" w="$APPDATA_ROOT/adguard/work"
  export STUB_SUDO_MV_FAIL_TARGET="$w"      # la 2.ª ruta falla al intercambiar
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target adguard; then fail "debió fallar"; return 1; fi
  assert_eq "current-adguard/conf" "$(_rs_content "$c/file.txt")" "la 1.ª ruta se deshizo" || return 1
  assert_eq "current-adguard/work" "$(_rs_content "$w/file.txt")" "la 2.ª ruta sigue intacta" || return 1
  assert_eq "" "$(_rs_olds "$c")$(_rs_olds "$w")" "sin copias previas huérfanas" || return 1
  [[ ! -e "$c.hli2-restore-tmp" && ! -e "$w.hli2-restore-tmp" ]] || { fail "quedaron carpetas de paso"; return 1; }
  [[ -n "$(_bk_calls '^docker\tstart\tadguard$')" ]] || { fail "AdGuard (el DNS) debe volver a iniciar"; return 1; }
}

test_restore_interrupted_restarts_containers_and_keeps_original() {
  _rs_prepare
  export STUB_RESTIC_KILL_ON="restore"
  local d="$APPDATA_ROOT/vaultwarden/data"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden || true
  assert_eq "current-vaultwarden/data" "$(_rs_content "$d/file.txt")" || return 1
  [[ ! -e "$d.hli2-restore-tmp" ]] || { fail "quedó la carpeta de paso"; return 1; }
  assert_eq "" "$(rg --files "$STUB_DOCKER_STATE_DIR" 2>/dev/null | rg -v '/\.' || true)" "ningún contenedor quedó detenido" || return 1
  assert_eq "interrupted" "$(_rs_status result)" || return 1
}

test_restore_second_signal_does_not_abort_restart() {
  _rs_prepare
  export STUB_RESTIC_KILL_ON="restore" STUB_DOCKER_KILL_ON_START=1
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target all || true
  [[ -f "$STUB_DOCKER_STATE_DIR/.killed" ]] || { fail "no se envió la segunda señal (test vacío)"; return 1; }
  assert_eq "" "$(rg --files "$STUB_DOCKER_STATE_DIR" 2>/dev/null | rg -v '/\.' || true)" "ningún contenedor quedó detenido" || return 1
  assert_eq "6" "$(_bk_calls '^docker\tstart\t' | wc -l | tr -d ' ')" "los 6 contenedores con datos volvieron a iniciar" || return 1
}

test_restore_leftover_recovery_list_is_recovered_before_restoring() {
  _rs_prepare
  : > "$STUB_DOCKER_STATE_DIR/adguard.stopped"
  printf 'adguard\n' > "$BACKUP_STATE_DIR/recovery-containers"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden || return 1
  local rec rest
  rec="$(_bk_line_no '^docker\tstart\tadguard$')"
  rest="$(_bk_line_no '^restic\t(.*\t)?restore\t')"
  [[ -n "$rec" ]] || { fail "no recuperó adguard"; return 1; }
  (( rec < rest )) || { fail "debió recuperar antes de restaurar"; return 1; }
  [[ ! -s "$BACKUP_STATE_DIR/recovery-containers" ]] || { fail "la lista debió quedar vacía"; return 1; }
}

test_restore_concurrent_run_is_refused_without_touching_anything() {
  _rs_prepare
  flock "$BACKUP_STATE_DIR/lock" sleep 5 &
  local holder=$!
  sleep 0.3
  local rc=0
  HLI2_BACKUP_LOCK_WAIT=1 _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden || rc=$?
  kill "$holder" 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || { fail "debió negarse con otro proceso en curso"; return 1; }
  _rs_no_privileged_calls || return 1
  assert_eq "error" "$(_rs_status result)" "deja rastro en el estado" || return 1
  assert_contains "$(_rs_status message)" "bloqueo" || return 1
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
}

test_restore_recover_marks_a_dead_restore_as_interrupted() {
  _rs_prepare
  printf 'timestamp=%s\nresult=running\nsource=local\nsnapshot=%s\nsnapshot_time=\ntarget=all\nmodules=\nmessage=\n' "$(date -Is)" "$_RS_FULL_NEW" > "$BACKUP_STATE_DIR/restore-status"
  _rs_run recover || return 1
  assert_eq "interrupted" "$(_rs_status result)" || return 1
}

# --- Foto: verificación y origen ----------------------------------------------------------------------

test_restore_refuses_a_snapshot_of_the_wrong_kind_or_missing() {
  _rs_prepare
  local id
  # La foto 'cloud' no es de la copia local, y 'deadbeef' no existe.
  for id in "$_RS_CLOUD" deadbeef; do
    : > "$STUB_CALL_LOG"
    if _rs_run restore --source local --snapshot "$id" --target vaultwarden; then fail "debió rechazar $id"; return 1; fi
    [[ -z "$(_bk_calls '^restic\t(.*\t)?restore\t')" ]] || { fail "no debió restaurar $id"; return 1; }
    [[ -z "$(_bk_calls '^docker\tstop\t')" ]] || { fail "no debió detener nada ($id)"; return 1; }
    assert_eq "error" "$(_rs_status result)" || return 1
  done
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
}

test_restore_from_r2_skips_opencloud_files_and_says_so() {
  _rs_prepare
  _bk_r2
  local oc="$APPDATA_ROOT/opencloud" restore
  _rs_run restore --source r2 --snapshot "$_RS_CLOUD" --target opencloud || { fail "debió terminar (con aviso)"; return 1; }
  # Solo la configuración se restauró; los archivos ni se piden ni se tocan.
  assert_eq "snapshot-opencloud/config" "$(_rs_content "$oc/config/file.txt")" || return 1
  assert_eq "current-opencloud/data" "$(_rs_content "$oc/data/file.txt")" "los archivos de OpenCloud no se tocan" || return 1
  [[ -f "$oc/data/extra.txt" ]] || { fail "los archivos de OpenCloud deben seguir completos"; return 1; }
  assert_eq "" "$(_rs_olds "$oc/data")" || return 1
  restore="$(_bk_calls '^restic\t(.*\t)?restore\t')"
  _bk_has_arg "$restore" "$oc/config" || { fail "debió pedir la configuración"; return 1; }
  assert_not_contains "$restore" "$oc/data" "nunca pide opencloud/data a R2" || return 1
  assert_eq "warning" "$(_rs_status result)" || return 1
  assert_contains "$(_rs_status message)" "solo existe en la copia local" "lo dice con claridad" || return 1
  # Credenciales de R2: por entorno, nunca en argv ni en logs.
  assert_contains "$(_bk_calls '^restic-env\t')" "REPO=s3:https://${_BK_ACCOUNT}.r2.cloudflarestorage.com/bkt" || return 1
  assert_not_contains "$(cat "$STUB_CALL_LOG")" "$_BK_SECRET_VAL" || return 1
  assert_not_contains "$(cat "$LOG_DIR/backup.log")" "$_BK_SECRET_VAL" || return 1
  assert_not_contains "$(cat "$BACKUP_STATE_DIR/restore-status")" "$_BK_SECRET_VAL" || return 1
  [[ -n "$(_bk_calls '^restic\t(.*\t)?snapshots\t.*--tag\tcloud')" ]] || { fail "R2 se verifica con el tag cloud"; return 1; }
}

test_restore_from_local_restores_opencloud_files() {
  _rs_prepare
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target opencloud || return 1
  assert_eq "snapshot-opencloud/data" "$(_rs_content "$APPDATA_ROOT/opencloud/data/file.txt")" || return 1
  assert_eq "snapshot-opencloud/config" "$(_rs_content "$APPDATA_ROOT/opencloud/config/file.txt")" || return 1
  assert_eq "ok" "$(_rs_status result)" || return 1
}

test_restore_cache_excluded_paths_are_never_requested() {
  _rs_prepare
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target jellyfin || return 1
  assert_not_contains "$(_bk_calls '^restic\t(.*\t)?restore\t')" "jellyfin/cache" || return 1
  assert_eq "cache" "$(_rs_content "$APPDATA_ROOT/jellyfin/cache/c.txt")" "la caché no se toca" || return 1
  assert_eq "snapshot-jellyfin/config" "$(_rs_content "$APPDATA_ROOT/jellyfin/config/file.txt")" || return 1
}

test_restore_service_missing_from_snapshot_is_an_error_and_leaves_data() {
  _rs_prepare
  rm -rf "${STUB_RESTIC_FIXTURE:?}$APPDATA_ROOT/qbittorrent"
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target qbittorrent; then fail "debió fallar: la foto no tiene datos"; return 1; fi
  assert_eq "current-qbittorrent/config" "$(_rs_content "$APPDATA_ROOT/qbittorrent/config/file.txt")" "no se borra lo actual" || return 1
  assert_contains "$(_rs_status message)" "no contiene datos" || return 1
  [[ -n "$(_bk_calls '^docker\tstart\tqbittorrent$')" ]] || { fail "el contenedor debe volver a iniciar"; return 1; }
}

# --- "Todo" ------------------------------------------------------------------------------------------------

test_restore_all_restores_services_and_secrets_but_not_restic_credentials() {
  _rs_prepare
  _rs_secrets
  export STUB_DOCKER_NOT_FOUND="jellyfin"        # equipo nuevo: este contenedor todavía no existe
  local pw_before
  pw_before="$(_rs_secret restic-password)"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target all || { fail "la restauración de todo debió terminar"; return 1; }

  # Servicios (incluidos los archivos de OpenCloud, que sí están en la foto local).
  local d
  for d in vaultwarden/data jellyfin/config opencloud/config opencloud/data homeassistant/config adguard/conf adguard/work qbittorrent/config; do
    assert_eq "snapshot-$d" "$(_rs_content "$APPDATA_ROOT/$d/file.txt")" "servicio $d" || return 1
    [[ ! -e "$APPDATA_ROOT/$d/extra.txt" ]] || { fail "$d debe quedar idéntica a la foto"; return 1; }
  done
  assert_eq "cache" "$(_rs_content "$APPDATA_ROOT/jellyfin/cache/c.txt")" "la caché no se toca" || return 1
  assert_eq "snapshot-smb" "$(_rs_content "$RS_SAMBA")" "smb.conf restaurado" || return 1
  [[ -n "$(_bk_calls '^sudo\t(-n\t)?systemctl\ttry-restart\tsmbd$')" ]] || { fail "debió reiniciar la unidad smbd"; return 1; }

  # Secretos: los de los servicios sí; restic-password, restic.env y dokploy.env, no.
  assert_eq "VW=FROM-SNAPSHOT" "$(_rs_secret vaultwarden.env)" "los secretos de los servicios se restauran" || return 1
  assert_eq "RESTIC_REPOSITORY=s3:https://${_BK_ACCOUNT}.r2.cloudflarestorage.com/bkt" "$(_rs_secret restic.env | head -1)" "restic.env del sistema no se pisa" || return 1
  assert_eq "$pw_before" "$(_rs_secret restic-password)" "restic-password no se toca" || return 1
  assert_eq "DOKPLOY_URL=http://test-dokploy:3000" "$(_rs_secret dokploy.env | head -1)" "dokploy.env del sistema no se pisa" || return 1
  _rs_secret_exists notes.txt && { fail "solo se restauran '<servicio>.env'"; return 1; }
  _rs_secret_exists .restic-password.123 && { fail "los temporales de la contraseña no se restauran"; return 1; }
  _rs_secret_exists sub && { fail "las subcarpetas no se restauran"; return 1; }
  _rs_secret_has_old vaultwarden.env || { fail "debió quedar copia previa de vaultwarden.env"; return 1; }
  [[ ! -e "$SECRETS_DIR.hli2-restore-tmp" ]] || { fail "quedó la carpeta de paso de /etc/hli2"; return 1; }

  # Contenedores existentes: detenidos y levantados; el que no existe, ni tocado y avisado.
  local c
  for c in adguard homeassistant opencloud qbittorrent vaultwarden; do
    [[ -n "$(_bk_calls "^docker\tstop\t.*\t$c\$")" && -n "$(_bk_calls "^docker\tstart\t$c\$")" ]] || { fail "$c debió detenerse y volver a iniciar"; return 1; }
  done
  [[ -z "$(_bk_calls '^docker\t(stop|start)\t.*jellyfin')" ]] || { fail "jellyfin no existe: no se toca"; return 1; }
  assert_eq "jellyfin" "$(_rs_status modules)" "avisa qué módulo falta" || return 1
  assert_eq "warning" "$(_rs_status result)" || return 1
  assert_not_contains "$(cat "$STUB_CALL_LOG")" "FROM-SNAPSHOT" "ningún secreto por argv" || return 1
  assert_not_contains "$(cat "$LOG_DIR/backup.log" "$BACKUP_STATE_DIR/restore-status")" "FROM-SNAPSHOT" "ningún secreto en logs ni estado" || return 1
}

test_restore_all_with_restic_env_flag_restores_restic_env_too() {
  _rs_prepare
  _rs_secrets
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target all --with-restic-env || return 1
  assert_eq "RESTIC=FROM-SNAPSHOT" "$(_rs_secret restic.env)" "con el pedido explícito, restic.env se restaura" || return 1
  assert_eq "DOKPLOY_URL=http://test-dokploy:3000" "$(_rs_secret dokploy.env | head -1)" "dokploy.env sigue sin tocarse" || return 1
  assert_eq "test-restic-password-123" "$(_rs_secret restic-password)" "restic-password nunca se toca" || return 1
}

test_restore_all_from_r2_leaves_opencloud_files_alone() {
  _rs_prepare
  _rs_secrets
  _rs_run restore --source r2 --snapshot "$_RS_CLOUD" --target all || { fail "debió terminar (con aviso)"; return 1; }
  assert_eq "snapshot-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
  assert_eq "current-opencloud/data" "$(_rs_content "$APPDATA_ROOT/opencloud/data/file.txt")" "los archivos de OpenCloud no están en R2 y no se tocan" || return 1
  assert_not_contains "$(_bk_calls '^restic\t(.*\t)?restore\t')" "$APPDATA_ROOT/opencloud/data" || return 1
  assert_contains "$(_rs_status message)" "solo existe en la copia local" || return 1
}

test_restore_unit_failure_for_native_service_is_a_warning() {
  _rs_prepare
  export STUB_SYSTEMCTL_FAIL="try-restart"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target smbd || { fail "un servicio sin instalar no es un error"; return 1; }
  assert_eq "snapshot-smb" "$(_rs_content "$RS_SAMBA")" || return 1
  assert_eq "warning" "$(_rs_status result)" || return 1
  assert_eq "samba" "$(_rs_status modules)" || return 1
}

# --- Módulo interactivo (modules/backup-restore.sh) ------------------------------------------------

_rs_module_env() {
  _rs_prepare
  export STUB_SUDO_RUN_ENTRYPOINT="snapshots restore run"
}

_rs_sudo_calls() { _bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\t"; }

test_restore_module_is_registered_as_a_tool() {
  local mods
  mods="$( ( source "$REPO_ROOT/lib/core.sh"; list_modules ) )"
  assert_contains "$mods" "backup-restore" || return 1
  assert_eq "tool" "$( ( source "$REPO_ROOT/lib/core.sh"; module_meta backup-restore TIPO ) )" || return 1
  assert_eq "no" "$( ( source "$REPO_ROOT/lib/core.sh"; module_meta backup-restore DEFAULT ) )" || return 1
}

test_restore_module_requires_setup() {
  _rs_module_env
  chmod u+rwx "$SECRETS_DIR"; rm -f "$SECRETS_DIR/restic-password"; chmod 000 "$SECRETS_DIR"
  if bash "$RS_CODE/modules/backup-restore.sh" </dev/null; then fail "debió pedir backup-setup primero"; return 1; fi
  assert_contains "$(_bk_calls '^dialog\t')" "backup-setup" || return 1
  [[ -z "$(_rs_sudo_calls)" ]] || { fail "no debió llamar a root"; return 1; }
}

test_restore_module_runs_safety_backup_first_then_restores() {
  _rs_module_env
  printf '%s\nvaultwarden\n' "$_RS_FULL_NEW" > "$DIALOG_MENU_QUEUE"
  printf 'yes\nyes\n' > "$DIALOG_YESNO_QUEUE"          # confirmar el resumen / hacer el backup de seguridad
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || { fail "el módulo falló"; return 1; }

  local calls snap run rest
  calls="$(_rs_sudo_calls)"
  snap="$(_bk_line_no "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\tsnapshots\t--source\tlocal\$")"
  run="$(_bk_line_no "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\trun\t--no-retention\$")"
  rest="$(_bk_line_no "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\trestore\t--source\tlocal\t--snapshot\t$_RS_FULL_NEW\t--target\tvaultwarden\t--discard-old\$")"
  [[ -n "$snap" && -n "$run" && -n "$rest" ]] || { fail "faltan llamadas a root: $calls"; return 1; }
  (( snap < run && run < rest )) || { fail "orden incorrecto: snapshots=$snap run=$run restore=$rest"; return 1; }
  # La retención no corre en el backup de seguridad (podría borrar la foto elegida).
  [[ -z "$(_bk_calls '^restic\t(.*\t)?forget\t')" ]] || { fail "el backup de seguridad no debe aplicar retención"; return 1; }
  assert_eq "snapshot-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
  assert_eq "" "$(_rs_olds "$APPDATA_ROOT/vaultwarden/data")" "con backup de seguridad no queda copia previa en disco" || return 1
  assert_contains "$(_bk_calls '^dialog\t')" "Restauración terminada" || return 1
  # El usuario ve la fecha legible y el id.
  assert_contains "$(_bk_calls '^dialog\t')" "$_RS_FULL_NEW" || return 1
}

test_restore_module_without_safety_backup_keeps_previous_copy() {
  _rs_module_env
  printf '%s\nvaultwarden\n' "$_RS_FULL_NEW" > "$DIALOG_MENU_QUEUE"
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"           # confirmar / NO hacer el backup de seguridad
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || { fail "el módulo falló"; return 1; }
  [[ -z "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\trun")" ]] || { fail "no debió hacer backup"; return 1; }
  [[ -n "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\trestore\t")" ]] || { fail "debió restaurar"; return 1; }
  assert_not_contains "$(_rs_sudo_calls)" "--discard-old" "sin backup de seguridad se conserva lo anterior" || return 1
  assert_eq "1" "$(_rs_olds "$APPDATA_ROOT/vaultwarden/data" | grep -c .)" || return 1
}

test_restore_module_safety_backup_failure_defaults_to_not_restoring() {
  _rs_module_env
  export STUB_RESTIC_FAIL="backup"
  printf '%s\nvaultwarden\n' "$_RS_FULL_NEW" > "$DIALOG_MENU_QUEUE"
  printf 'yes\nyes\nno\n' > "$DIALOG_YESNO_QUEUE"      # resumen / backup de seguridad / "¿restaurar igual?" -> no
  if bash "$RS_CODE/modules/backup-restore.sh" </dev/null; then fail "debió terminar con error"; return 1; fi
  [[ -z "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\trestore\t")" ]] || { fail "no debió restaurar"; return 1; }
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
  # La pregunta de "restaurar igual" tiene "No" como opción por defecto.
  [[ -n "$(_bk_calls '^dialog\t--defaultno\t')" ]] || { fail "'restaurar de todas formas' debe ser defaultno"; return 1; }
}

test_restore_module_cancel_at_the_summary_changes_nothing() {
  _rs_module_env
  printf '%s\nvaultwarden\n' "$_RS_FULL_NEW" > "$DIALOG_MENU_QUEUE"
  printf 'no\n' > "$DIALOG_YESNO_QUEUE"
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || true
  [[ -z "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\t(run|restore)")" ]] || { fail "no debió ejecutar nada"; return 1; }
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
}

test_restore_module_menus_list_snapshots_newest_first_and_only_services_with_data() {
  _rs_module_env
  printf '%s\nvaultwarden\n' "$_RS_FULL_NEW" > "$DIALOG_MENU_QUEUE"
  printf 'no\n' > "$DIALOG_YESNO_QUEUE"
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || true
  local menus snap_menu tgt_menu
  menus="$(_bk_calls '^dialog\t.*--menu')"
  snap_menu="$(printf '%s\n' "$menus" | rg "Foto a restaurar")"
  tgt_menu="$(printf '%s\n' "$menus" | rg "Qué restaurar")"
  [[ -n "$snap_menu" && -n "$tgt_menu" ]] || { fail "faltan los menús: $menus"; return 1; }
  # Solo la copia local configurada: no hay menú de origen.
  assert_not_contains "$menus" "Desde dónde restaurar" || return 1
  [[ "$snap_menu" == *"$_RS_FULL_NEW"*"$_RS_FULL_OLD"* ]] || { fail "la foto más nueva debe ir primero: $snap_menu"; return 1; }
  assert_not_contains "$snap_menu" "$_RS_CLOUD" || return 1
  local svc
  for svc in all vaultwarden jellyfin opencloud homeassistant adguard qbittorrent smbd; do
    [[ "$tgt_menu" == *$'\t'"$svc"$'\t'* ]] || { fail "falta '$svc' en el menú de qué restaurar"; return 1; }
  done
  for svc in tailscale cloudflared dokploy; do
    [[ "$tgt_menu" != *$'\t'"$svc"$'\t'* ]] || { fail "'$svc' no tiene datos: no debe ofrecerse"; return 1; }
  done
}

test_restore_module_offers_r2_and_warns_about_opencloud_files() {
  _rs_module_env
  _bk_r2
  printf 'r2\n%s\nopencloud\n' "$_RS_CLOUD" > "$DIALOG_MENU_QUEUE"
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || { fail "el módulo falló"; return 1; }
  local dialogs
  dialogs="$(_bk_calls '^dialog\t')"
  assert_contains "$dialogs" "Desde dónde restaurar" "con R2 configurado se elige el origen" || return 1
  assert_contains "$dialogs" "no están en la copia externa" "avisa que los archivos de OpenCloud no están en R2" || return 1
  [[ -n "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\trestore\t--source\tr2\t--snapshot\t$_RS_CLOUD\t--target\topencloud\$")" ]] || { fail "debió pedir la restauración desde R2: $(_rs_sudo_calls)"; return 1; }
  assert_eq "snapshot-opencloud/config" "$(_rs_content "$APPDATA_ROOT/opencloud/config/file.txt")" || return 1
  assert_eq "current-opencloud/data" "$(_rs_content "$APPDATA_ROOT/opencloud/data/file.txt")" || return 1
}

test_restore_module_all_asks_about_restic_env_with_no_as_default() {
  _rs_module_env
  export STUB_SUDO_RUN_ENTRYPOINT="snapshots"     # la restauración se registra, no se ejecuta
  _rs_secrets
  printf 'local\n%s\nall\n' "$_RS_FULL_NEW" > "$DIALOG_MENU_QUEUE"     # con R2 configurado se elige el origen
  printf 'no\nyes\nno\n' > "$DIALOG_YESNO_QUEUE"       # ¿restic.env? no / resumen sí / backup de seguridad no
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || true
  [[ -n "$(_bk_calls '^dialog\t--defaultno\t.*restic\.env')" ]] || { fail "la pregunta de restic.env debe ser defaultno"; return 1; }
  assert_not_contains "$(_rs_sudo_calls)" "--with-restic-env" || return 1
  assert_contains "$(_bk_calls '^dialog\t')" "NO se tocan restic-password ni dokploy.env ni restic.env" || return 1
  assert_eq "RESTIC_REPOSITORY=s3:https://${_BK_ACCOUNT}.r2.cloudflarestorage.com/bkt" "$(_rs_secret restic.env | head -1)" || return 1
}

test_restore_module_reports_failure_from_root() {
  _rs_module_env
  export STUB_RESTIC_FAIL="restore"
  printf '%s\nvaultwarden\n' "$_RS_FULL_NEW" > "$DIALOG_MENU_QUEUE"
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"
  if bash "$RS_CODE/modules/backup-restore.sh" </dev/null; then fail "debió terminar con error"; return 1; fi
  assert_contains "$(_bk_calls '^dialog\t')" "terminó con errores" || return 1
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
}

test_restore_refresh_install_ships_the_restore_library() {
  _rs_prepare
  ( cd / && source "$RS_CODE/lib/core.sh" && backup_refresh_install ) || { fail "no se pudo refrescar la copia"; return 1; }
  [[ -f "$BACKUP_INSTALL_DIR/lib/restore.sh" ]] || { fail "la copia root-owned debe incluir lib/restore.sh"; return 1; }
}

# --- Recuperación ante un desastre (backup-setup con contraseña existente) ----------------------

test_backup_setup_disaster_recovery_uses_the_existing_password() {
  _rs_prepare
  _bk_setup_env
  local pw="la-contrasena-de-los-backups-viejos-123"
  echo "existing" > "$DIALOG_MENU_QUEUE"
  printf '%s\n%s\n' "$pw" "$pw" > "$DIALOG_PASSWORDBOX_QUEUE"
  printf 'yes\n' > "$DIALOG_YESNO_QUEUE"               # configurar R2
  printf '%s\n%s\n%s\n' "https://${_BK_ACCOUNT}.r2.cloudflarestorage.com" "hli2-bkt" "$_BK_SECRET_KEY" > "$DIALOG_INPUTBOX_QUEUE"
  # Dos veces la contraseña de restic y, después, el Secret de R2.
  printf '%s\n%s\n%s\n' "$pw" "$pw" "$_BK_SECRET_VAL" > "$DIALOG_PASSWORDBOX_QUEUE"
  export STUB_RESTIC_R2_INITIALIZED=1                  # el repositorio de R2 ya existe
  export STUB_SUDO_RUN_ENTRYPOINT="init"               # 'hli2-backup init' corre de verdad

  timeout 30 bash "$RS_CODE/modules/backup-setup.sh" || { fail "backup-setup falló"; return 1; }

  assert_eq "$pw" "$(sudo -n cat "$SECRETS_DIR/restic-password")" "la contraseña existente quedó guardada" || return 1
  assert_eq "600" "$(sudo -n stat -c %a "$SECRETS_DIR/restic-password")" || return 1
  assert_file_contains "$STATE_FILE" "backup-password-confirmed" || return 1
  [[ -z "$STUB_TEXTBOX_LOG" || ! -s "$STUB_TEXTBOX_LOG" ]] || { fail "no debe mostrar ninguna contraseña generada"; return 1; }
  assert_not_contains "$(cat "$STUB_CALL_LOG")" "$pw" "la contraseña nunca va por argv" || return 1
  # El repositorio de R2 ya existía: no se inicializa nada ahí (solo el local, que es nuevo).
  assert_eq "1" "$(_bk_calls '^restic\t(.*\t)?init' | wc -l | tr -d ' ')" "solo se inicializa el repositorio local" || return 1
  [[ -n "$(_bk_calls '^restic\t(.*\t)?cat\tconfig')" ]] || { fail "debió comprobar el repositorio de R2 con 'cat config'"; return 1; }
  assert_contains "$(_bk_calls '^dialog\t')" "Recuperación" "indica cómo recuperar los datos" || return 1
}

test_backup_setup_disaster_recovery_rejects_mismatched_passwords() {
  _rs_prepare
  _bk_setup_env
  echo "existing" > "$DIALOG_MENU_QUEUE"
  printf '%s\n%s\n' "una-contrasena-larga-uno-123" "una-contrasena-larga-dos-456" > "$DIALOG_PASSWORDBOX_QUEUE"
  if timeout 30 bash "$RS_CODE/modules/backup-setup.sh"; then fail "debió abortar"; return 1; fi
  chmod u+rwx "$SECRETS_DIR"
  [[ ! -e "$SECRETS_DIR/restic-password" ]] || { chmod 000 "$SECRETS_DIR"; fail "no debe guardar nada si no coinciden"; return 1; }
  chmod 000 "$SECRETS_DIR"
  [[ -z "$(_bk_calls '^restic\t')" ]] || { fail "no debe inicializar nada"; return 1; }
}

test_backup_setup_disaster_recovery_rejects_weak_password() {
  _rs_prepare
  _bk_setup_env
  echo "existing" > "$DIALOG_MENU_QUEUE"
  printf '%s\n%s\n' "corta" "corta" > "$DIALOG_PASSWORDBOX_QUEUE"
  if timeout 30 bash "$RS_CODE/modules/backup-setup.sh"; then fail "debió abortar"; return 1; fi
  chmod u+rwx "$SECRETS_DIR"
  [[ ! -e "$SECRETS_DIR/restic-password" ]] || { chmod 000 "$SECRETS_DIR"; fail "no debe guardar una contraseña inválida"; return 1; }
  chmod 000 "$SECRETS_DIR"
}

test_backup_setup_fresh_install_still_generates_when_asked() {
  _rs_prepare
  _bk_setup_env
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"           # contraseña guardada / sin R2
  timeout 30 bash "$RS_CODE/modules/backup-setup.sh" || { fail "backup-setup falló"; return 1; }
  assert_contains "$(cat "$STUB_TEXTBOX_LOG")" "CONTRASEÑA" "se genera y muestra una contraseña nueva" || return 1
}

test_backup_init_refuses_an_existing_r2_repo_with_a_different_password() {
  _bk_prepare
  _bk_r2
  export STUB_RESTIC_CAT_WRONG_PW=1
  if _bk_run init; then fail "debió negarse: la contraseña no abre el repositorio de R2"; return 1; fi
  [[ -z "$(_bk_calls '^restic\t(.*\t)?init')" ]] || { fail "NUNCA debe inicializar sobre un repositorio existente"; return 1; }
  assert_contains "$(cat "$LOG_DIR/backup.log")" "no lo abre" "dice por qué" || return 1
  assert_not_contains "$(cat "$STUB_CALL_LOG" "$LOG_DIR/backup.log")" "$_BK_SECRET_VAL" || return 1
}
