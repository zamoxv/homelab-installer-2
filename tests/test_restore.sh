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

# Copias previas de un .env: viven FUERA de /etc/hli2 (no entran en los backups) pero junto a él, en el mismo sistema de archivos.
_rs_secret_has_old() {
  local f
  for f in "$SECRETS_DIR-old-secrets/$1".hli2-before-restore-*; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}
_rs_secret_old_inside() {
  local rc=1 f
  chmod u+rwx "$SECRETS_DIR"
  for f in "$SECRETS_DIR"/*.hli2-before-restore-*; do [[ -e "$f" ]] && rc=0; done
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
  (( rest < stop && stop < start )) || { fail "orden incorrecto (restaurar a la carpeta de paso, detener, iniciar): restore=$rest stop=$stop start=$start"; return 1; }
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

# Registra una copia previa de $1 (ruta de datos) con fecha $2 como creada por una restauración
# exitosa anterior (como lo hace lib/restore.sh).
_rs_seed_old_copy() {
  local dst="$1" ts="$2"
  mkdir -p "$dst.hli2-before-restore-$ts"
  echo "copia-$ts" > "$dst.hli2-before-restore-$ts/file.txt"
  printf '%s\t%s\n' "$dst" "$dst.hli2-before-restore-$ts" >> "$BACKUP_STATE_DIR/restore-old-copies"
}

test_restore_keeps_the_oldest_and_the_newest_before_restore_copy() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data" n
  _rs_seed_old_copy "$d" 20200101-000000      # el estado original, anterior a toda restauración
  _rs_seed_old_copy "$d" 20200201-000000      # intermedia
  # Una copia que no registró ninguna corrida exitosa: nunca se borra sola.
  mkdir -p "$d.hli2-before-restore-20190101-000000"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden || return 1
  [[ -e "$d.hli2-before-restore-20200101-000000" ]] || { fail "la copia más vieja (estado original) debe conservarse"; return 1; }
  [[ ! -e "$d.hli2-before-restore-20200201-000000" ]] || { fail "la intermedia debió borrarse"; return 1; }
  [[ -e "$d.hli2-before-restore-20190101-000000" ]] || { fail "una copia desconocida no se borra"; return 1; }
  n="$(_rs_olds "$d" | grep -c .)"
  assert_eq "3" "$n" "la vieja, la desconocida y la nueva" || return 1
  assert_contains "$(_rs_status message)" "copias previas conservadas" "avisa dónde quedaron" || return 1
  assert_contains "$(_rs_status message)" "20200101-000000" || return 1
}

test_restore_does_not_prune_when_the_previous_restore_was_interrupted() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data"
  _rs_seed_old_copy "$d" 20200101-000000
  _rs_seed_old_copy "$d" 20200201-000000
  _rs_seed_old_copy "$d" 20200301-000000
  printf 'timestamp=%s\nresult=interrupted\nsource=local\nsnapshot=x\nsnapshot_time=\ntarget=all\nmodules=\nmessage=\n' "$(date -Is)" > "$BACKUP_STATE_DIR/restore-status"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden --discard-old || return 1
  assert_eq "4" "$(_rs_olds "$d" | grep -c .)" "no se borró ninguna copia previa" || return 1
  assert_contains "$(_rs_status message)" "quedó interrumpida" "lo dice" || return 1
}

test_restore_failed_run_registers_nothing_for_pruning() {
  _rs_prepare
  local c="$APPDATA_ROOT/adguard/conf" w="$APPDATA_ROOT/adguard/work"
  export STUB_SUDO_MV_FAIL_TARGET="$w"
  # 'all' hace que adguard (la 1.ª en orden) falle: nada completado, nada registrado.
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target adguard || true
  [[ ! -s "$BACKUP_STATE_DIR/restore-old-copies" ]] || { fail "una corrida fallida no registra copias: $(cat "$BACKUP_STATE_DIR/restore-old-copies")"; return 1; }
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
    _restore_containers_plan
    echo "rc=$? modules=$RS_MODULES"
  ) )"
  assert_contains "$out" "rc=0" || return 1
  assert_contains "$out" "modules=dokploy adguard" "Dokploy primero, luego los servicios" || return 1
  assert_contains "$out" "opencloud" || return 1
  out="$( (
    source "$REPO_ROOT/lib/core.sh"
    hli_docker_presence() { echo unknown; }
    RS_TARGET=all RS_MODULES=""
    _restore_containers_plan && echo "rc=0" || echo "rc=1"
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
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" "nada reemplazado" || return 1
  # Las carpetas de paso se armaron con los contenedores en marcha y se borraron al abortar.
  [[ -n "$(_bk_calls '^restic\t(.*\t)?restore\t')" ]] || { fail "la fase 1 (carpetas de paso) debió correr antes de detener nada"; return 1; }
  [[ ! -e "$APPDATA_ROOT/vaultwarden/data.hli2-restore-tmp" && ! -e "$APPDATA_ROOT/jellyfin/config.hli2-restore-tmp" ]] || { fail "quedaron carpetas de paso"; return 1; }
  assert_eq "" "$(_rs_olds "$APPDATA_ROOT/vaultwarden/data")" "no se apartó nada" || return 1
  local c
  # Se detuvieron (en orden) adguard, homeassistant y jellyfin (falla); el cleanup intenta
  # levantar TODOS los de la lista (iniciar uno que nunca se detuvo no hace daño).
  for c in adguard homeassistant jellyfin; do
    [[ -n "$(_bk_calls "^docker\tstart\t$c\$")" ]] || { fail "no reinició $c"; return 1; }
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
  # Las carpetas de paso se arman con los contenedores en marcha: si falla, nunca se detuvieron.
  [[ -z "$(_bk_calls '^docker\t(stop|start)\t')" ]] || { fail "no debió detener ni iniciar nada"; return 1; }
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
  assert_eq "" "$(_bk_files_in "$STUB_DOCKER_STATE_DIR" \'/\.\')" "ningún contenedor quedó detenido" || return 1
  assert_eq "interrupted" "$(_rs_status result)" || return 1
}

test_restore_second_signal_does_not_abort_restart() {
  _rs_prepare
  # TERM en plena parada de contenedores y un segundo TERM al primer 'docker start'.
  export STUB_DOCKER_KILL_ON_STOP=1 STUB_DOCKER_KILL_ON_START=1
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target all || true
  [[ -f "$STUB_DOCKER_STATE_DIR/.killed-stop" && -f "$STUB_DOCKER_STATE_DIR/.killed" ]] || { fail "no se enviaron las dos señales (test vacío)"; return 1; }
  assert_eq "" "$(_bk_files_in "$STUB_DOCKER_STATE_DIR" \'/\.\')" "ningún contenedor quedó detenido" || return 1
  assert_eq "6" "$(_bk_calls '^docker\tstart\t' | wc -l | tr -d ' ')" "los 6 contenedores con datos volvieron a iniciar" || return 1
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" "no se reemplazó nada" || return 1
  assert_eq "interrupted" "$(_rs_status result)" || return 1
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
  [[ -z "$(_bk_calls '^docker\tstop\t')" ]] || { fail "sin nada que restaurar no se detiene el contenedor"; return 1; }
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
  _rs_secret_has_old vaultwarden.env || { fail "debió quedar copia previa de vaultwarden.env fuera de /etc/hli2"; return 1; }
  if _rs_secret_old_inside; then fail "las copias previas de secretos no deben quedar dentro de /etc/hli2 (entrarían en los backups)"; return 1; fi
  assert_eq "700" "$(stat -c %a "$SECRETS_DIR-old-secrets")" "carpeta de copias de secretos 0700, junto a /etc/hli2" || return 1
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

# ==================================================================================================
# Revisión: robustez ante señales y terminal colgada, diario de intercambio, orden de fases,
# frescura del estado, enlaces simbólicos y recuperación ante desastre verificable
# ==================================================================================================

# --- W1: una tubería rota (SSH colgado) no puede matar el cleanup ----------------------------------

test_backup_cleanup_survives_a_closed_stdout_pipe() {
  _bk_prepare
  : > "$STUB_DOCKER_STATE_DIR/vaultwarden.stopped"
  printf 'vaultwarden\n' > "$BACKUP_STATE_DIR/recovery-containers"
  # El lector sale al instante: cuando el subshell escribe, la tubería ya está rota
  # (con SIGPIPE por defecto, el primer 'printf' del cleanup lo mataba).
  ( sleep 0.3
    source "$REPO_ROOT/lib/core.sh"
    BACKUP_STOPPED_CONTAINERS="vaultwarden " BK_ACTIVE=1
    backup_exit_cleanup
    : > "$HLI2_TEST_SCRATCH/cleanup-finished"
  ) 2>/dev/null | true
  [[ -f "$HLI2_TEST_SCRATCH/cleanup-finished" ]] || { fail "el cleanup murió antes de terminar (SIGPIPE)"; return 1; }
  [[ -n "$(_bk_calls '^docker\tstart\tvaultwarden$')" ]] || { fail "no volvió a iniciar el contenedor"; return 1; }
  assert_contains "$(cat "$LOG_DIR/backup.log")" "Iniciando 'vaultwarden'" "con stdout roto, el registro va al log" || return 1
  assert_eq "interrupted" "$(_bk_status result)" || return 1
}

test_restore_cleanup_survives_a_closed_stdout_pipe() {
  _rs_prepare
  : > "$STUB_DOCKER_STATE_DIR/vaultwarden.stopped"
  ( sleep 0.3
    source "$RS_CODE/lib/core.sh"
    BACKUP_STOPPED_CONTAINERS="vaultwarden " RS_ACTIVE=1 RS_SOURCE=local RS_SNAPSHOT="$_RS_FULL_NEW" RS_TARGET=vaultwarden
    restore_exit_cleanup
    : > "$HLI2_TEST_SCRATCH/cleanup-finished"
  ) 2>/dev/null | true
  [[ -f "$HLI2_TEST_SCRATCH/cleanup-finished" ]] || { fail "el cleanup murió antes de terminar (SIGPIPE)"; return 1; }
  [[ -n "$(_bk_calls '^docker\tstart\tvaultwarden$')" ]] || { fail "no volvió a iniciar el contenedor"; return 1; }
  assert_eq "interrupted" "$(_rs_status result)" || return 1
}

# --- W2: intercambio atómico por servicio, deshacer a medias y diario ---------------------------

test_restore_signal_between_two_swaps_cannot_leave_a_half_restored_service() {
  _rs_prepare
  local c="$APPDATA_ROOT/adguard/conf" w="$APPDATA_ROOT/adguard/work"
  export STUB_SUDO_MV_KILL_TARGET="$c"      # TERM justo después de colocar la 1.ª ruta
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target adguard || { fail "las señales se ignoran durante el intercambio: debió terminar"; return 1; }
  [[ -f "$HLI2_TEST_SCRATCH/.mv-killed" ]] || { fail "no se envió la señal (test vacío)"; return 1; }
  assert_eq "snapshot-adguard/conf" "$(_rs_content "$c/file.txt")" || return 1
  assert_eq "snapshot-adguard/work" "$(_rs_content "$w/file.txt")" "las dos rutas, no solo la primera" || return 1
  [[ ! -e "$BACKUP_STATE_DIR/restore-swap-journal" ]] || { fail "el diario debe borrarse al terminar"; return 1; }
  assert_eq "ok" "$(_rs_status result)" || return 1
}

test_restore_exit_cleanup_undoes_a_partial_swap() {
  _rs_prepare
  local p="$APPDATA_ROOT/adguard/conf" stage
  stage="$p.hli2-restore-tmp$p"
  mkdir -p "$stage"; echo "nuevo" > "$stage/file.txt"
  ( source "$RS_CODE/lib/core.sh"
    RS_TS=T RS_ACTIVE=1 RS_SOURCE=local RS_SNAPSHOT=x RS_TARGET=adguard
    RS_SW_DST=() RS_SW_OLD=() RS_SW_HAD=()
    _restore_swap_one "$stage" "$p" "$p.hli2-before-restore-T" 1
    # Un 'set -e' aborta aquí, entre dos intercambios: el trap EXIT lo deshace.
    restore_exit_cleanup
  ) >/dev/null 2>&1
  assert_eq "current-adguard/conf" "$(_rs_content "$p/file.txt")" "se devolvió lo original" || return 1
  [[ ! -e "$p.hli2-before-restore-T" ]] || { fail "no debe quedar la copia apartada"; return 1; }
  assert_eq "interrupted" "$(_rs_status result)" || return 1
  assert_contains "$(_rs_status message)" "se deshizo" "el estado no miente sobre lo que pasó" || return 1
}

test_restore_interrupted_status_names_the_services_already_restored() {
  _rs_prepare
  ( source "$RS_CODE/lib/core.sh"
    RS_ACTIVE=1 RS_RESULT=ok RS_DONE="adguard jellyfin" RS_SOURCE=local RS_SNAPSHOT=x RS_TARGET=all
    restore_exit_cleanup ) >/dev/null 2>&1
  assert_contains "$(_rs_status message)" "ya restaurados: adguard jellyfin" || return 1
}

test_restore_journal_recovery_puts_old_data_back_before_starting_containers() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data" old="$APPDATA_ROOT/vaultwarden/data.hli2-before-restore-20261006-040000"
  # Corte de luz entre los dos 'mv': falta 'data', lo anterior quedó apartado y el contenedor, detenido.
  mv "$d" "$old"
  : > "$STUB_DOCKER_STATE_DIR/vaultwarden.stopped"
  printf 'vaultwarden\n' > "$BACKUP_STATE_DIR/recovery-containers"
  printf '%s\t%s\t1\n' "$d" "$old" > "$BACKUP_STATE_DIR/restore-swap-journal"
  _rs_run recover || { fail "recover falló"; return 1; }
  assert_eq "current-vaultwarden/data" "$(_rs_content "$d/file.txt")" "lo anterior volvió a su lugar" || return 1
  [[ ! -e "$old" ]] || { fail "la copia apartada debió volver a su nombre"; return 1; }
  [[ ! -e "$BACKUP_STATE_DIR/restore-swap-journal" ]] || { fail "el diario debe borrarse"; return 1; }
  local mvl start
  mvl="$(_bk_line_no '^sudo\t-n\tmv\t.*hli2-before-restore')"
  start="$(_bk_line_no '^docker\tstart\tvaultwarden$')"
  [[ -n "$mvl" && -n "$start" ]] || { fail "faltan llamadas (mv=$mvl start=$start)"; return 1; }
  (( mvl < start )) || { fail "el dato debe volver ANTES de iniciar el contenedor (mv=$mvl start=$start)"; return 1; }
}

test_restore_journal_recovery_also_runs_at_the_start_of_run_and_restore() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data" old="$APPDATA_ROOT/vaultwarden/data.hli2-before-restore-20261006-040000"
  mv "$d" "$old"
  printf '%s\t%s\t1\n' "$d" "$old" > "$BACKUP_STATE_DIR/restore-swap-journal"
  _bk_run run || return 1
  assert_eq "current-vaultwarden/data" "$(_rs_content "$d/file.txt")" "run también deshace lo que quedó a medias" || return 1
}

test_restore_journal_recovery_removes_data_placed_when_nothing_existed_before() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data"
  printf '%s\t%s\t0\n' "$d" "$d.hli2-before-restore-20261006-040000" > "$BACKUP_STATE_DIR/restore-swap-journal"
  _rs_run recover || return 1
  [[ ! -e "$d" ]] || { fail "sin estado anterior (had=0) se vuelve a no tener la carpeta"; return 1; }
}

test_restore_journal_recovery_ignores_invalid_lines() {
  _rs_prepare
  printf '/etc/passwd\t/etc/shadow\t1\n../x\t../y\t1\n%s\t%s\t7\n' "$APPDATA_ROOT/vaultwarden/data" "$APPDATA_ROOT/vaultwarden/data.hli2-before-restore-1" > "$BACKUP_STATE_DIR/restore-swap-journal"
  if _rs_run recover; then fail "con líneas rechazadas debió terminar con error"; return 1; fi
  assert_contains "$(cat "$LOG_DIR/backup.log")" "línea inválida" || return 1
  [[ -f "$BACKUP_STATE_DIR/restore-swap-journal.failed" ]] || { fail "el diario se conserva como .failed"; return 1; }
  [[ -z "$(_bk_calls '^sudo\t-n\t(mv|rm)\t')" ]] || { fail "no debió tocar nada con líneas inválidas: $(_bk_calls '^sudo\t-n\t(mv|rm)\t')"; return 1; }
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
}

# --- W6: primero las carpetas de paso, después se detiene; espacio libre -----------------------------

test_restore_stages_everything_before_stopping_any_container() {
  _rs_prepare
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target all || true
  local last_restore first_stop
  last_restore="$(_bk_last_line_no '^restic\t(.*\t)?restore\t')"
  first_stop="$(_bk_line_no '^docker\tstop\t')"
  [[ -n "$last_restore" && -n "$first_stop" ]] || { fail "faltan llamadas (restore=$last_restore stop=$first_stop)"; return 1; }
  (( last_restore < first_stop )) || { fail "todos los 'restic restore' deben ir antes del primer 'docker stop' (los servicios siguen arriba mientras se restaura)"; return 1; }
}

test_restore_refuses_when_there_is_not_enough_free_space() {
  _rs_prepare
  export STUB_DF_AVAIL=1000
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden; then fail "debió negarse por falta de espacio"; return 1; fi
  assert_contains "$(_rs_status message)" "espacio insuficiente" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?restore\t')" ]] || { fail "no debió restaurar nada"; return 1; }
  [[ -z "$(_bk_calls '^docker\t(stop|start)\t')" ]] || { fail "no debió tocar contenedores"; return 1; }
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
}

test_restore_estimates_with_restic_stats_when_the_path_does_not_exist_yet() {
  _rs_prepare
  rm -rf "$APPDATA_ROOT/vaultwarden"        # equipo nuevo: no hay nada que medir con 'du'
  export STUB_RESTIC_STATS_SIZE=1000000000000 STUB_DF_AVAIL=1000000 STUB_DOCKER_NOT_FOUND=vaultwarden
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden; then fail "debió negarse: la foto no entra"; return 1; fi
  [[ -n "$(_bk_calls '^restic\t(.*\t)?stats\t.*restore-size')" ]] || { fail "debió estimar con 'restic stats --mode restore-size'"; return 1; }
  assert_contains "$(_rs_status message)" "espacio insuficiente" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?restore\t')" ]] || { fail "no debió restaurar"; return 1; }
}

# --- Enlaces simbólicos y carpeta de paso -----------------------------------------------------------

test_restore_removes_a_stale_stage_dir_from_an_interrupted_run() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data"
  mkdir -p "$d.hli2-restore-tmp/basura"; echo x > "$d.hli2-restore-tmp/basura/f"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden || { fail "debió terminar bien"; return 1; }
  [[ ! -e "$d/basura" ]] || { fail "la basura de la carpeta de paso vieja no debe colarse en los datos"; return 1; }
  [[ ! -e "$d.hli2-restore-tmp" ]] || { fail "quedó la carpeta de paso"; return 1; }
  assert_eq "snapshot-vaultwarden/data" "$(_rs_content "$d/file.txt")" || return 1
}

test_restore_refuses_a_stage_dir_that_is_a_symlink() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data" other="$HLI2_TEST_SCRATCH/otro"
  mkdir -p "$other"
  ln -s "$other" "$d.hli2-restore-tmp"
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden; then fail "debió negarse"; return 1; fi
  [[ -L "$d.hli2-restore-tmp" ]] || { fail "el enlace no se toca"; return 1; }
  assert_eq "" "$(_bk_files_in "$other")" "no se escribió a través del enlace" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?restore\t')" ]] || { fail "no debió restaurar"; return 1; }
  assert_contains "$(_rs_status message)" "enlace simbólico" || return 1
  assert_eq "current-vaultwarden/data" "$(_rs_content "$d/file.txt")" || return 1
}

test_restore_refuses_a_data_path_that_is_a_symlink() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data" real="$HLI2_TEST_SCRATCH/otro-disco-data"
  mv "$d" "$real"; ln -s "$real" "$d"
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden; then fail "debió negarse"; return 1; fi
  assert_contains "$(_rs_status message)" "enlace simbólico" "con un mensaje claro" || return 1
  [[ -L "$d" ]] || { fail "el enlace no se toca"; return 1; }
  assert_eq "current-vaultwarden/data" "$(_rs_content "$real/file.txt")" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?restore\t')" ]] || { fail "no debió restaurar"; return 1; }
}

test_restore_refuses_a_parent_dir_that_is_a_symlink() {
  _rs_prepare
  local real="$HLI2_TEST_SCRATCH/jellyfin-real"
  mv "$APPDATA_ROOT/jellyfin" "$real"; ln -s "$real" "$APPDATA_ROOT/jellyfin"
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target jellyfin; then fail "debió negarse"; return 1; fi
  assert_contains "$(_rs_status message)" "enlace simbólico" || return 1
  assert_eq "current-jellyfin/config" "$(_rs_content "$real/config/file.txt")" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?restore\t')" ]] || { fail "no debió restaurar"; return 1; }
}

test_restore_creates_the_stage_dir_with_plain_mkdir_not_mkdir_p() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden || return 1
  [[ -n "$(_bk_calls "^sudo\\t(-n\\t)?mkdir\\t--\\t$d.hli2-restore-tmp\$")" ]] || { fail "la carpeta de paso debe crearse con 'mkdir' sin -p"; return 1; }
}

# --- S1: configuración de Samba inválida ----------------------------------------------------------

test_restore_validates_smb_conf_with_testparm_before_swapping() {
  _rs_prepare
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target smbd || return 1
  assert_contains "$(_bk_calls '^testparm\t')" "$RS_SAMBA.hli2-restore-tmp$RS_SAMBA" "valida la copia de la carpeta de paso" || return 1
  assert_eq "snapshot-smb" "$(_rs_content "$RS_SAMBA")" || return 1
}

test_restore_refuses_an_invalid_smb_conf_and_keeps_the_current_one() {
  _rs_prepare
  export STUB_TESTPARM_FAIL=1
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target smbd; then fail "debió negarse"; return 1; fi
  assert_eq "current-smb" "$(_rs_content "$RS_SAMBA")" "Samba sigue con su configuración" || return 1
  assert_contains "$(_rs_status message)" "no es válida" || return 1
  [[ ! -e "$RS_SAMBA.hli2-restore-tmp" ]] || { fail "quedó la carpeta de paso"; return 1; }
  [[ -z "$(_bk_calls 'systemctl\ttry-restart')" ]] || { fail "no debió reiniciar smbd"; return 1; }
}

# --- R2: nada que restaurar si todo es "solo local" (S6) --------------------------------------------

test_restore_from_r2_when_all_the_data_of_a_service_is_local_only() {
  _rs_prepare
  _bk_r2
  printf '%s\n' 'SERVICE_NAME="OpenCloud"' 'SERVICE_KIND="container"' 'SERVICE_CONTAINER="opencloud"' \
    "SERVICE_DATA=(\"$APPDATA_ROOT/opencloud/data\")" 'SERVICE_BACKUP_KIND="files"' \
    "SERVICE_BACKUP_LOCAL_ONLY=(\"$APPDATA_ROOT/opencloud/data\")" > "$RS_CODE/services/opencloud.conf"
  if _rs_run restore --source r2 --snapshot "$_RS_CLOUD" --target opencloud; then fail "debió fallar con un mensaje claro"; return 1; fi
  assert_contains "$(_rs_status message)" "todos los datos de 'opencloud' son solo locales" || return 1
  [[ -z "$(_bk_calls '^docker\tstop\t')" ]] || { fail "no debió detener nada"; return 1; }
  # El módulo lo avisa antes de preguntar nada más.
  export STUB_SUDO_RUN_ENTRYPOINT="snapshots"
  printf 'r2\n%s\nopencloud\n' "$_RS_CLOUD" > "$DIALOG_MENU_QUEUE"
  printf 'yes\nyes\n' > "$DIALOG_YESNO_QUEUE"
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || true
  assert_contains "$(_bk_calls '^dialog\t')" "solo existen en la copia local" || return 1
  [[ -z "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\trestore")" ]] || { fail "el módulo no debe pedir la restauración"; return 1; }
}

# --- W4/W5: respuestas del módulo y frescura del estado ---------------------------------------------

test_restore_module_esc_on_the_safety_question_cancels_everything() {
  _rs_module_env
  printf '%s\nvaultwarden\n' "$_RS_FULL_NEW" > "$DIALOG_MENU_QUEUE"
  printf 'yes\nesc\n' > "$DIALOG_YESNO_QUEUE"          # resumen sí / ESC en la pregunta del backup de seguridad
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || true
  [[ -z "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\t(run|restore)")" ]] || { fail "ESC no es 'no hacer backup y seguir': no debió ejecutar nada"; return 1; }
  assert_contains "$(_bk_calls '^dialog\t')" "Restauración cancelada" || return 1
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
}

test_restore_module_does_not_discard_old_when_the_safety_status_is_stale() {
  _rs_module_env
  export STUB_SUDO_RUN_ENTRYPOINT="snapshots restore"      # 'run' es un no-op: el estado queda viejo
  printf 'timestamp=%s\nresult=ok\nlocal=ok\ncloud=ok\ncheck=ok\nsnapshot_full=ab12cd01\nsnapshot_cloud=ab12cd02\nmessage=\n' "$(date -d '2 days ago' -Is)" > "$BACKUP_STATE_DIR/backup-status"
  printf '%s\nvaultwarden\n' "$_RS_FULL_NEW" > "$DIALOG_MENU_QUEUE"
  printf 'yes\nyes\n' > "$DIALOG_YESNO_QUEUE"
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || true
  assert_not_contains "$(_rs_sudo_calls)" "--discard-old" "un estado viejo no prueba que el backup de seguridad se hizo" || return 1
  assert_contains "$(_bk_calls '^dialog\t')" "No se pudo confirmar el resultado del backup de seguridad" || return 1
  [[ -n "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\trestore")" ]] || { fail "igual restaura"; return 1; }
}

test_restore_module_does_not_discard_old_when_the_safety_backup_has_a_warning() {
  _rs_module_env
  export STUB_RESTIC_FAIL_RC=3 STUB_RESTIC_FAIL="backup:cloud"   # foto cloud con archivos ilegibles
  printf '%s\nvaultwarden\n' "$_RS_FULL_NEW" > "$DIALOG_MENU_QUEUE"
  printf 'yes\nyes\n' > "$DIALOG_YESNO_QUEUE"
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || true
  assert_not_contains "$(_rs_sudo_calls)" "--discard-old" "solo result=ok autoriza descartar" || return 1
}

test_restore_module_never_shows_a_stale_restore_status() {
  _rs_module_env
  export STUB_SUDO_RUN_ENTRYPOINT="snapshots"             # 'restore' no se ejecuta (p. ej. sudo -n vencido)
  printf 'timestamp=%s\nresult=ok\nsource=local\nsnapshot=%s\nsnapshot_time=\ntarget=vaultwarden\nmodules=\nmessage=\n' "$(date -d '3 days ago' -Is)" "$_RS_FULL_NEW" > "$BACKUP_STATE_DIR/restore-status"
  printf '%s\nvaultwarden\n' "$_RS_FULL_NEW" > "$DIALOG_MENU_QUEUE"
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"
  if bash "$RS_CODE/modules/backup-restore.sh" </dev/null; then fail "debió terminar con error"; return 1; fi
  assert_contains "$(_bk_calls '^dialog\t')" "No se pudo leer el resultado de la restauración" || return 1
  assert_not_contains "$(_bk_calls '^dialog\t')" "Restauración terminada" "no se muestra el resultado de otra restauración" || return 1
}

test_restore_module_lets_you_pick_older_snapshots_beyond_the_first_page() {
  _rs_module_env
  export HLI2_RESTORE_PAGE=1
  printf 'more\n%s\nvaultwarden\n' "$_RS_FULL_OLD" > "$DIALOG_MENU_QUEUE"
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || { fail "el módulo falló"; return 1; }
  local menus
  menus="$(_bk_calls '^dialog\t.*--menu')"
  assert_contains "$menus" "Ver fotos más antiguas" "ofrece la página siguiente" || return 1
  [[ -n "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\trestore\t--source\tlocal\t--snapshot\t$_RS_FULL_OLD\t--target\tvaultwarden\$")" ]] || { fail "debió restaurar la foto más vieja: $(_rs_sudo_calls)"; return 1; }
  assert_eq "snapshot-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
}

# --- W8: el timer esperando una restauración no es un error ------------------------------------------

_rs_hold_lock_with_restore_running() {
  printf 'timestamp=%s\nresult=running\nsource=local\nsnapshot=ab12cd01\nsnapshot_time=\ntarget=all\nmodules=\nmessage=\n' "$(date -Is)" > "$BACKUP_STATE_DIR/restore-status"
  flock "$BACKUP_STATE_DIR/lock" sleep 5 &
  RS_LOCK_HOLDER=$!
  sleep 0.3
}

test_backup_run_waiting_on_a_restore_is_skipped_and_does_not_refresh_staleness() {
  _bk_prepare
  local old_ts
  old_ts="$(date -d '40 hours ago' -Is)"
  printf 'timestamp=%s\nresult=ok\nlocal=ok\ncloud=ok\ncheck=ok\nsnapshot_full=ab12cd01\nsnapshot_cloud=ab12cd02\nmessage=\n' "$old_ts" > "$BACKUP_STATE_DIR/backup-status"
  _rs_hold_lock_with_restore_running
  local rc=0
  HLI2_BACKUP_LOCK_WAIT=1 _bk_run run || rc=$?
  HLI2_BACKUP_LOCK_WAIT=1 _bk_run run || rc=$((rc + $?))      # una segunda vez: el mensaje no se duplica
  kill "$RS_LOCK_HOLDER" 2>/dev/null || true
  assert_eq "0" "$rc" "no es un fallo del backup (el servicio systemd no queda 'failed')" || return 1
  assert_eq "$old_ts" "$(_bk_status timestamp)" "la fecha del último intento REAL no se refresca" || return 1
  assert_eq "ok" "$(_bk_status result)" "el resultado previo se conserva" || return 1
  [[ -n "$(_bk_status last_skip)" ]] || { fail "falta last_skip"; return 1; }
  assert_contains "$(_bk_status message)" "restauración en curso" || return 1
  assert_eq "1" "$(grep -o 'último intento omitido' "$BACKUP_STATE_DIR/backup-status" | wc -l | tr -d ' ')" "el mensaje no se acumula" || return 1
  [[ -z "$(_bk_calls '^(docker|restic)\t')" ]] || { fail "no debió tocar nada"; return 1; }
  assert_eq "ab12cd01" "$(_bk_status snapshot_full)" || return 1
  local summary
  summary="$( ( source "$REPO_ROOT/lib/core.sh"; backup_status_summary ) )"
  assert_contains "$summary" "Intento omitido" "el dashboard lo muestra" || return 1
  assert_contains "$summary" "AVISO" "el aviso de backup viejo sigue valiendo (omitir no cuenta como backup)" || return 1
  assert_contains "$summary" "más de 36 horas" || return 1
}

test_backup_run_skipped_keeps_a_previous_error_result() {
  _bk_prepare
  printf 'timestamp=%s\nresult=error\nlocal=ok\ncloud=error\ncheck=skipped\nsnapshot_full=\nsnapshot_cloud=\nmessage=falló la copia externa\n' "$(date -d '3 hours ago' -Is)" > "$BACKUP_STATE_DIR/backup-status"
  _rs_hold_lock_with_restore_running
  HLI2_BACKUP_LOCK_WAIT=1 _bk_run run || { kill "$RS_LOCK_HOLDER" 2>/dev/null; fail "debió terminar bien"; return 1; }
  kill "$RS_LOCK_HOLDER" 2>/dev/null || true
  assert_eq "error" "$(_bk_status result)" "un error previo no se tapa" || return 1
  assert_eq "error" "$(_bk_status cloud)" || return 1
  assert_contains "$(_bk_status message)" "falló la copia externa" || return 1
  assert_contains "$(_bk_status message)" "restauración en curso" "se agrega, no se reemplaza" || return 1
}

test_backup_run_skipped_without_previous_status_is_recorded_as_skipped() {
  _bk_prepare
  _rs_hold_lock_with_restore_running
  HLI2_BACKUP_LOCK_WAIT=1 _bk_run run || { kill "$RS_LOCK_HOLDER" 2>/dev/null; fail "debió terminar bien"; return 1; }
  kill "$RS_LOCK_HOLDER" 2>/dev/null || true
  assert_eq "skipped" "$(_bk_status result)" || return 1
}

# --- W3: recuperación ante un desastre con la contraseña equivocada ----------------------------------

test_backup_init_wrong_password_initializes_nothing_and_a_retry_works() {
  _bk_prepare
  _bk_r2
  rm -f "$BACKUP_ROOT/config"
  export STUB_RESTIC_CAT_WRONG_PW=1
  if _bk_run init; then fail "debió negarse con la contraseña equivocada"; return 1; fi
  [[ -z "$(_bk_calls '^restic\t(.*\t)?init')" ]] || { fail "no debió inicializar NADA (ni siquiera el repositorio local)"; return 1; }
  [[ ! -e "$BACKUP_ROOT/config" ]] || { fail "el repositorio local no debe quedar inicializado"; return 1; }
  # Con la contraseña correcta (el repositorio de R2 existe): el local nace con los parámetros de R2.
  unset STUB_RESTIC_CAT_WRONG_PW
  export STUB_RESTIC_R2_INITIALIZED=1
  : > "$STUB_CALL_LOG"
  _bk_run init || { fail "con la contraseña correcta debió funcionar"; return 1; }
  [[ -f "$BACKUP_ROOT/config" ]] || { fail "debió inicializar el repositorio local"; return 1; }
  local init
  init="$(_bk_calls '^restic\t(.*\t)?init\t')"
  assert_eq "1" "$(printf '%s\n' "$init" | grep -c .)" "solo el local: el de R2 ya existe" || return 1
  _bk_has_arg "$init" "--from-repo" && _bk_has_arg "$init" "s3:https://${_BK_ACCOUNT}.r2.cloudflarestorage.com/bkt" || { fail "el local debe copiar el repositorio de R2: $init"; return 1; }
  _bk_has_arg "$init" "--copy-chunker-params" || { fail "faltan los parámetros de troceado de R2: $init"; return 1; }
  assert_not_contains "$(cat "$STUB_CALL_LOG")" "$_BK_SECRET_VAL" "las claves de R2 viajan por el entorno, nunca por argv" || return 1
}

test_backup_init_does_not_initialize_on_an_ambiguous_r2_error() {
  _bk_prepare
  _bk_r2
  rm -f "$BACKUP_ROOT/config"
  export STUB_RESTIC_CAT_ERROR=1
  if _bk_run init; then fail "debió negarse: no se pudo comprobar R2"; return 1; fi
  [[ -z "$(_bk_calls '^restic\t(.*\t)?init')" ]] || { fail "solo se inicializa ante una señal positiva de 'no hay repositorio'"; return 1; }
  [[ ! -e "$BACKUP_ROOT/config" ]] || { fail "no debe quedar nada inicializado"; return 1; }
  assert_contains "$(cat "$LOG_DIR/backup.log")" "No se inicializó nada" || return 1
}

test_backup_init_new_install_creates_local_first_then_r2_from_local() {
  _bk_prepare
  _bk_r2
  rm -f "$BACKUP_ROOT/config"
  _bk_run init || return 1
  local first second
  first="$(_bk_calls '^restic\t(.*\t)?init' | sed -n 1p)"
  second="$(_bk_calls '^restic\t(.*\t)?init' | sed -n 2p)"
  [[ -n "$first" && -n "$second" ]] || { fail "debió inicializar los dos"; return 1; }
  ! _bk_has_arg "$first" "--from-repo" || { fail "el local nuevo no copia nada"; return 1; }
  _bk_has_arg "$second" "--from-repo" && _bk_has_arg "$second" "$BACKUP_ROOT" && _bk_has_arg "$second" "--copy-chunker-params" || { fail "R2 se crea desde el local: $second"; return 1; }
}

test_backup_setup_disaster_recovery_allows_reentering_the_password_after_a_failure() {
  _rs_prepare
  _bk_setup_env
  local bad="la-contrasena-equivocada-123456" good="la-contrasena-correcta-7890123"
  export STUB_SUDO_RUN_ENTRYPOINT="init" STUB_RESTIC_CAT_WRONG_PW=1
  echo "existing" > "$DIALOG_MENU_QUEUE"
  printf '%s\n%s\n%s\n' "$bad" "$bad" "$_BK_SECRET_VAL" > "$DIALOG_PASSWORDBOX_QUEUE"
  printf 'yes\n' > "$DIALOG_YESNO_QUEUE"
  printf '%s\n%s\n%s\n' "https://${_BK_ACCOUNT}.r2.cloudflarestorage.com" "hli2-bkt" "$_BK_SECRET_KEY" > "$DIALOG_INPUTBOX_QUEUE"
  if timeout 30 bash "$RS_CODE/modules/backup-setup.sh"; then fail "con la contraseña equivocada debió fallar"; return 1; fi
  [[ ! -e "$BACKUP_ROOT/config" ]] || { fail "no debió inicializar el repositorio local"; return 1; }
  assert_file_contains "$STATE_FILE" "backup-dr-pending" "la recuperación queda pendiente de verificar" || return 1

  # Segunda corrida con la contraseña correcta: NO dice "ya existente y confirmada: se conserva".
  unset STUB_RESTIC_CAT_WRONG_PW
  export STUB_RESTIC_R2_INITIALIZED=1
  : > "$STUB_CALL_LOG"
  echo "existing" > "$DIALOG_MENU_QUEUE"
  printf '%s\n%s\n' "$good" "$good" > "$DIALOG_PASSWORDBOX_QUEUE"
  : > "$DIALOG_YESNO_QUEUE"
  timeout 30 bash "$RS_CODE/modules/backup-setup.sh" || { fail "el reintento con la contraseña correcta debió funcionar"; return 1; }
  assert_eq "$good" "$(sudo -n cat "$SECRETS_DIR/restic-password")" "la contraseña se reemplazó por la correcta" || return 1
  [[ -f "$BACKUP_ROOT/config" ]] || { fail "ahora sí se inicializó el repositorio local"; return 1; }
  assert_file_not_contains "$STATE_FILE" "backup-dr-pending" "verificada: se saca la marca" || return 1
  assert_not_contains "$(cat "$STUB_CALL_LOG")" "$good" || return 1
  assert_not_contains "$(cat "$STUB_CALL_LOG")" "$bad" || return 1
}

# ==================================================================================================
# Segunda revisión: durabilidad y validación del diario, copias de secretos junto a /etc/hli2,
# detección de "no hay repositorio", recuperación visible, arranque antes de Docker
# ==================================================================================================

# --- W1: el diario se sincroniza ANTES del primer mv -----------------------------------------------

test_restore_syncs_the_journal_before_the_first_move() {
  _rs_prepare
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden || return 1
  local first_sync first_sync_fs first_mv
  first_sync="$(_bk_line_no '^sync\t')"
  first_sync_fs="$(_bk_line_no '^sync\t-f\t')"
  first_mv="$(_bk_line_no '^sudo\t-n\tmv\t-T\t')"
  [[ -n "$first_sync" && -n "$first_sync_fs" && -n "$first_mv" ]] || { fail "faltan llamadas (sync=$first_sync sync-f=$first_sync_fs mv=$first_mv)"; return 1; }
  (( first_sync < first_mv && first_sync_fs < first_mv )) || { fail "el diario (archivo y directorio) debe estar sincronizado antes del primer mv: sync=$first_sync sync-f=$first_sync_fs mv=$first_mv"; return 1; }
  # Y también al borrarlo.
  assert_contains "$(_bk_calls '^sync\t')" "$BACKUP_STATE_DIR" || return 1
  [[ "$(_bk_last_line_no '^sync\t-f\t')" -gt "$(_bk_last_line_no '^sudo\t-n\tmv\t-T\t')" ]] || { fail "al borrar el diario también se sincroniza"; return 1; }
}

# --- W2: validación del diario ---------------------------------------------------------------------

test_restore_journal_rejects_destinations_outside_the_registry_and_malformed_copies() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data"
  {
    printf '/etc/passwd\t/etc/passwd.hli2-before-restore-1\t0\n'
    printf '/etc/passwd\t/etc/passwd.hli2-before-restore-20261006-040000\t1\n'
    printf '%s\t%s\t1\n' "$APPDATA_ROOT/inventado/data" "$APPDATA_ROOT/inventado/data.hli2-before-restore-20261006-040000"
    printf '%s\t%s\t1\n' "$d" "$d.hli2-before-restore-1"
    printf '%s\t%s\t1\n' "$d" "$d.hli2-before-restore-20261006-040000.x"
    printf '%s\t%s\t1\n' "$d" "$APPDATA_ROOT/otra/data.hli2-before-restore-20261006-040000"
    printf '%s\t%s\t0\n' "$SECRETS_DIR/notas.txt" "$SECRETS_DIR-old-secrets/notas.txt.hli2-before-restore-20261006-040000"
    printf '%s\t%s\t0\n' "$SECRETS_DIR" "$SECRETS_DIR.hli2-before-restore-20261006-040000"
  } > "$BACKUP_STATE_DIR/restore-swap-journal"
  mkdir -p "$APPDATA_ROOT/inventado/data"
  if _rs_run recover; then fail "con líneas rechazadas debió terminar con error (hay algo sin resolver)"; return 1; fi
  [[ -z "$(_bk_calls '^sudo\t(-n\t)?(mv|rm)\t')" ]] || { fail "ninguna línea inválida debe provocar mv ni rm: $(_bk_calls '^sudo\t(-n\t)?(mv|rm)\t')"; return 1; }
  assert_eq "8" "$(grep -c 'línea inválida' "$LOG_DIR/backup.log")" "las 8 líneas se rechazan" || return 1
  [[ -f "$BACKUP_STATE_DIR/restore-swap-journal.failed" && ! -e "$BACKUP_STATE_DIR/restore-swap-journal" ]] || { fail "el diario no se borra: queda como .failed"; return 1; }
  assert_eq "error" "$(_rs_status result)" || return 1
  [[ -d "$APPDATA_ROOT/inventado/data" && -f "$d/file.txt" ]] || { fail "nada se tocó"; return 1; }
}

test_restore_journal_accepts_registry_paths_and_secret_env_files() {
  _rs_prepare
  _rs_secrets
  local d="$APPDATA_ROOT/jellyfin/config" old
  old="$d.hli2-before-restore-20261006-040000"
  mv "$d" "$old"
  # Un .env: la copia vive en <SECRETS_DIR>-old-secrets y el destino falta.
  mkdir -p "$SECRETS_DIR-old-secrets"
  chmod u+rwx "$SECRETS_DIR"; mv "$SECRETS_DIR/vaultwarden.env" "$SECRETS_DIR-old-secrets/vaultwarden.env.hli2-before-restore-20261006-040000"; chmod 000 "$SECRETS_DIR"
  {
    printf '%s\t%s\t1\n' "$d" "$old"
    printf '%s\t%s\t1\n' "$SECRETS_DIR/vaultwarden.env" "$SECRETS_DIR-old-secrets/vaultwarden.env.hli2-before-restore-20261006-040000"
  } > "$BACKUP_STATE_DIR/restore-swap-journal"
  _rs_run recover || { fail "recover falló"; return 1; }
  assert_eq "current-jellyfin/config" "$(_rs_content "$d/file.txt")" || return 1
  assert_eq "VW=OLD" "$(_rs_secret vaultwarden.env)" "el .env volvió a /etc/hli2" || return 1
}

# --- W3: copias de secretos en el mismo sistema de archivos que /etc/hli2 ------------------------

test_restore_refuses_secrets_when_the_old_copies_dir_is_on_another_filesystem() {
  _rs_prepare
  _rs_secrets
  export STUB_FAKE_ROOT_PREFIX="$SECRETS_DIR-old-secrets"      # el stub de 'stat' lo ve en otro dispositivo
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target all; then fail "debió negarse"; return 1; fi
  assert_contains "$(_rs_status message)" "mismo sistema de archivos" || return 1
  assert_eq "VW=OLD" "$(_rs_secret vaultwarden.env)" "los secretos no se tocan" || return 1
  # Se detecta en la fase 1, antes de detener o reemplazar nada: ni siquiera los servicios.
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
  [[ -z "$(_bk_calls '^docker\tstop\t')" ]] || { fail "no debió detener nada"; return 1; }
}

test_restore_old_secret_copies_are_a_sibling_dir_of_etc_hli2_not_inside_it() {
  _rs_prepare
  _rs_secrets
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target all || true
  _rs_secret_has_old vaultwarden.env || { fail "la copia debe estar en $SECRETS_DIR-old-secrets"; return 1; }
  [[ "$(dirname "$SECRETS_DIR-old-secrets")" == "$(dirname "$SECRETS_DIR")" ]] || return 1
  # /etc/hli2-old-secrets no es una de las rutas que respalda el backup.
  local out
  out="$( ( source "$RS_CODE/lib/core.sh"; _backup_collect; printf '%s\n' "${BK_PATHS[@]}" ) )"
  assert_not_contains "$out" "$SECRETS_DIR-old-secrets" "los secretos viejos no entran en los backups" || return 1
}

test_restore_journal_recovery_failure_keeps_the_journal_and_blocks_everything() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data" old="$APPDATA_ROOT/vaultwarden/data.hli2-before-restore-20261006-040000"
  mv "$d" "$old"
  : > "$STUB_DOCKER_STATE_DIR/vaultwarden.stopped"
  printf 'vaultwarden\n' > "$BACKUP_STATE_DIR/recovery-containers"
  printf '%s\t%s\t1\n' "$d" "$old" > "$BACKUP_STATE_DIR/restore-swap-journal"
  export STUB_SUDO_MV_FAIL_TARGET="$d"                  # el 'mv' que devuelve lo apartado falla
  if _rs_run recover; then fail "debió fallar: no se pudo revertir"; return 1; fi
  [[ ! -e "$BACKUP_STATE_DIR/restore-swap-journal" ]] || { fail "el diario original debe moverse"; return 1; }
  [[ -f "$BACKUP_STATE_DIR/restore-swap-journal.failed" ]] || { fail "el diario debe conservarse como .failed"; return 1; }
  assert_eq "600" "$(stat -c %a "$BACKUP_STATE_DIR/restore-swap-journal.failed")" || return 1
  assert_eq "error" "$(_rs_status result)" || return 1
  assert_contains "$(_rs_status message)" "$d" "el estado lista las rutas" || return 1
  [[ -d "$old" ]] || { fail "lo anterior sigue apartado, intacto"; return 1; }
  [[ -z "$(_bk_calls '^docker\tstart\t')" ]] || { fail "no se inician contenedores con el dato sin devolver (Docker crearía una carpeta vacía)"; return 1; }
  # Y una restauración nueva se niega hasta que se resuelva a mano.
  : > "$STUB_CALL_LOG"
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target jellyfin; then fail "debió negarse con un diario sin resolver"; return 1; fi
  assert_contains "$(_rs_status message)" "sin revertir" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?restore\t')" ]] || { fail "no debió restaurar"; return 1; }
}

# --- W6: la recuperación deja constancia visible -------------------------------------------------

test_restore_journal_recovery_is_visible_in_the_restore_status_and_dashboard() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data" old="$APPDATA_ROOT/vaultwarden/data.hli2-before-restore-20261006-040000"
  mv "$d" "$old"
  printf '%s\t%s\t1\n' "$d" "$old" > "$BACKUP_STATE_DIR/restore-swap-journal"
  _rs_run recover || return 1
  assert_eq "interrupted" "$(_rs_status result)" || return 1
  assert_eq "1" "$(_rs_status reverted)" || return 1
  assert_contains "$(_rs_status message)" "$d" "lista lo que se revirtió" || return 1
  assert_contains "$(_rs_status message)" "se revirtió" || return 1
  local dash
  dash="$( ( source "$REPO_ROOT/lib/core.sh"; printf 'timestamp=%s\nresult=ok\nlocal=ok\ncloud=ok\nmessage=\n' "$(date -Is)" > "$BACKUP_STATE_DIR/backup-status"; backup_status_summary ) )"
  assert_contains "$dash" "la última restauración se revirtió" "el dashboard lo muestra" || return 1
  local sum
  sum="$( ( source "$REPO_ROOT/lib/core.sh"; restore_status_summary ) )"
  assert_contains "$sum" "se revirtió" "y el resumen del módulo" || return 1
}

test_restore_run_reports_a_previous_restore_it_had_to_revert_and_does_not_prune() {
  _rs_prepare
  local d="$APPDATA_ROOT/jellyfin/config" old="$APPDATA_ROOT/jellyfin/config.hli2-before-restore-20261006-040000"
  mv "$d" "$old"
  printf '%s\t%s\t1\n' "$d" "$old" > "$BACKUP_STATE_DIR/restore-swap-journal"
  _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden --discard-old || return 1
  assert_contains "$(_rs_status message)" "se revirtió una restauración anterior" || return 1
  assert_eq "warning" "$(_rs_status result)" || return 1
  assert_eq "current-jellyfin/config" "$(_rs_content "$d/file.txt")" "lo anterior volvió antes de empezar" || return 1
}

test_restore_module_warns_when_the_last_restore_was_reverted() {
  _rs_module_env
  printf 'timestamp=%s\nresult=interrupted\nsource=local\nsnapshot=x\nsnapshot_time=\ntarget=all\nmodules=\nmessage=se revirtió\nreverted=1\n' "$(date -Is)" > "$BACKUP_STATE_DIR/restore-status"
  printf 'no\n' > "$DIALOG_YESNO_QUEUE"
  bash "$RS_CODE/modules/backup-restore.sh" </dev/null || true
  assert_contains "$(_bk_calls '^dialog\t')" "la última restauración se revirtió" || return 1
}

# --- S-E: arranque antes de Docker ------------------------------------------------------------------

test_restore_journal_recover_subcommand_needs_no_docker() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data" old="$APPDATA_ROOT/vaultwarden/data.hli2-before-restore-20261006-040000"
  mv "$d" "$old"
  printf '%s\t%s\t1\n' "$d" "$old" > "$BACKUP_STATE_DIR/restore-swap-journal"
  _rs_run journal-recover || { fail "journal-recover falló"; return 1; }
  assert_eq "current-vaultwarden/data" "$(_rs_content "$d/file.txt")" || return 1
  [[ -z "$(_bk_calls '^(docker|restic)\t')" ]] || { fail "no debe usar docker ni restic: $(_bk_calls '^(docker|restic)\t')"; return 1; }
  [[ -z "$(_bk_calls '^sudo\t(-n\t)?docker\t')" ]] || { fail "no debe usar docker"; return 1; }
  assert_eq "1" "$(_rs_status reverted)" || return 1
  # Sin diario no hace nada.
  : > "$STUB_CALL_LOG"
  _rs_run journal-recover || return 1
  [[ -z "$(_bk_calls '^sudo\t')" ]] || { fail "sin diario no hay nada que hacer"; return 1; }
}

test_backup_setup_installs_the_journal_unit_before_docker() {
  _rs_prepare
  _bk_setup_env
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"
  timeout 30 bash "$RS_CODE/modules/backup-setup.sh" || { fail "backup-setup falló"; return 1; }
  local u="$HLI2_SYSTEMD_DIR/hli2-restore-journal.service"
  [[ -f "$u" ]] || { fail "falta la unidad hli2-restore-journal.service"; return 1; }
  assert_file_contains "$u" "Type=oneshot" || return 1
  assert_file_contains "$u" "Before=docker.service" "se ejecuta antes de que Docker inicie contenedores" || return 1
  assert_file_contains "$u" "DefaultDependencies=no" || return 1
  assert_file_contains "$u" "After=local-fs.target" || return 1
  assert_file_contains "$u" "RequiresMountsFor=$APPDATA_ROOT $BACKUP_STATE_DIR $SECRETS_DIR" || return 1
  assert_file_contains "$u" "ExecStart=$BACKUP_INSTALL_DIR/bin/hli2-backup journal-recover" "desde la copia root-owned" || return 1
  assert_file_contains "$u" "WantedBy=multi-user.target" || return 1
  assert_file_not_contains "$u" "docker start" || return 1
  [[ -n "$(_bk_calls '^sudo\tsystemctl\tenable\thli2-restore-journal.service$')" ]] || { fail "no habilitó la unidad"; return 1; }
  # La unidad de los contenedores sigue DESPUÉS de Docker.
  assert_file_contains "$HLI2_SYSTEMD_DIR/hli2-backup-recover.service" "After=docker.service" || return 1
}

# --- W4: "no hay repositorio" solo ante una señal explícita -----------------------------------------

test_backup_init_r2_access_or_network_errors_never_initialize() {
  _bk_prepare
  _bk_r2
  local kind
  for kind in 403 badkey sig timeout refused bucket dns; do
    rm -f "$BACKUP_ROOT/config"; : > "$STUB_CALL_LOG"
    export STUB_RESTIC_CAT_ERROR="$kind"
    if _bk_run init >/dev/null 2>&1; then fail "[$kind] debió negarse"; return 1; fi
    [[ -z "$(_bk_calls '^restic\t(.*\t)?init')" ]] || { fail "[$kind] no debió inicializar nada"; return 1; }
    [[ ! -e "$BACKUP_ROOT/config" ]] || { fail "[$kind] no debe quedar nada inicializado"; return 1; }
  done
}

test_backup_init_uses_exit_code_10_when_restic_provides_it() {
  _bk_prepare
  _bk_r2
  rm -f "$BACKUP_ROOT/config"
  export STUB_RESTIC_CAT_EXIT10=1
  _bk_run init || { fail "con el código 10 (el repositorio no existe) debió inicializar"; return 1; }
  assert_eq "2" "$(_bk_calls '^restic\t(.*\t)?init' | wc -l | tr -d ' ')" "local y R2" || return 1
}

test_backup_init_a_random_account_id_containing_403_does_not_confuse_the_detection() {
  _bk_prepare
  _bk_root_write restic.env "RESTIC_REPOSITORY=s3:https://40340340340340340340340340340340.r2.cloudflarestorage.com/bkt
AWS_ACCESS_KEY_ID=${_BK_SECRET_KEY}
AWS_SECRET_ACCESS_KEY=${_BK_SECRET_VAL}
AWS_DEFAULT_REGION=auto
"
  rm -f "$BACKUP_ROOT/config"
  _bk_run init || { fail "el id de cuenta no debe leerse como un 403"; return 1; }
  assert_eq "2" "$(_bk_calls '^restic\t(.*\t)?init' | wc -l | tr -d ' ')" || return 1
}

test_backup_init_verifies_an_existing_local_repo_with_the_password() {
  _bk_prepare
  export STUB_RESTIC_CAT_WRONG_PW=1
  if _bk_run init; then fail "debió negarse: la contraseña no abre el repositorio local"; return 1; fi
  assert_contains "$(cat "$LOG_DIR/backup.log")" "no abre el repositorio local" || return 1
  unset STUB_RESTIC_CAT_WRONG_PW
  _bk_run init || { fail "con la contraseña correcta debió funcionar"; return 1; }
}

# --- S-D: recuperación ante un desastre sin R2 -----------------------------------------------------

test_backup_setup_disaster_recovery_without_r2_and_without_a_local_repo_creates_nothing() {
  _rs_prepare
  _bk_setup_env
  export STUB_SUDO_RUN_ENTRYPOINT="init"
  echo "existing" > "$DIALOG_MENU_QUEUE"
  printf '%s\n%s\n' "la-contrasena-sin-verificar-12345" "la-contrasena-sin-verificar-12345" > "$DIALOG_PASSWORDBOX_QUEUE"
  : > "$DIALOG_YESNO_QUEUE"                                # sin R2
  if timeout 30 bash "$RS_CODE/modules/backup-setup.sh"; then fail "debió detenerse"; return 1; fi
  assert_contains "$(_bk_calls '^dialog\t')" "necesita la copia externa" "explica que la recuperación necesita R2" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?init')" && ! -e "$BACKUP_ROOT/config" ]] || { fail "no debió crear un repositorio nuevo en silencio"; return 1; }
  [[ -z "$(_bk_calls "hli2-backup\tinit")" ]] || { fail "ni siquiera llamar a init"; return 1; }
  assert_file_contains "$STATE_FILE" "backup-dr-pending" "la marca sigue: nada se verificó" || return 1
}

test_backup_setup_disaster_recovery_with_a_local_repo_verifies_the_password_against_it() {
  _rs_prepare
  _bk_setup_env
  export STUB_SUDO_RUN_ENTRYPOINT="init"
  mkdir -p "$BACKUP_ROOT"; : > "$BACKUP_ROOT/config"           # el repositorio local existe (disco recuperado)
  echo "existing" > "$DIALOG_MENU_QUEUE"
  printf '%s\n%s\n' "la-contrasena-incorrecta-123456" "la-contrasena-incorrecta-123456" > "$DIALOG_PASSWORDBOX_QUEUE"
  : > "$DIALOG_YESNO_QUEUE"
  export STUB_RESTIC_CAT_WRONG_PW=1
  if timeout 30 bash "$RS_CODE/modules/backup-setup.sh"; then fail "con la contraseña equivocada debió fallar"; return 1; fi
  assert_file_contains "$STATE_FILE" "backup-dr-pending" "sin verificar: la marca se conserva" || return 1
  unset STUB_RESTIC_CAT_WRONG_PW
  echo "existing" > "$DIALOG_MENU_QUEUE"
  printf '%s\n%s\n' "la-contrasena-correcta-1234567" "la-contrasena-correcta-1234567" > "$DIALOG_PASSWORDBOX_QUEUE"
  timeout 30 bash "$RS_CODE/modules/backup-setup.sh" || { fail "con la contraseña correcta debió funcionar"; return 1; }
  assert_file_not_contains "$STATE_FILE" "backup-dr-pending" "verificada contra el repositorio local" || return 1
}

test_backup_unmark_is_atomic_and_keeps_the_other_lines() {
  _rs_prepare
  printf 'uno\nbackup-dr-pending\ndos\n' > "$STATE_FILE"
  local inode_before inode_after
  inode_before="$(stat -c %i "$STATE_FILE")"
  ( source "$RS_CODE/modules/backup-setup.sh"; _backup_unmark backup-dr-pending ) || { fail "_backup_unmark falló"; return 1; }
  inode_after="$(stat -c %i "$STATE_FILE")"
  assert_eq "uno
dos" "$(cat "$STATE_FILE")" || return 1
  # Escritura atómica = archivo nuevo + renombrado: el i-nodo cambia (un 'cat > archivo'
  # lo trunca y reescribe en el mismo, y una interrupción deja el estado a medias).
  [[ "$inode_before" != "$inode_after" ]] || { fail "el estado se reescribió en el mismo archivo (no atómico)"; return 1; }
  assert_eq "" "$(_bk_files_in "$STATE_DIR" '/state$')" "sin temporales sobrantes" || return 1
  # Y sin el archivo, no hace nada ni falla.
  rm -f "$STATE_FILE"
  ( source "$RS_CODE/modules/backup-setup.sh"; _backup_unmark backup-dr-pending ) || { fail "sin estado no debe fallar"; return 1; }
}

# ==================================================================================================
# Tercera revisión: .failed bloquea de forma persistente, journal-recover visible, unidades
# validadas, bucket nuevo con respuesta ambigua, sync obligatorio
# ==================================================================================================

_rs_failed_journal_for_vaultwarden() {
  local d="$APPDATA_ROOT/vaultwarden/data" old="$APPDATA_ROOT/vaultwarden/data.hli2-before-restore-20261006-040000"
  mv "$d" "$old"
  printf '%s\t%s\t1\n' "$d" "$old" > "$BACKUP_STATE_DIR/restore-swap-journal.failed"
  chmod 600 "$BACKUP_STATE_DIR/restore-swap-journal.failed"
}

test_restore_failed_journal_keeps_blocking_only_the_affected_containers_on_every_recover() {
  _rs_prepare
  _rs_failed_journal_for_vaultwarden
  : > "$STUB_DOCKER_STATE_DIR/vaultwarden.stopped"; : > "$STUB_DOCKER_STATE_DIR/adguard.stopped"
  printf 'vaultwarden\nadguard\n' > "$BACKUP_STATE_DIR/recovery-containers"
  # Dos llamadas seguidas: el bloqueo no vale solo para la primera.
  _rs_run recover || true
  _rs_run recover || true
  _bk_run run || true
  [[ -z "$(_bk_calls '^docker\tstart\tvaultwarden$')" ]] || { fail "vaultwarden (sus datos están a medias) no debe iniciarse nunca mientras exista el .failed"; return 1; }
  [[ -n "$(_bk_calls '^docker\tstart\tadguard$')" ]] || { fail "AdGuard (DNS de la casa) no es rehén de un servicio ajeno: debe iniciarse"; return 1; }
  [[ ! -e "$STUB_DOCKER_STATE_DIR/adguard.stopped" && -e "$STUB_DOCKER_STATE_DIR/vaultwarden.stopped" ]] || { fail "estado final de los contenedores incorrecto"; return 1; }
  assert_contains "$(cat "$BACKUP_STATE_DIR/recovery-containers")" "vaultwarden" "sigue en la lista de recuperación" || return 1
  assert_not_contains "$(cat "$BACKUP_STATE_DIR/recovery-containers")" "adguard" || return 1
  assert_contains "$(cat "$LOG_DIR/backup.log")" "NO se inicia 'vaultwarden'" || return 1
}

test_backup_run_skips_retention_while_a_failed_journal_exists() {
  _bk_prepare
  _bk_r2
  printf '%s\t%s\t1\n' "$APPDATA_ROOT/vaultwarden/data" "$APPDATA_ROOT/vaultwarden/data.hli2-before-restore-20261006-040000" > "$BACKUP_STATE_DIR/restore-swap-journal.failed"
  _bk_run run || { fail "el backup sigue haciéndose"; return 1; }
  [[ -n "$(_bk_calls '^restic\t(.*\t)?backup\t')" ]] || { fail "las fotos se siguen tomando"; return 1; }
  [[ -z "$(_bk_calls '^restic\t(.*\t)?forget\t')" ]] || { fail "no se debe podar NINGÚN repositorio (podría borrar las fotos buenas)"; return 1; }
  assert_eq "warning" "$(_bk_status result)" || return 1
  assert_contains "$(_bk_status message)" "retención omitida" || return 1
}

test_restore_dashboard_shows_a_prominent_message_for_a_failed_journal() {
  _bk_prepare
  printf 'x\t/y\t1\n' > "$BACKUP_STATE_DIR/restore-swap-journal.failed"
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; backup_status_summary ) )"
  assert_contains "$out" "RESTAURACIÓN SIN REVERTIR" || return 1
  assert_contains "$out" "restore-swap-journal.failed" "dice qué archivo borrar" || return 1
  assert_contains "$out" "VALIDACION.md" "y dónde están los pasos exactos" || return 1
}

test_restore_journal_recover_fails_visibly_when_it_cannot_take_the_lock() {
  _rs_prepare
  local d="$APPDATA_ROOT/vaultwarden/data" old="$APPDATA_ROOT/vaultwarden/data.hli2-before-restore-20261006-040000"
  mv "$d" "$old"
  printf '%s\t%s\t1\n' "$d" "$old" > "$BACKUP_STATE_DIR/restore-swap-journal"
  flock "$BACKUP_STATE_DIR/lock" sleep 5 &
  local holder=$! rc=0
  sleep 0.3
  HLI2_BACKUP_LOCK_WAIT=1 _rs_run journal-recover || rc=$?
  kill "$holder" 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || { fail "sin el bloqueo debe salir con error (la unidad de arranque tiene que fallar a la vista)"; return 1; }
  [[ -f "$BACKUP_STATE_DIR/restore-swap-journal" && -d "$old" ]] || { fail "no debió tocar nada"; return 1; }
  [[ -z "$(_bk_calls '^sudo\t(-n\t)?mv\t')" ]] || { fail "no debió mover nada"; return 1; }
  # 'recover' (ExecStopPost) sigue siendo benigno ante el bloqueo.
  rc=0
  flock "$BACKUP_STATE_DIR/lock" sleep 5 &
  holder=$!; sleep 0.3
  HLI2_BACKUP_LOCK_WAIT=1 _rs_run recover || rc=$?
  kill "$holder" 2>/dev/null || true
  assert_eq "0" "$rc" "recover ante el bloqueo no cambia su comportamiento" || return 1
}

test_backup_setup_validates_all_unit_paths_before_writing_any_unit() {
  _rs_prepare
  _bk_setup_env
  local var val rc
  for var in APPDATA_ROOT BACKUP_ROOT HLI2_BACKUP_STATE_DIR HLI2_BACKUP_INSTALL_DIR HLI2_SECRETS_DIR; do
    for val in "$HLI2_TEST_SCRATCH/con espacio" "$HLI2_TEST_SCRATCH/con%porciento" "$HLI2_TEST_SCRATCH/con\"comilla" "$HLI2_TEST_SCRATCH/con'simple"; do
      rc=0
      ( export "$var=$val"; source "$RS_CODE/modules/backup-setup.sh"; _backup_install_units ) >/dev/null 2>&1 || rc=$?
      [[ "$rc" -ne 0 ]] || { fail "[$var=$val] debió rechazarse"; return 1; }
      assert_eq "" "$(_bk_files_in "$HLI2_SYSTEMD_DIR")" "[$var=$val] no debe quedar ninguna unidad escrita" || return 1
    done
  done
  [[ -z "$(_bk_calls 'systemctl\tenable')" ]] || { fail "no debió habilitar nada"; return 1; }
}

# --- S1: bucket nuevo con una respuesta ambigua de restic -------------------------------------------

test_backup_init_ambiguous_r2_answer_exits_20_and_assume_new_initializes() {
  _bk_prepare
  _bk_r2
  rm -f "$BACKUP_ROOT/config"
  export STUB_RESTIC_CAT_ERROR=weird
  local rc=0
  _bk_run init >/dev/null 2>&1 || rc=$?
  assert_eq "20" "$rc" "respuesta ambigua: código 20 para que backup-setup pregunte" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?init')" && ! -e "$BACKUP_ROOT/config" ]] || { fail "sin confirmación no se inicializa nada"; return 1; }
  : > "$STUB_CALL_LOG"
  _bk_run init --r2-assume-new || { fail "con --r2-assume-new debió inicializar"; return 1; }
  assert_eq "2" "$(_bk_calls '^restic\t(.*\t)?init' | wc -l | tr -d ' ')" "local y R2" || return 1
}

test_backup_init_assume_new_never_overrides_access_errors_wrong_passwords_or_bad_flags() {
  _bk_prepare
  _bk_r2
  rm -f "$BACKUP_ROOT/config"
  local kind rc
  for kind in 403 badkey sig timeout refused bucket dns; do
    export STUB_RESTIC_CAT_ERROR="$kind"; : > "$STUB_CALL_LOG"
    rc=0; _bk_run init --r2-assume-new >/dev/null 2>&1 || rc=$?
    [[ "$rc" -ne 0 && "$rc" -ne 20 ]] || { fail "[$kind] con la bandera sigue siendo un error normal (rc=$rc)"; return 1; }
    [[ -z "$(_bk_calls '^restic\t(.*\t)?init')" ]] || { fail "[$kind] no debió inicializar"; return 1; }
  done
  unset STUB_RESTIC_CAT_ERROR
  export STUB_RESTIC_CAT_WRONG_PW=1 STUB_RESTIC_R2_INITIALIZED=1
  if _bk_run init --r2-assume-new >/dev/null 2>&1; then fail "contraseña equivocada + bandera debió fallar"; return 1; fi
  unset STUB_RESTIC_CAT_WRONG_PW
  rc=0; _bk_run init --r2-assume-new --delete >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "una opción desconocida se rechaza" || return 1
}

test_backup_init_keeps_the_not_found_marker_even_when_its_line_has_a_url() {
  _bk_prepare
  _bk_root_write restic.env "RESTIC_REPOSITORY=s3:https://40340340340340340340340340340340.r2.cloudflarestorage.com/bkt
AWS_ACCESS_KEY_ID=${_BK_SECRET_KEY}
AWS_SECRET_ACCESS_KEY=${_BK_SECRET_VAL}
AWS_DEFAULT_REGION=auto
"
  rm -f "$BACKUP_ROOT/config"
  export STUB_RESTIC_CAT_ERROR=missingurl
  _bk_run init || { fail "la línea 'Fatal ... does not exist' con una URL debe reconocerse (se quita la URL, no la línea)"; return 1; }
  assert_eq "2" "$(_bk_calls '^restic\t(.*\t)?init' | wc -l | tr -d ' ')" || return 1
}

_rs_setup_new_install_with_ambiguous_r2() {
  _rs_prepare
  _bk_setup_env
  export STUB_SUDO_RUN_ENTRYPOINT="init" STUB_RESTIC_CAT_ERROR=weird
  printf '%s\n%s\n%s\n' "https://${_BK_ACCOUNT}.r2.cloudflarestorage.com" "hli2-bkt" "$_BK_SECRET_KEY" > "$DIALOG_INPUTBOX_QUEUE"
  echo "$_BK_SECRET_VAL" > "$DIALOG_PASSWORDBOX_QUEUE"
}

test_backup_setup_asks_whether_the_bucket_is_new_and_only_a_yes_initializes() {
  _rs_setup_new_install_with_ambiguous_r2
  printf 'yes\nyes\nyes\n' > "$DIALOG_YESNO_QUEUE"      # contraseña guardada / configurar R2 / "¿bucket nuevo y vacío?"
  timeout 30 bash "$RS_CODE/modules/backup-setup.sh" || { fail "con la confirmación debió terminar bien"; return 1; }
  assert_contains "$(_bk_calls '^dialog\t')" "¿El bucket es nuevo y está vacío?" || return 1
  [[ -n "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\tinit\t--r2-assume-new\$")" ]] || { fail "debió llamar a init --r2-assume-new"; return 1; }
  [[ -n "$(_bk_calls '^dialog\t--defaultno\t.*bucket es nuevo')" ]] || { fail "la pregunta es defaultno"; return 1; }
}

test_backup_setup_bucket_question_defaults_to_no_and_initializes_nothing() {
  _rs_setup_new_install_with_ambiguous_r2
  printf 'yes\nyes\nno\n' > "$DIALOG_YESNO_QUEUE"
  if timeout 30 bash "$RS_CODE/modules/backup-setup.sh"; then fail "con 'No' debió fallar"; return 1; fi
  [[ -z "$(_bk_calls 'init\t--r2-assume-new')" ]] || { fail "sin confirmación no se llama con la bandera"; return 1; }
  [[ -z "$(_bk_calls '^restic\t(.*\t)?init')" ]] || { fail "no debió inicializar nada"; return 1; }
}

test_backup_setup_never_offers_the_new_bucket_question_in_a_disaster_recovery() {
  _rs_prepare
  _bk_setup_env
  export STUB_SUDO_RUN_ENTRYPOINT="init" STUB_RESTIC_CAT_ERROR=weird
  echo "existing" > "$DIALOG_MENU_QUEUE"
  printf '%s\n%s\n%s\n' "la-contrasena-de-recuperacion-12345" "la-contrasena-de-recuperacion-12345" "$_BK_SECRET_VAL" > "$DIALOG_PASSWORDBOX_QUEUE"
  printf '%s\n%s\n%s\n' "https://${_BK_ACCOUNT}.r2.cloudflarestorage.com" "hli2-bkt" "$_BK_SECRET_KEY" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'yes\nyes\nyes\n' > "$DIALOG_YESNO_QUEUE"
  if timeout 30 bash "$RS_CODE/modules/backup-setup.sh"; then fail "ambiguo en una recuperación debió fallar"; return 1; fi
  assert_not_contains "$(_bk_calls '^dialog\t')" "¿El bucket es nuevo y está vacío?" "en una recuperación nunca se ofrece" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?init')" ]] || { fail "no debió inicializar nada"; return 1; }
  assert_file_contains "$STATE_FILE" "backup-dr-pending" || return 1
}

# --- S2: el sync del diario es obligatorio -----------------------------------------------------------

test_restore_aborts_before_any_move_when_the_journal_cannot_be_synced() {
  _rs_prepare
  export STUB_SYNC_FAIL=1
  if _rs_run restore --source local --snapshot "$_RS_FULL_NEW" --target vaultwarden; then fail "debió abortar"; return 1; fi
  [[ -z "$(_bk_calls '^sudo\t-n\tmv\t-T\t')" ]] || { fail "sin diario durable no se hace ningún mv: $(_bk_calls '^sudo\t-n\tmv\t-T\t')"; return 1; }
  assert_eq "current-vaultwarden/data" "$(_rs_content "$APPDATA_ROOT/vaultwarden/data/file.txt")" || return 1
  [[ ! -e "$BACKUP_STATE_DIR/restore-swap-journal" ]] || { fail "no queda un diario a medias"; return 1; }
  assert_eq "error" "$(_rs_status result)" || return 1
  [[ -n "$(_bk_calls '^docker\tstart\tvaultwarden$')" ]] || { fail "el contenedor ya detenido debe volver a iniciar"; return 1; }
}

# --- S3: capa antigua de copias de secretos -----------------------------------------------------------

test_restore_validators_accept_the_legacy_old_secrets_layout() {
  _rs_prepare
  local legacy="$BACKUP_STATE_DIR/restore-old-secrets/vaultwarden.env.hli2-before-restore-20261006-040000" out
  out="$( ( source "$RS_CODE/lib/core.sh"
    _restore_old_name_ok "$SECRETS_DIR/vaultwarden.env" "$legacy" && echo name-ok
    echo "dst=$(_restore_old_to_dst "$legacy")"
    _restore_old_name_ok "$SECRETS_DIR/vaultwarden.env" "$BACKUP_STATE_DIR/otro/vaultwarden.env.hli2-before-restore-20261006-040000" || echo otro-rechazado ) )"
  assert_contains "$out" "name-ok" || return 1
  assert_contains "$out" "dst=$SECRETS_DIR/vaultwarden.env" || return 1
  assert_contains "$out" "otro-rechazado" || return 1
  # Y la recuperación puede devolver un .env desde la capa antigua.
  mkdir -p "$BACKUP_STATE_DIR/restore-old-secrets"
  _rs_secrets
  chmod u+rwx "$SECRETS_DIR"; mv "$SECRETS_DIR/vaultwarden.env" "$legacy"; chmod 000 "$SECRETS_DIR"
  printf '%s\t%s\t1\n' "$SECRETS_DIR/vaultwarden.env" "$legacy" > "$BACKUP_STATE_DIR/restore-swap-journal"
  _rs_run recover || { fail "recover falló"; return 1; }
  assert_eq "VW=OLD" "$(_rs_secret vaultwarden.env)" || return 1
}

# --- S4: un 'running' viejo no se reescribe --------------------------------------------------------

test_backup_run_skipped_over_a_stale_running_status_marks_it_interrupted() {
  _bk_prepare
  printf 'timestamp=%s\nresult=running\nlocal=pending\ncloud=pending\ncheck=pending\nsnapshot_full=\nsnapshot_cloud=\nmessage=\n' "$(date -d '5 hours ago' -Is)" > "$BACKUP_STATE_DIR/backup-status"
  _rs_hold_lock_with_restore_running
  HLI2_BACKUP_LOCK_WAIT=1 _bk_run run || { kill "$RS_LOCK_HOLDER" 2>/dev/null; fail "debió terminar bien"; return 1; }
  kill "$RS_LOCK_HOLDER" 2>/dev/null || true
  assert_eq "interrupted" "$(_bk_status result)" "un running de un backup muerto no se deja como 'en curso'" || return 1
}

# --- S5: el helper de archivos no confunde un error de rg con 'no hay archivos' -----------------------

test_bk_files_in_reports_rg_errors_instead_of_hiding_them() {
  assert_contains "$(_bk_files_in "$HLI2_TEST_SCRATCH/no-existe")" "RG-ERROR" || return 1
  mkdir -p "$HLI2_TEST_SCRATCH/vacio"
  assert_eq "" "$(_bk_files_in "$HLI2_TEST_SCRATCH/vacio")" || return 1
  echo x > "$HLI2_TEST_SCRATCH/vacio/a"; echo x > "$HLI2_TEST_SCRATCH/vacio/.b"
  assert_contains "$(_bk_files_in "$HLI2_TEST_SCRATCH/vacio")" "/a" || return 1
  assert_not_contains "$(_bk_files_in "$HLI2_TEST_SCRATCH/vacio" '/\.')" ".b" || return 1
  assert_contains "$(_bk_files_in "$HLI2_TEST_SCRATCH/vacio" '(')" "RG-ERROR" "una expresión inválida también se reporta" || return 1
}
