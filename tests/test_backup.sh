#!/usr/bin/env bash
# Tests de los backups (lib/backup.sh, bin/hli2-backup, modules/backup-setup.sh,
# modules/backup-now.sh) con restic/docker/sudo/dialog/stat stubbeados. El
# backup real corre como root; acá corre como el usuario del test con
# HLI2_BACKUP_ALLOW_NONROOT=1 (solo para tests) y el entrypoint como proceso
# aparte ('bash bin/hli2-backup'): así se prueba también el trap EXIT/TERM, que
# no se vería dentro del shell del test (donde 'set -e' queda ignorado).

_BK_SECRET_KEY="AKIATESTKEY0000000001"
_BK_SECRET_VAL="SECRETVALUE-xyz-0123456789abcdef"
_BK_ACCOUNT="0123456789abcdef0123456789abcdef"

# Escribe un archivo en el área root-only simulada (0600, área 000).
_bk_root_write() {
  chmod u+rwx "$SECRETS_DIR"
  printf '%s' "$2" > "$SECRETS_DIR/$1"
  chmod 0600 "$SECRETS_DIR/$1"
  chmod 000 "$SECRETS_DIR"
}

_bk_prepare() {
  export HLI2_BACKUP_ALLOW_NONROOT=1
  export HLI2_BACKUP_EXPECT_UID="$(id -u)"       # el código de los tests es del usuario
  export HLI2_BACKUP_RESTART_SETTLE=0 HLI2_BACKUP_RESTART_POLL=1 HLI2_BACKUP_RESTART_WAIT=2
  export STUB_RESTIC_HAS_FULL=1                  # sin esto: pasada previa en vivo
  export STUB_RECOVERY_FILE="$BACKUP_STATE_DIR/recovery-containers"
  mkdir -p "$BACKUP_STATE_DIR" "$MEDIA_ROOT"
  export STUB_MOUNTPOINTS="$MEDIA_ROOT"
  export STUB_DOCKER_STATE_DIR="$HLI2_TEST_SCRATCH/dockerstate"
  export STUB_TEXTBOX_LOG="$HLI2_TEST_SCRATCH/textbox.log"
  mkdir -p "$STUB_DOCKER_STATE_DIR"
  : > "$STUB_TEXTBOX_LOG"
  mkdir -p "$APPDATA_ROOT"/{vaultwarden/data,jellyfin/config,jellyfin/cache,opencloud/config,opencloud/data,homeassistant/config,adguard/conf,adguard/work,qbittorrent/config}
  mkdir -p "$BACKUP_ROOT"
  : > "$BACKUP_ROOT/config"
  _bk_root_write restic-password "test-restic-password-123"
}

_bk_r2() {
  _bk_root_write restic.env "RESTIC_REPOSITORY=s3:https://${_BK_ACCOUNT}.r2.cloudflarestorage.com/bkt
AWS_ACCESS_KEY_ID=${_BK_SECRET_KEY}
AWS_SECRET_ACCESS_KEY=${_BK_SECRET_VAL}
AWS_DEFAULT_REGION=auto
"
}

_bk_run() { bash "$REPO_ROOT/bin/hli2-backup" "$@"; }

# Líneas del log de llamadas que empiezan con $1 (patrón de grep -P).
_bk_calls() { grep -P "$1" "$STUB_CALL_LOG" || true; }
_bk_line_no() { grep -nP "$1" "$STUB_CALL_LOG" | head -1 | cut -d: -f1; }
_bk_last_line_no() { grep -nP "$1" "$STUB_CALL_LOG" | tail -1 | cut -d: -f1; }
_bk_status() { grep "^$1=" "$BACKUP_STATE_DIR/backup-status" | head -1 | cut -d= -f2-; }

# ¿La línea $1 tiene a $2 como argumento completo (entre tabuladores)?
_bk_has_arg() { [[ "$1"$'\t' == *$'\t'"$2"$'\t'* ]]; }

_bk_snapshot_line() { grep -P "^restic\t(.*\t)?backup\t.*--tag\t$1\t" "$STUB_CALL_LOG" | head -1; }

# --- Registro de servicios --------------------------------------------------------

test_backup_registry_kinds_and_exclusions() {
  local out
  out="$( (
    source "$REPO_ROOT/lib/core.sh"
    echo "ha=$(service_get homeassistant BACKUP_KIND)"
    echo "ag=$(service_get adguard BACKUP_KIND)"
    echo "jf_ex=$(service_get jellyfin BACKUP_EXCLUDE)"
    echo "oc_lo=$(service_get opencloud BACKUP_LOCAL_ONLY)"
    echo "vw_ex=[$(service_get vaultwarden BACKUP_EXCLUDE)]"
  ) )" || return 1
  assert_contains "$out" "ha=sqlite" || return 1
  assert_contains "$out" "ag=sqlite" || return 1
  assert_contains "$out" "jf_ex=$APPDATA_ROOT/jellyfin/cache" || return 1
  assert_contains "$out" "oc_lo=$APPDATA_ROOT/opencloud/data" || return 1
  assert_contains "$out" "vw_ex=[]" "un servicio sin exclusiones no emite nada" || return 1
}

# --- Ventana de parada -----------------------------------------------------------------

test_backup_stops_only_sqlite_running_containers_and_restarts_them() {
  _bk_prepare
  export STUB_DOCKER_NOT_RUNNING="adguard"
  _bk_run run || { fail "el backup debió terminar bien"; return 1; }

  local c
  for c in vaultwarden jellyfin homeassistant; do
    [[ -n "$(_bk_calls "^docker\tstop\t.*\t$c\$")" ]] || { fail "no detuvo $c"; return 1; }
    [[ -n "$(_bk_calls "^docker\tstart\t$c\$")" ]] || { fail "no volvió a iniciar $c"; return 1; }
  done
  # Solo los sqlite: nada de opencloud/qbittorrent; y adguard ya estaba parado.
  for c in opencloud qbittorrent adguard cloudflared; do
    [[ -z "$(_bk_calls "^docker\t(stop|start)\t.*$c")" ]] || { fail "no debía tocar $c"; return 1; }
  done

  # Orden: todas las paradas < primera foto; todos los arranques > última foto
  # local y antes de la retención (los servicios no esperan la subida a R2).
  local last_stop first_snap last_snap first_start first_forget
  last_stop="$(_bk_last_line_no '^docker\tstop\t')"
  first_snap="$(_bk_line_no '^restic\t(.*\t)?backup\t')"
  last_snap="$(_bk_last_line_no '^restic\t(.*\t)?backup\t')"
  first_start="$(_bk_line_no '^docker\tstart\t')"
  first_forget="$(_bk_line_no '^restic\t(.*\t)?forget\t')"
  (( last_stop < first_snap )) || { fail "las paradas deben ir antes de las fotos"; return 1; }
  (( first_start > last_snap )) || { fail "los arranques deben ir después de las fotos"; return 1; }
  (( first_start < first_forget )) || { fail "los servicios deben estar arriba antes de la retención"; return 1; }
}

test_backup_restarts_containers_when_restic_fails() {
  _bk_prepare
  export STUB_RESTIC_FAIL="backup"
  if _bk_run run; then fail "debió fallar si restic falla"; return 1; fi
  local c
  for c in vaultwarden jellyfin homeassistant adguard; do
    [[ -n "$(_bk_calls "^docker\tstart\t$c\$")" ]] || { fail "no reinició $c tras el fallo de restic"; return 1; }
  done
  assert_eq "error" "$(_bk_status result)" "estado" || return 1
  assert_eq "error" "$(_bk_status local)" || return 1
}

test_backup_restarts_containers_when_interrupted() {
  # TERM en plena ventana de parada (set -e / señal): el trap EXIT del proceso
  # real debe levantar lo detenido. Proceso aparte: en el shell del test el
  # trap y 'set -e' no se comportan igual.
  _bk_prepare
  export STUB_RESTIC_KILL_ON="backup"
  _bk_run run || true
  local left
  left="$(rg --files "$STUB_DOCKER_STATE_DIR" 2>/dev/null || true)"
  [[ -z "$left" ]] || { fail "quedaron contenedores detenidos: $left"; return 1; }
  [[ -n "$(_bk_calls '^docker\tstart\t')" ]] || { fail "no hubo ningún docker start"; return 1; }
}

test_backup_stop_failure_skips_snapshot_and_restarts() {
  _bk_prepare
  export STUB_DOCKER_FAIL_STOP="jellyfin"
  if _bk_run run; then fail "debió fallar si un contenedor no se detiene"; return 1; fi
  [[ -z "$(_bk_calls '^restic\t(.*\t)?backup\t')" ]] || { fail "no debió tomar fotos inconsistentes"; return 1; }
  local c
  for c in adguard homeassistant jellyfin; do
    [[ -n "$(_bk_calls "^docker\tstart\t$c\$")" ]] || { fail "no reinició $c"; return 1; }
  done
  [[ -z "$(_bk_calls '^docker\tstart\tvaultwarden$')" ]] || { fail "vaultwarden nunca se detuvo"; return 1; }
  assert_eq "error" "$(_bk_status result)" || return 1
}

# --- Fotos: tags y exclusiones ------------------------------------------------------------

test_backup_two_snapshots_with_tags_and_cloud_excludes_opencloud_data() {
  _bk_prepare
  _bk_r2
  _bk_run run || { fail "el backup debió terminar bien"; return 1; }

  local full cloud oc="$APPDATA_ROOT/opencloud/data" jc="$APPDATA_ROOT/jellyfin/cache"
  full="$(_bk_snapshot_line full)"
  cloud="$(_bk_snapshot_line cloud)"
  [[ -n "$full" && -n "$cloud" ]] || { fail "faltan las dos fotos (full/cloud)"; return 1; }
  assert_eq "2" "$(_bk_calls '^restic\t(.*\t)?backup\t' | wc -l | tr -d ' ')" "exactamente dos fotos" || return 1

  # full: incluye opencloud/data como ruta; cloud: NO (solo como --exclude).
  _bk_has_arg "$full" "$oc" || { fail "la foto full debe incluir opencloud/data"; return 1; }
  if _bk_has_arg "$cloud" "$oc"; then fail "la foto cloud NO debe incluir opencloud/data como ruta"; return 1; fi
  _bk_has_arg "$cloud" "--exclude=$oc" || { fail "la foto cloud debe excluir opencloud/data"; return 1; }
  _bk_has_arg "$cloud" "$APPDATA_ROOT/opencloud/config" || { fail "cloud conserva opencloud/config"; return 1; }
  _bk_has_arg "$cloud" "$APPDATA_ROOT/vaultwarden/data" || { fail "cloud incluye vaultwarden"; return 1; }

  # La caché de Jellyfin no entra en ninguna; la contraseña de restic tampoco.
  local l
  for l in "$full" "$cloud"; do
    if _bk_has_arg "$l" "$jc"; then fail "la caché de jellyfin no se respalda"; return 1; fi
    _bk_has_arg "$l" "--exclude=$jc" || { fail "falta excluir la caché de jellyfin"; return 1; }
    _bk_has_arg "$l" "--exclude=$SECRETS_DIR/restic-password" || { fail "la contraseña no debe respaldarse"; return 1; }
    _bk_has_arg "$l" "$SECRETS_DIR" || { fail "/etc/hli2 se respalda"; return 1; }
    _bk_has_arg "$l" "$STATE_DIR" || { fail "el estado del HLI se respalda"; return 1; }
    [[ "$l" != *$'\t'"$MEDIA_ROOT"* ]] || { fail "la media no se respalda"; return 1; }
  done

  # Misma ventana: copia a R2 de lo etiquetado 'cloud', después de levantar.
  local copy last_start
  copy="$(grep -P '^restic\t(.*\t)?copy\t' "$STUB_CALL_LOG" | head -1)"
  [[ -n "$copy" ]] || { fail "no hubo restic copy a R2"; return 1; }
  _bk_has_arg "$copy" "--from-repo" || return 1
  _bk_has_arg "$copy" "$BACKUP_ROOT" || return 1
  _bk_has_arg "$copy" "--from-password-file" || return 1
  _bk_has_arg "$copy" "cloud" || return 1
  last_start="$(_bk_last_line_no '^docker\tstart\t')"
  (( last_start < $(_bk_line_no '^restic\t(.*\t)?copy\t') )) || { fail "la subida a R2 debe ocurrir con los servicios ya levantados"; return 1; }
  assert_eq "ab12cd01" "$(_bk_status snapshot_full)" || return 1
  assert_eq "ab12cd02" "$(_bk_status snapshot_cloud)" || return 1
}

test_backup_retention_on_both_repos_grouped_by_tags() {
  _bk_prepare
  _bk_r2
  _bk_run run || return 1
  local n l
  n="$(_bk_calls '^restic\t(.*\t)?forget\t' | wc -l | tr -d ' ')"
  assert_eq "2" "$n" "retención en local y en R2" || return 1
  while IFS= read -r l; do
    _bk_has_arg "$l" "--group-by" && _bk_has_arg "$l" "host,tags" || { fail "agrupar por host,tags: $l"; return 1; }
    _bk_has_arg "$l" "--keep-daily" && _bk_has_arg "$l" "7" || return 1
    _bk_has_arg "$l" "--keep-weekly" && _bk_has_arg "$l" "4" || return 1
    _bk_has_arg "$l" "--keep-monthly" && _bk_has_arg "$l" "6" || return 1
    _bk_has_arg "$l" "--prune" || return 1
  done < <(_bk_calls '^restic\t(.*\t)?forget\t')
}

test_backup_integrity_check_weekly() {
  _bk_prepare
  _bk_run run || return 1
  [[ -n "$(_bk_calls '^restic\t(.*\t)?check\t.*--read-data-subset=5%')" ]] || { fail "la primera corrida debe chequear una muestra"; return 1; }
  assert_eq "ok" "$(_bk_status check)" || return 1
  : > "$STUB_CALL_LOG"
  _bk_run run || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?check\t')" ]] || { fail "no debe volver a chequear antes de 7 días"; return 1; }
  assert_eq "skipped" "$(_bk_status check)" || return 1
  # Con la marca vieja, vuelve a tocar.
  touch -d '10 days ago' "$BACKUP_STATE_DIR/backup-last-check"
  _bk_run run || return 1
  [[ -n "$(_bk_calls '^restic\t(.*\t)?check\t')" ]] || { fail "pasada una semana debe chequear otra vez"; return 1; }
}

# --- Falla cerrado -------------------------------------------------------------------------------

test_backup_fails_closed_when_backup_root_is_on_root_device() {
  _bk_prepare
  export STUB_FAKE_MEDIA_DEV=1      # mismo dispositivo que '/'
  if _bk_run run; then fail "debió negarse a correr"; return 1; fi
  [[ -z "$(_bk_calls '^restic\t(.*\t)?(backup|copy|forget)\t')" ]] || { fail "no debe tocar restic"; return 1; }
  [[ -z "$(_bk_calls '^docker\tstop\t')" ]] || { fail "no debe detener contenedores"; return 1; }
  assert_eq "error" "$(_bk_status result)" || return 1
  assert_contains "$(_bk_status message)" "mismo disco que el sistema" || return 1
}

test_backup_init_fails_closed_on_root_device() {
  _bk_prepare
  rm -f "$BACKUP_ROOT/config"
  export STUB_FAKE_MEDIA_DEV=1
  if _bk_run init; then fail "init debió negarse"; return 1; fi
  [[ -z "$(_bk_calls '^restic\t(.*\t)?init')" ]] || { fail "no debe inicializar en el disco del sistema"; return 1; }
}

test_backup_fails_when_repo_not_initialized() {
  _bk_prepare
  rm -f "$BACKUP_ROOT/config"
  if _bk_run run; then fail "debió fallar sin repositorio"; return 1; fi
  assert_contains "$(_bk_status message)" "backup-setup" || return 1
  [[ -z "$(_bk_calls '^docker\tstop\t')" ]] || { fail "sin repo no se detiene nada"; return 1; }
}

# --- Secretos ------------------------------------------------------------------------------------

test_backup_secrets_never_in_argv_or_logs() {
  _bk_prepare
  _bk_r2
  _bk_run run || return 1

  assert_file_not_contains "$STUB_CALL_LOG" "$_BK_SECRET_VAL" "secreto de R2 fuera de argv" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "$_BK_SECRET_KEY" "Access Key fuera de argv" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "test-restic-password-123" "contraseña de restic fuera de argv" || return 1
  # (las líneas 'restic-env' son el registro del stub de lo recibido por entorno)
  if grep -v '^restic-env' "$STUB_CALL_LOG" | grep -qF "r2.cloudflarestorage.com"; then
    fail "el endpoint apareció en argv"; return 1
  fi
  if grep -rqF -e "$_BK_SECRET_VAL" -e "$_BK_SECRET_KEY" -e "test-restic-password-123" "$LOG_DIR" "$STATE_DIR" 2>/dev/null; then
    fail "un secreto apareció en logs o estado"; return 1
  fi

  # Sí llegan por el ENTORNO de restic, y solo en las llamadas a R2.
  local env_copy env_local
  env_copy="$(grep -P '^restic-env\tREPO=s3:' "$STUB_CALL_LOG" | head -1)"
  [[ -n "$env_copy" ]] || { fail "R2 no recibió el repositorio por entorno"; return 1; }
  assert_contains "$env_copy" "AWS_KEY_LEN=${#_BK_SECRET_KEY}" || return 1
  assert_contains "$env_copy" "AWS_SECRET_LEN=${#_BK_SECRET_VAL}" || return 1
  assert_contains "$env_copy" "PW_FILE=$SECRETS_DIR/restic-password" || return 1
  env_local="$(grep -P "^restic-env\tREPO=$BACKUP_ROOT\t" "$STUB_CALL_LOG" | head -1)"
  assert_contains "$env_local" "AWS_KEY_LEN=0" "el repo local no recibe claves de R2" || return 1
}

# --- Estado --------------------------------------------------------------------------------------

test_backup_status_ok_without_r2() {
  _bk_prepare
  _bk_run run || return 1
  assert_eq "ok" "$(_bk_status result)" || return 1
  assert_eq "ok" "$(_bk_status local)" || return 1
  assert_eq "not-configured" "$(_bk_status cloud)" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?copy\t')" ]] || { fail "sin R2 no hay copia"; return 1; }
  assert_eq "644" "$(stat -c %a "$BACKUP_STATE_DIR/backup-status")" "modo del estado" || return 1
  [[ "$(_bk_status timestamp)" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T ]] || { fail "timestamp inválido"; return 1; }
}

test_backup_status_records_cloud_copy_failure() {
  _bk_prepare
  _bk_r2
  export STUB_RESTIC_FAIL="copy"
  if _bk_run run; then fail "el servicio debe fallar si falla la copia externa"; return 1; fi
  assert_eq "error" "$(_bk_status result)" || return 1
  assert_eq "error" "$(_bk_status cloud)" || return 1
  assert_eq "ok" "$(_bk_status local)" "la copia local sí quedó" || return 1
  assert_eq "ab12cd01" "$(_bk_status snapshot_full)" || return 1
  assert_contains "$(_bk_status message)" "R2" || return 1
  # Y los servicios igual se levantaron antes.
  [[ -n "$(_bk_calls '^docker\tstart\tvaultwarden$')" ]] || return 1
}

test_backup_status_summary_for_dashboard() {
  local out
  mkdir -p "$BACKUP_STATE_DIR"
  out="$( ( source "$REPO_ROOT/lib/core.sh"; backup_status_summary ) )"
  assert_contains "$out" "sin backups todavía" || return 1
  printf 'timestamp=%s\nresult=error\nlocal=ok\ncloud=error\ncheck=skipped\nmessage=falló la copia externa a R2\n' \
    "$(date -Is)" > "$BACKUP_STATE_DIR/backup-status"
  out="$( ( source "$REPO_ROOT/lib/core.sh"; backup_status_summary ) )"
  assert_contains "$out" "ERROR" || return 1
  assert_contains "$out" "Copia externa : ERROR" || return 1
  assert_contains "$out" "Copia local   : correcto" || return 1
  assert_not_contains "$out" "AVISO" || return 1
  printf 'timestamp=%s\nresult=ok\nlocal=ok\ncloud=ok\n' "$(date -d '3 days ago' -Is)" > "$BACKUP_STATE_DIR/backup-status"
  out="$( ( source "$REPO_ROOT/lib/core.sh"; backup_status_summary ) )"
  assert_contains "$out" "AVISO" "backup atrasado" || return 1
}

# --- init ----------------------------------------------------------------------------------------

test_backup_init_creates_repos_and_is_idempotent() {
  _bk_prepare
  _bk_r2
  rm -f "$BACKUP_ROOT/config"
  _bk_run init || { fail "init falló"; return 1; }
  [[ -f "$BACKUP_ROOT/config" ]] || { fail "no inicializó el repo local"; return 1; }
  assert_eq "700" "$(stat -c %a "$BACKUP_ROOT")" "repo root 0700" || return 1
  assert_eq "2" "$(_bk_calls '^restic\t(.*\t)?init' | wc -l | tr -d ' ')" "init local + R2" || return 1
  : > "$STUB_CALL_LOG"
  _bk_run init || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?init')" ]] || { fail "no debe reinicializar"; return 1; }
}

# --- backup-setup ----------------------------------------------------------------------------------

_bk_setup_env() {
  _bk_prepare
  export HLI2_SYSTEMD_DIR="$HLI2_TEST_SCRATCH/systemd"
  mkdir -p "$HLI2_SYSTEMD_DIR"
  # Ni contraseña ni R2 todavía: es una instalación nueva.
  chmod u+rwx "$SECRETS_DIR"; rm -f "$SECRETS_DIR/restic-password"; chmod 000 "$SECRETS_DIR"
  rm -rf "$BACKUP_ROOT"
}

test_backup_setup_fresh_install_with_r2() {
  _bk_setup_env
  printf 'yes\nyes\n' > "$DIALOG_YESNO_QUEUE"      # guardó la contraseña / configurar R2
  printf '%s\n%s\n%s\n' "https://${_BK_ACCOUNT}.r2.cloudflarestorage.com" "hli2-bkt" "$_BK_SECRET_KEY" > "$DIALOG_INPUTBOX_QUEUE"
  echo "$_BK_SECRET_VAL" > "$DIALOG_PASSWORDBOX_QUEUE"

  timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh" || { fail "backup-setup falló"; return 1; }

  # restic instalado con hli_apt.
  [[ -n "$(_bk_calls '^sudo\tenv\t.*\tinstall\trestic')" ]] || { fail "no instaló restic con hli_apt"; return 1; }

  # Contraseña: root-only, mostrada una vez en el textbox, nunca en argv.
  local pw
  pw="$(sudo -n cat "$SECRETS_DIR/restic-password")" || return 1
  [[ "${#pw}" -ge 40 ]] || { fail "contraseña demasiado corta"; return 1; }
  assert_eq "600" "$(sudo -n stat -c %a "$SECRETS_DIR/restic-password")" || return 1
  assert_eq "1" "$(grep -cF -- "$pw" "$STUB_TEXTBOX_LOG")" "se muestra una sola vez" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "$pw" "contraseña fuera de argv" || return 1
  assert_file_contains "$STATE_FILE" "backup-password-confirmed" || return 1

  # R2: root-only, formato correcto, secretos fuera de argv/logs.
  assert_eq "600" "$(sudo -n stat -c %a "$SECRETS_DIR/restic.env")" || return 1
  local env
  env="$(sudo -n cat "$SECRETS_DIR/restic.env")"
  assert_contains "$env" "RESTIC_REPOSITORY=s3:https://${_BK_ACCOUNT}.r2.cloudflarestorage.com/hli2-bkt" || return 1
  assert_contains "$env" "AWS_ACCESS_KEY_ID=$_BK_SECRET_KEY" || return 1
  assert_contains "$env" "AWS_SECRET_ACCESS_KEY=$_BK_SECRET_VAL" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "$_BK_SECRET_VAL" || return 1
  if grep -rqF -e "$_BK_SECRET_VAL" -e "$pw" "$LOG_DIR" 2>/dev/null; then fail "secreto en logs"; return 1; fi

  # La inicialización la hace el entrypoint como root, no este proceso.
  [[ -n "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\tinit\$")" ]] || { fail "no llamó a hli2-backup init vía sudo"; return 1; }

  # Unidades systemd.
  local svc="$HLI2_SYSTEMD_DIR/hli2-backup.service" tmr="$HLI2_SYSTEMD_DIR/hli2-backup.timer"
  assert_file_contains "$svc" "Type=oneshot" || return 1
  assert_file_contains "$svc" "ExecStart=$BACKUP_INSTALL_DIR/bin/hli2-backup run" "el servicio ejecuta la copia root-owned" || return 1
  assert_file_not_contains "$svc" "$REPO_ROOT" "nada del checkout del usuario" || return 1
  assert_file_contains "$svc" "ExecStopPost=$BACKUP_INSTALL_DIR/bin/hli2-backup recover" || return 1
  assert_file_contains "$svc" "PrivateTmp=yes" || return 1
  assert_file_contains "$svc" "TimeoutStopSec=300" "tiempo para el cleanup y ExecStopPost" || return 1
  assert_file_contains "$tmr" "OnCalendar=*-*-* 04:00:00" || return 1
  assert_file_contains "$tmr" "Persistent=true" || return 1
  [[ -n "$(_bk_calls '^sudo\tsystemctl\tenable\t--now\thli2-backup.timer$')" ]] || { fail "no habilitó el timer"; return 1; }
  assert_file_contains "$STATE_FILE" "backup-setup" || return 1
}

test_backup_setup_rerun_is_idempotent() {
  _bk_setup_env
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"      # confirma contraseña / sin R2
  timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh" || return 1
  local before
  before="$(sudo -n cat "$SECRETS_DIR/restic-password")"
  assert_eq "1" "$(grep -cF -- "$before" "$STUB_TEXTBOX_LOG")" || return 1
  [[ ! -e "$SECRETS_DIR/restic.env" ]] 2>/dev/null
  sudo -n test -f "$SECRETS_DIR/restic.env" && { fail "sin R2 no debe crear restic.env"; return 1; }

  # Segunda corrida: ya existe y está confirmada; no se regenera ni se muestra.
  : > "$STUB_CALL_LOG"; : > "$STUB_TEXTBOX_LOG"
  : > "$DIALOG_YESNO_QUEUE"
  echo "no" > "$DIALOG_YESNO_QUEUE"                # ¿configurar R2? No
  timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh" || return 1
  assert_eq "$before" "$(sudo -n cat "$SECRETS_DIR/restic-password")" "la contraseña no se regenera" || return 1
  assert_eq "" "$(cat "$STUB_TEXTBOX_LOG")" "no se vuelve a mostrar la contraseña" || return 1
}

test_backup_setup_shows_password_again_until_confirmed() {
  _bk_setup_env
  printf 'no\nno\nyes\nno\n' > "$DIALOG_YESNO_QUEUE"   # no, no, sí (guardó) / sin R2
  timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh" || return 1
  local pw
  pw="$(sudo -n cat "$SECRETS_DIR/restic-password")"
  assert_eq "3" "$(grep -cF -- "$pw" "$STUB_TEXTBOX_LOG")" "se repite hasta confirmar" || return 1
}

test_backup_setup_resumes_unconfirmed_password() {
  # El módulo se interrumpió tras generar la contraseña: al volver a correr
  # debe mostrarla de nuevo (nunca dejarla sin confirmar en silencio).
  _bk_setup_env
  _bk_root_write restic-password "interrupted-password-abc"
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"
  timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh" || return 1
  assert_file_contains "$STUB_TEXTBOX_LOG" "interrupted-password-abc" || return 1
  assert_file_contains "$STATE_FILE" "backup-password-confirmed" || return 1
  assert_eq "interrupted-password-abc" "$(sudo -n cat "$SECRETS_DIR/restic-password")" || return 1
}

test_backup_setup_rejects_invalid_r2_input() {
  local bad
  for bad in "http://${_BK_ACCOUNT}.r2.cloudflarestorage.com" "https://example.com" "https://abc.r2.cloudflarestorage.com"; do
    _bk_setup_env
    printf 'yes\nyes\n' > "$DIALOG_YESNO_QUEUE"
    printf '%s\n%s\n%s\n' "$bad" "hli2-bkt" "$_BK_SECRET_KEY" > "$DIALOG_INPUTBOX_QUEUE"
    echo "$_BK_SECRET_VAL" > "$DIALOG_PASSWORDBOX_QUEUE"
    timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh" || return 1   # sigue solo con copia local
    sudo -n test -f "$SECRETS_DIR/restic.env" && { fail "guardó un endpoint inválido: $bad"; return 1; }
    assert_contains "$(_bk_calls '^dialog\t')" "no tiene la forma esperada" || return 1
    assert_file_not_contains "$STUB_CALL_LOG" "$_BK_SECRET_VAL" || return 1
    rm -f "$STATE_FILE"; touch "$STATE_FILE"
  done
}

# --- backup-now -------------------------------------------------------------------------------------

test_backup_now_runs_entrypoint_as_root_and_shows_result() {
  _bk_prepare
  printf 'timestamp=%s\nresult=ok\nlocal=ok\ncloud=not-configured\n' "$(date -Is)" > "$BACKUP_STATE_DIR/backup-status"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/backup-now.sh" </dev/null || { fail "backup-now falló"; return 1; }
  [[ -n "$(_bk_calls "^sudo\t-n\t$BACKUP_INSTALL_DIR/bin/hli2-backup\trun\$")" ]] || { fail "no corrió el entrypoint con sudo"; return 1; }
  assert_contains "$(_bk_calls '^dialog\t')" "Backup terminado" || return 1
}

test_backup_now_requires_setup() {
  _bk_prepare
  chmod u+rwx "$SECRETS_DIR"; rm -f "$SECRETS_DIR/restic-password"; chmod 000 "$SECRETS_DIR"
  if bash "$REPO_ROOT/modules/backup-now.sh" </dev/null; then fail "debió pedir backup-setup primero"; return 1; fi
  assert_contains "$(_bk_calls '^dialog\t')" "backup-setup" || return 1
  [[ -z "$(_bk_calls 'hli2-backup\trun')" ]] || { fail "no debió ejecutar el backup"; return 1; }
}

# --- Integración con el resto del HLI -------------------------------------------------------------

test_backup_modules_are_registered_and_dashboard_shows_status() {
  local mods
  mods="$( ( source "$REPO_ROOT/lib/core.sh"; list_modules ) )"
  assert_contains "$mods" "backup-setup" || return 1
  assert_contains "$mods" "backup-now" || return 1
  assert_eq "tool" "$( ( source "$REPO_ROOT/lib/core.sh"; module_meta backup-now TIPO ) )" || return 1
  assert_eq "no" "$( ( source "$REPO_ROOT/lib/core.sh"; module_meta backup-setup DEFAULT ) )" || return 1
  assert_file_contains "$REPO_ROOT/ui/menu.sh" "backup_status_summary" "dashboard muestra el estado" || return 1
}

test_samba_does_not_share_backup_repo() {
  assert_file_not_contains "$REPO_ROOT/modules/samba.sh" '_samba_share_block backups' "el repo no se comparte por Samba" || return 1
}

# =====================================================================================
# Revisión independiente: C1/C2 y W1-W10
# =====================================================================================

# --- C1: root solo ejecuta una copia root-owned ------------------------------------------

test_backup_refresh_install_copies_regular_files_only_and_replaces_old() {
  local fake="$HLI2_TEST_SCRATCH/fake-repo"
  mkdir -p "$fake"/{bin,lib,services,config}
  cp "$REPO_ROOT/bin/hli2-backup" "$fake/bin/"
  cp "$REPO_ROOT"/lib/*.sh "$fake/lib/"
  cp "$REPO_ROOT"/services/*.conf "$fake/services/"
  cp "$REPO_ROOT/config/default.conf" "$fake/config/"
  ln -s /etc/passwd "$fake/lib/evil.sh"          # un enlace NO se copia
  mkdir -p "$BACKUP_INSTALL_DIR/lib"
  : > "$BACKUP_INSTALL_DIR/lib/old-file.sh"      # lo viejo desaparece
  ( cd / && source "$fake/lib/core.sh" && backup_refresh_install ) || { fail "refresh falló"; return 1; }

  [[ -x "$BACKUP_INSTALL_DIR/bin/hli2-backup" ]] || { fail "falta el entrypoint ejecutable"; return 1; }
  cmp -s "$REPO_ROOT/lib/backup.sh" "$BACKUP_INSTALL_DIR/lib/backup.sh" || { fail "lib/backup.sh distinto"; return 1; }
  cmp -s "$REPO_ROOT/services/jellyfin.conf" "$BACKUP_INSTALL_DIR/services/jellyfin.conf" || return 1
  cmp -s "$REPO_ROOT/config/default.conf" "$BACKUP_INSTALL_DIR/config/default.conf" || return 1
  [[ ! -e "$BACKUP_INSTALL_DIR/lib/evil.sh" ]] || { fail "copió un enlace simbólico"; return 1; }
  [[ ! -e "$BACKUP_INSTALL_DIR/lib/old-file.sh" ]] || { fail "dejó un archivo viejo"; return 1; }
  [[ ! -e "$BACKUP_INSTALL_DIR.new" && ! -e "$BACKUP_INSTALL_DIR.old" ]] || { fail "quedaron directorios de paso"; return 1; }
  assert_eq "$fake" "$(cat "$BACKUP_INSTALL_DIR/source-dir")" || return 1
  assert_eq "755" "$(stat -c %a "$BACKUP_INSTALL_DIR")" || return 1
  assert_eq "644" "$(stat -c %a "$BACKUP_INSTALL_DIR/lib/backup.sh")" || return 1
  assert_eq "755" "$(stat -c %a "$BACKUP_INSTALL_DIR/bin/hli2-backup")" || return 1
}

test_backup_runs_from_installed_copy_and_backs_up_real_config() {
  _bk_prepare
  # El stub de sudo solo copia desde el scratch: el "checkout" del usuario es una copia.
  local co="$HLI2_TEST_SCRATCH/checkout"
  mkdir -p "$co"/{bin,lib,services,config}
  cp "$REPO_ROOT/bin/hli2-backup" "$co/bin/"; cp "$REPO_ROOT"/lib/*.sh "$co/lib/"
  cp "$REPO_ROOT"/services/*.conf "$co/services/"; cp "$REPO_ROOT/config/default.conf" "$co/config/"
  ( cd / && source "$co/lib/core.sh" && backup_refresh_install ) || return 1
  bash "$BACKUP_INSTALL_DIR/bin/hli2-backup" run || { fail "el backup desde la copia debió funcionar"; return 1; }
  local full; full="$(_bk_snapshot_line full)"
  _bk_has_arg "$full" "$BACKUP_INSTALL_DIR/config" || { fail "falta la config de la copia"; return 1; }
  _bk_has_arg "$full" "$co/config" || { fail "falta la config REAL del usuario (source-dir)"; return 1; }
}

test_backup_entrypoint_refuses_code_not_owned_by_root() {
  _bk_prepare
  # Sin el permiso de test (EXPECT_UID=0 real): el repo es del usuario => se niega.
  if env -u HLI2_BACKUP_EXPECT_UID bash "$REPO_ROOT/bin/hli2-backup" run; then fail "debió negarse a correr código del usuario"; return 1; fi
  [[ -z "$(_bk_calls '^(restic|docker)\t')" ]] || { fail "no debió tocar restic/docker"; return 1; }
}

test_backup_root_state_lives_outside_user_owned_state_dir() {
  _bk_prepare
  # Enlaces plantados por el usuario en su STATE_DIR: root no debe seguirlos.
  local victim="$HLI2_TEST_SCRATCH/victim"
  echo "intacto" > "$victim"
  ln -s "$victim" "$STATE_DIR/backup-last-check"
  ln -s "$victim" "$STATE_DIR/backup-status.tmp"
  ln -s "$victim" "$STATE_DIR/backup-status"
  _bk_run run || return 1
  assert_eq "intacto" "$(cat "$victim")" "root no escribió a través de un enlace del usuario" || return 1
  [[ -f "$BACKUP_STATE_DIR/backup-status" && -f "$BACKUP_STATE_DIR/backup-last-check" ]] || { fail "estado fuera de BACKUP_STATE_DIR"; return 1; }
  assert_eq "644" "$(stat -c %a "$BACKUP_STATE_DIR/backup-status")" || return 1
}

test_backup_refuses_symlinked_state_dir() {
  _bk_prepare
  rm -rf "$BACKUP_STATE_DIR"; mkdir -p "$HLI2_TEST_SCRATCH/elsewhere"
  ln -s "$HLI2_TEST_SCRATCH/elsewhere" "$BACKUP_STATE_DIR"
  if _bk_run run; then fail "debió negarse con un directorio de estado enlazado"; return 1; fi
  [[ -z "$(_bk_calls '^restic\t')" ]] || return 1
}

# --- C2: create_media_skeleton no toca el repo --------------------------------------------

test_create_media_skeleton_leaves_backup_repo_alone() {
  mkdir -p "$MEDIA_ROOT"
  export BACKUP_ROOT="$MEDIA_ROOT/.hli2-backups"
  mkdir -p "$BACKUP_ROOT/data"
  : > "$BACKUP_ROOT/config"; : > "$BACKUP_ROOT/data/pack"
  chmod 0700 "$BACKUP_ROOT" "$BACKUP_ROOT/data"; chmod 0600 "$BACKUP_ROOT/config" "$BACKUP_ROOT/data/pack"
  : > "$MEDIA_ROOT/suelto.mkv"; chmod 0600 "$MEDIA_ROOT/suelto.mkv"
  ( source "$REPO_ROOT/lib/core.sh"; create_media_skeleton "$MEDIA_ROOT" ) || return 1

  # Lo de media sí se normaliza...
  assert_eq "2775" "$(stat -c %a "$MEDIA_ROOT/peliculas")" || return 1
  assert_eq "664" "$(stat -c %a "$MEDIA_ROOT/suelto.mkv")" || return 1
  # ...y el repo queda exactamente como estaba.
  assert_eq "700" "$(stat -c %a "$BACKUP_ROOT")" "repo 0700" || return 1
  assert_eq "700" "$(stat -c %a "$BACKUP_ROOT/data")" "subcarpetas del repo" || return 1
  assert_eq "600" "$(stat -c %a "$BACKUP_ROOT/config")" || return 1
  assert_eq "600" "$(stat -c %a "$BACKUP_ROOT/data/pack")" || return 1
  if _bk_calls '^chown\t' | grep -qF ".hli2-backups"; then fail "chown alcanzó el repo de backups"; return 1; fi
  [[ -n "$(_bk_calls '^chown\t')" ]] || { fail "el chown de media no se ejecutó (test vacío)"; return 1; }
  [[ -z "$(_bk_calls '^chown\t' | grep -vP '^chown\t-h\t')" ]] || { fail "chown debe usar -h (no seguir enlaces simbólicos)"; return 1; }
}

test_backup_enforces_repo_dir_owner_and_mode() {
  _bk_prepare
  chmod 2775 "$BACKUP_ROOT"
  _bk_run run || return 1
  assert_eq "700" "$(stat -c %a "$BACKUP_ROOT")" || return 1
  [[ -n "$(_bk_calls "^chown\t-R\t-h\troot:root\t$BACKUP_ROOT\$")" ]] || { fail "no forzó root:root (recursivo) sobre el repo"; return 1; }
}

# --- W1/W2/W3: reinicio robusto ------------------------------------------------------------

test_backup_second_signal_does_not_abort_restart() {
  _bk_prepare
  export STUB_RESTIC_KILL_ON="backup" STUB_DOCKER_KILL_ON_START=1
  _bk_run run || true
  local left; left="$(rg --files "$STUB_DOCKER_STATE_DIR" 2>/dev/null | rg -v '/\.' || true)"
  [[ -z "$left" ]] || { fail "una segunda señal dejó contenedores detenidos: $left"; return 1; }
  [[ -f "$STUB_DOCKER_STATE_DIR/.killed" ]] || { fail "no se envió la segunda señal (test vacío)"; return 1; }
  assert_eq "4" "$(_bk_calls '^docker\tstart\t' | wc -l | tr -d ' ')" "los 4 contenedores volvieron a iniciar" || return 1
}

test_backup_restart_retries_until_container_is_really_running() {
  _bk_prepare
  export STUB_DOCKER_START_IGNORED=1 HLI2_BACKUP_RESTART_WAIT=4
  _bk_run run || { fail "debió terminar bien tras reintentar"; return 1; }
  assert_eq "" "$(rg --files "$STUB_DOCKER_STATE_DIR" 2>/dev/null | rg -v '/\.' || true)" "todo quedó corriendo" || return 1
  local n; n="$(_bk_calls '^docker\tstart\tvaultwarden$' | wc -l | tr -d ' ')"
  (( n >= 2 )) || { fail "no reintentó docker start (n=$n)"; return 1; }
  assert_eq "ok" "$(_bk_status result)" || return 1
}

test_backup_records_restart_failure_in_status() {
  _bk_prepare
  export STUB_DOCKER_FAIL_START=1
  if _bk_run run; then fail "debió fallar si un contenedor no vuelve"; return 1; fi
  assert_eq "error" "$(_bk_status result)" || return 1
  assert_contains "$(_bk_status message)" "no volvió a iniciar" || return 1
}

test_backup_writes_recovery_list_before_stopping_and_clears_it() {
  _bk_prepare
  _bk_run run || return 1
  local l
  while IFS= read -r l; do
    assert_contains "$l" "yes" "la lista de recuperación existe antes de detener: $l" || return 1
  done < <(_bk_calls '^recovery-at-stop\t')
  assert_eq "4" "$(_bk_calls '^recovery-at-stop\t' | wc -l | tr -d ' ')" "se verificó cada parada" || return 1
  [[ ! -s "$BACKUP_STATE_DIR/recovery-containers" ]] || { fail "la lista no se limpió"; return 1; }
}

test_backup_run_recovers_containers_left_stopped_by_a_dead_run() {
  _bk_prepare
  : > "$STUB_DOCKER_STATE_DIR/vaultwarden.stopped"
  printf 'vaultwarden\n' > "$BACKUP_STATE_DIR/recovery-containers"
  _bk_run run || return 1
  local first_start first_snap
  first_start="$(_bk_line_no '^docker\tstart\tvaultwarden$')"
  first_snap="$(_bk_line_no '^restic\t(.*\t)?backup\t')"
  (( first_start < first_snap )) || { fail "debió recuperar antes de la primera foto"; return 1; }
  [[ ! -s "$BACKUP_STATE_DIR/recovery-containers" ]] || return 1
}

test_backup_recover_subcommand_restarts_listed_containers() {
  _bk_prepare
  : > "$STUB_DOCKER_STATE_DIR/adguard.stopped"
  printf 'adguard\n' > "$BACKUP_STATE_DIR/recovery-containers"
  _bk_run recover || return 1
  [[ -n "$(_bk_calls '^docker\tstart\tadguard$')" ]] || { fail "no levantó adguard"; return 1; }
  [[ ! -e "$STUB_DOCKER_STATE_DIR/adguard.stopped" ]] || return 1
  [[ ! -s "$BACKUP_STATE_DIR/recovery-containers" ]] || return 1
}

test_backup_concurrent_run_is_refused_without_touching_containers() {
  _bk_prepare
  flock "$BACKUP_STATE_DIR/lock" sleep 5 &
  local holder=$!
  sleep 0.3
  local rc=0
  HLI2_BACKUP_LOCK_WAIT=1 _bk_run run || rc=$?
  kill "$holder" 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || { fail "debió negarse con otro backup en curso"; return 1; }
  [[ -z "$(_bk_calls '^(docker|restic)\t')" ]] || { fail "no debió tocar nada"; return 1; }
  assert_eq "error" "$(_bk_status result)" "deja rastro en el estado" || return 1
  assert_contains "$(_bk_status message)" "bloqueo" || return 1
}

# --- W4: primera corrida ----------------------------------------------------------------------

test_backup_first_run_does_live_warmup_before_the_stop_window() {
  _bk_prepare
  unset STUB_RESTIC_HAS_FULL
  _bk_run run || return 1
  local warm first_stop last_start forget
  warm="$(grep -nP '^restic\t(.*\t)?backup\t.*--tag\twarmup\t' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  first_stop="$(_bk_line_no '^docker\tstop\t')"
  last_start="$(_bk_last_line_no '^docker\tstart\t')"
  forget="$(_bk_line_no '^restic\t(.*\t)?forget\tab12cd03$')"
  [[ -n "$warm" && -n "$forget" ]] || { fail "faltan la pasada previa o su olvido"; return 1; }
  (( warm < first_stop )) || { fail "la pasada previa debe ir con los servicios arriba"; return 1; }
  (( forget > last_start )) || { fail "la foto previa se olvida después de reiniciar"; return 1; }
  assert_eq "3" "$(_bk_calls '^restic\t(.*\t)?backup\t' | wc -l | tr -d ' ')" "warmup + full + cloud" || return 1
}

test_backup_later_runs_skip_warmup() {
  _bk_prepare
  _bk_run run || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?backup\t.*--tag\twarmup')" ]] || { fail "ya hay foto full: sin pasada previa"; return 1; }
}

# --- W5: errores de docker --------------------------------------------------------------------

test_backup_docker_inspect_error_is_a_warning_not_silent_ok() {
  _bk_prepare
  export STUB_DOCKER_INSPECT_ERROR="vaultwarden"
  _bk_run run || { fail "un error de consulta no debe ser fatal"; return 1; }
  assert_eq "warning" "$(_bk_status result)" || return 1
  assert_contains "$(_bk_status message)" "vaultwarden" || return 1
  [[ -z "$(_bk_calls '^docker\tstop\t.*vaultwarden$')" ]] || { fail "no se puede detener lo que no se sabe si corre"; return 1; }
}

test_backup_missing_container_is_not_a_warning() {
  _bk_prepare
  export STUB_DOCKER_NOT_FOUND="homeassistant"
  _bk_run run || return 1
  assert_eq "ok" "$(_bk_status result)" || return 1
}

# --- W6: disco ---------------------------------------------------------------------------------

test_backup_guard_refuses_unmounted_media_on_separate_partition() {
  _bk_prepare
  export BACKUP_ROOT="$MEDIA_ROOT/.hli2-backups"
  mkdir -p "$BACKUP_ROOT"; : > "$BACKUP_ROOT/config"
  export STUB_MOUNTPOINTS=""          # /srv es otra partición, pero media NO está montada
  if _bk_run run; then fail "debió negarse"; return 1; fi
  assert_contains "$(_bk_status message)" "no es un punto de montaje" || return 1
  [[ -z "$(_bk_calls '^docker\tstop\t')" ]] || return 1
  # Con media montada, el mismo escenario corre.
  export STUB_MOUNTPOINTS="$MEDIA_ROOT"
  _bk_run run || { fail "con media montada debió correr"; return 1; }
}

test_backup_guard_resolves_symlinked_backup_root() {
  _bk_prepare
  mkdir -p "$HLI2_TEST_SCRATCH/rootfs-dir"; : > "$HLI2_TEST_SCRATCH/rootfs-dir/config"
  ln -s "$HLI2_TEST_SCRATCH/rootfs-dir" "$HLI2_TEST_SCRATCH/link-root"
  export BACKUP_ROOT="$HLI2_TEST_SCRATCH/link-root"
  export STUB_FAKE_ROOT_PREFIX="$HLI2_TEST_SCRATCH/rootfs-dir"   # el destino real es del disco del sistema
  if _bk_run run; then fail "un enlace al disco del sistema debió rechazarse"; return 1; fi
  assert_contains "$(_bk_status message)" "mismo disco que el sistema" || return 1
  [[ -z "$(_bk_calls '^restic\t(.*\t)?backup\t')" ]] || return 1
}

test_backup_guard_handles_nonexistent_backup_root() {
  _bk_prepare
  export BACKUP_ROOT="$MEDIA_ROOT/a/b/.hli2-backups"
  rm -rf "$MEDIA_ROOT/a"
  # Sin repo: el guardia pasa (media montada) y el error es "no inicializado".
  if _bk_run run; then fail "sin repo debió fallar"; return 1; fi
  assert_contains "$(_bk_status message)" "no está inicializado" || return 1
  # init lo crea 0700.
  _bk_run init || { fail "init debió crear la ruta"; return 1; }
  assert_eq "700" "$(stat -c %a "$BACKUP_ROOT")" || return 1
  # Sin media montada, ni siquiera crea nada.
  rm -rf "$MEDIA_ROOT/a"; export STUB_MOUNTPOINTS=""
  if _bk_run init; then fail "init debió negarse sin media montada"; return 1; fi
  [[ ! -e "$MEDIA_ROOT/a" ]] || { fail "creó carpetas en el disco equivocado"; return 1; }
}

# --- W7/W8: backup-setup ------------------------------------------------------------------------

test_backup_setup_removes_password_tempfile_when_interrupted() {
  _bk_setup_env
  export TMPDIR="$HLI2_TEST_SCRATCH/tmp"; mkdir -p "$TMPDIR"
  export STUB_TEXTBOX_KILL=1
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"
  timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh" || true
  assert_file_contains "$STUB_TEXTBOX_LOG" "CONTRASEÑA" "el textbox llegó a mostrarse (test no vacío)" || return 1
  assert_eq "" "$(rg --files "$TMPDIR" 2>/dev/null || true)" "no queda el archivo con la contraseña" || return 1
}

test_backup_setup_writes_password_atomically() {
  _bk_setup_env
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"
  timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh" || return 1
  [[ -n "$(_bk_calls "^sudo\tmv\t-f\t$SECRETS_DIR/\.restic-password\.[0-9]+\t$SECRETS_DIR/restic-password\$")" ]] \
    || { fail "la contraseña debe escribirse a un temporal y moverse"; return 1; }
  sudo -n test -e "$SECRETS_DIR/.restic-password.$$" && return 1
  return 0
}

test_backup_setup_regenerates_empty_password_without_repo() {
  _bk_setup_env
  _bk_root_write restic-password ""
  printf 'yes\nno\n' > "$DIALOG_YESNO_QUEUE"
  timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh" || return 1
  local pw; pw="$(sudo -n cat "$SECRETS_DIR/restic-password")"
  [[ "${#pw}" -ge 40 ]] || { fail "no regeneró la contraseña"; return 1; }
  assert_eq "1" "$(grep -cF -- "$pw" "$STUB_TEXTBOX_LOG")" "se muestra la nueva" || return 1
}

test_backup_setup_refuses_empty_password_when_repo_exists() {
  _bk_setup_env
  mkdir -p "$BACKUP_ROOT"; : > "$BACKUP_ROOT/config"
  _bk_root_write restic-password ""
  if timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh"; then fail "debió fallar: regenerar no abriría el repo"; return 1; fi
  assert_contains "$(_bk_calls '^dialog\t')" "no abriría los backups existentes" || return 1
  assert_eq "" "$(sudo -n cat "$SECRETS_DIR/restic-password")" "no se tocó el archivo" || return 1
}

test_backup_run_rejects_empty_password_file() {
  _bk_prepare
  _bk_root_write restic-password ""
  if _bk_run run; then fail "debió fallar con contraseña vacía"; return 1; fi
  assert_contains "$(_bk_status message)" "contraseña" || return 1
  [[ -z "$(_bk_calls '^docker\tstop\t')" ]] || return 1
}

# --- W9/W10 y sugerencias -----------------------------------------------------------------------

test_backup_status_is_running_during_the_run_and_interrupted_when_killed() {
  _bk_prepare
  export STUB_RESTIC_PROBE="$HLI2_TEST_SCRATCH/probe"
  export TMPDIR="$HLI2_TEST_SCRATCH/tmp"; mkdir -p "$TMPDIR"
  export STUB_RESTIC_KILL_ON="backup"
  _bk_run run || true
  assert_file_contains "$STUB_RESTIC_PROBE" "result=running" "estado 'running' mientras corre" || return 1
  assert_eq "interrupted" "$(_bk_status result)" "una corrida cortada no deja un 'ok' viejo" || return 1
  assert_eq "" "$(rg --files "$TMPDIR" 2>/dev/null || true)" "el temporal de salida de restic se borró en la señal" || return 1
}

test_backup_previous_ok_status_does_not_survive_a_killed_run() {
  _bk_prepare
  printf 'timestamp=%s\nresult=ok\nlocal=ok\ncloud=ok\n' "$(date -Is)" > "$BACKUP_STATE_DIR/backup-status"
  export STUB_RESTIC_KILL_ON="backup"
  _bk_run run || true
  assert_eq "interrupted" "$(_bk_status result)" || return 1
}

test_backup_retention_order_and_r2_prune_only_with_new_snapshot() {
  _bk_prepare
  _bk_r2
  _bk_run run || return 1
  local copy f_r2 f_local
  copy="$(_bk_line_no '^restic\t(.*\t)?copy\t')"
  f_r2="$(grep -nP '^restic-env\tREPO=s3:' "$STUB_CALL_LOG" | tail -1 | cut -d: -f1)"
  f_local="$(_bk_last_line_no '^restic\t(.*\t)?forget\t')"
  (( f_local > copy )) || { fail "la retención local va DESPUÉS de la copia a R2"; return 1; }
  assert_eq "2" "$(_bk_calls '^restic\t(.*\t)?forget\t' | wc -l | tr -d ' ')" "con foto nueva se poda local y R2" || return 1

  # Si la foto cloud no se pudo tomar, no se poda R2.
  : > "$STUB_CALL_LOG"
  export STUB_RESTIC_FAIL="backup:cloud"
  _bk_run run || true
  assert_eq "1" "$(_bk_calls '^restic\t(.*\t)?forget\t' | wc -l | tr -d ' ')" "sin foto cloud nueva no se poda R2" || return 1
  assert_eq "REPO=$BACKUP_ROOT" "$(grep -A1 -P '^restic\t(.*\t)?forget\t' "$STUB_CALL_LOG" | grep restic-env | cut -f2)" "la única poda es la local" || return 1
}

test_backup_no_retention_when_cloud_copy_fails() {
  _bk_prepare
  _bk_r2
  export STUB_RESTIC_FAIL="copy"
  _bk_run run || true
  [[ -z "$(_bk_calls '^restic\t(.*\t)?forget\t')" ]] || { fail "sin copia a R2 no se poda ni local ni R2"; return 1; }
  assert_contains "$(_bk_status message)" "retención local omitida" || return 1
}

test_backup_uses_exclude_caches_and_r2_init_copies_chunker_params() {
  _bk_prepare
  _bk_r2
  _bk_run run || return 1
  _bk_has_arg "$(_bk_snapshot_line full)" "--exclude-caches" || { fail "falta --exclude-caches"; return 1; }
  rm -f "$BACKUP_ROOT/config"
  _bk_run init || return 1
  local init; init="$(grep -P '^restic\t(.*\t)?init\t.*--from-repo' "$STUB_CALL_LOG" | head -1)"
  [[ -n "$init" ]] || { fail "el init de R2 debe usar --from-repo"; return 1; }
  _bk_has_arg "$init" "--copy-chunker-params" || return 1
  _bk_has_arg "$init" "--from-password-file" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "$_BK_SECRET_VAL" || return 1
}

# =====================================================================================
# Segunda revisión
# =====================================================================================

test_backup_failed_recover_keeps_the_recovery_list() {
  _bk_prepare
  : > "$STUB_DOCKER_STATE_DIR/vaultwarden.stopped"; : > "$STUB_DOCKER_STATE_DIR/adguard.stopped"
  printf 'vaultwarden\nadguard\n' > "$BACKUP_STATE_DIR/recovery-containers"
  export STUB_DOCKER_FAIL_START="vaultwarden"
  if _bk_run recover; then :; fi
  # adguard sí subió y sale de la lista; vaultwarden NO subió y se conserva
  # (el trap EXIT ya no borra la lista).
  assert_eq "vaultwarden" "$(cat "$BACKUP_STATE_DIR/recovery-containers")" || return 1
}

test_backup_run_keeps_unrecoverable_leftovers_in_the_list() {
  _bk_prepare
  : > "$STUB_DOCKER_STATE_DIR/legacy.stopped"
  printf 'legacy\n' > "$BACKUP_STATE_DIR/recovery-containers"
  export STUB_DOCKER_FAIL_START="legacy"
  _bk_run run || true
  assert_eq "legacy" "$(cat "$BACKUP_STATE_DIR/recovery-containers")" "lo no recuperable no se pisa ni se borra" || return 1
  assert_contains "$(_bk_status message)" "sin iniciar" || return 1
  # Lo detenido por esta corrida sí volvió.
  assert_eq "" "$(rg --files "$STUB_DOCKER_STATE_DIR" 2>/dev/null | rg -v '/\.|legacy' || true)" || return 1
}

test_backup_recover_drops_containers_that_no_longer_exist() {
  _bk_prepare
  printf 'ghost\n' > "$BACKUP_STATE_DIR/recovery-containers"
  export STUB_DOCKER_NOT_FOUND="ghost"
  _bk_run recover || { fail "un contenedor inexistente no debe hacer fallar recover"; return 1; }
  [[ -z "$(_bk_calls '^docker\tstart\tghost$')" ]] || { fail "no hay nada que iniciar"; return 1; }
  [[ ! -s "$BACKUP_STATE_DIR/recovery-containers" ]] || { fail "el nombre viejo quedó en la lista"; return 1; }
}

test_backup_recover_marks_stale_running_status_as_interrupted() {
  _bk_prepare
  printf 'timestamp=%s\nresult=running\nlocal=pending\ncloud=pending\ncheck=pending\n' "$(date -Is)" > "$BACKUP_STATE_DIR/backup-status"
  _bk_run recover || return 1
  assert_eq "interrupted" "$(_bk_status result)" || return 1
  # Un estado terminado no se toca.
  printf 'timestamp=%s\nresult=ok\nlocal=ok\ncloud=ok\n' "$(date -Is)" > "$BACKUP_STATE_DIR/backup-status"
  _bk_run recover || return 1
  assert_eq "ok" "$(_bk_status result)" || return 1
}

test_backup_excludes_password_stage_files() {
  _bk_prepare
  _bk_run run || return 1
  _bk_has_arg "$(_bk_snapshot_line full)" "--exclude=$SECRETS_DIR/.restic-password.*" || { fail "los temporales de la contraseña no deben respaldarse"; return 1; }
}

test_backup_refresh_install_restores_previous_copy_if_swap_fails() {
  local co="$HLI2_TEST_SCRATCH/checkout"
  mkdir -p "$co"/{bin,lib,services,config}
  cp "$REPO_ROOT/bin/hli2-backup" "$co/bin/"; cp "$REPO_ROOT"/lib/*.sh "$co/lib/"
  cp "$REPO_ROOT"/services/*.conf "$co/services/"; cp "$REPO_ROOT/config/default.conf" "$co/config/"
  mkdir -p "$BACKUP_INSTALL_DIR"; echo previa > "$BACKUP_INSTALL_DIR/marca"
  export STUB_SUDO_MV_FAIL_TARGET="$BACKUP_INSTALL_DIR"
  if ( cd / && source "$co/lib/core.sh" && backup_refresh_install ); then fail "debió fallar el intercambio"; return 1; fi
  assert_eq "previa" "$(cat "$BACKUP_INSTALL_DIR/marca" 2>/dev/null)" "la copia anterior se restauró" || return 1
}

test_backup_setup_aborts_confirmation_loop_without_a_terminal() {
  _bk_setup_env
  export TMPDIR="$HLI2_TEST_SCRATCH/tmp"; mkdir -p "$TMPDIR"
  : > "$DIALOG_YESNO_QUEUE"                       # cola vacía: confirm siempre falla
  if timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh"; then fail "debió abortar tras N intentos"; return 1; fi
  assert_eq "10" "$(grep -c "CONTRASEÑA DE CIFRADO" "$STUB_TEXTBOX_LOG")" "tope de intentos" || return 1
  assert_file_not_contains "$STATE_FILE" "backup-password-confirmed" "sin confirmar no se marca" || return 1
  assert_eq "" "$(rg --files "$TMPDIR" 2>/dev/null || true)" || return 1
}

test_backup_setup_cleans_password_stage_when_move_fails() {
  _bk_setup_env
  export STUB_SUDO_MV_FAIL_TARGET="$SECRETS_DIR/restic-password"
  if timeout 30 bash "$REPO_ROOT/modules/backup-setup.sh"; then fail "debió fallar"; return 1; fi
  [[ -n "$(_bk_calls "^sudo\trm\t-f\t$SECRETS_DIR/\.restic-password\.[0-9]+\$")" ]] || { fail "no limpió el temporal de la contraseña"; return 1; }
}
