#!/usr/bin/env bash
# Helpers compartidos por tests/test_backup.sh y tests/test_restore.sh (el
# entorno de backup: root simulado, restic/docker/sudo stubbeados).

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

_bk_setup_env() {
  _bk_prepare
  export HLI2_SYSTEMD_DIR="$HLI2_TEST_SCRATCH/systemd"
  mkdir -p "$HLI2_SYSTEMD_DIR"
  # Ni contraseña ni R2 todavía: es una instalación nueva.
  chmod u+rwx "$SECRETS_DIR"; rm -f "$SECRETS_DIR/restic-password"; chmod 000 "$SECRETS_DIR"
  rm -rf "$BACKUP_ROOT"
  echo "new" > "$DIALOG_MENU_QUEUE"      # instalación nueva (no recuperación ante un desastre)
}


# Archivos bajo $1 (uno por línea), sin los que calzan con la expresión $2 (opcional). Un
# error de 'rg' (directorio inexistente, expresión inválida) NO se confunde con "no hay
# archivos": devuelve 'RG-ERROR(...)' y el assert contra "" falla.
_bk_files_in() {
  local dir="$1" excl="${2:-}" out rc=0
  out="$(rg --files -- "$dir" 2>&1)" || rc=$?
  if [[ "$rc" -gt 1 ]]; then printf 'RG-ERROR(%s): %s' "$rc" "$out"; return 0; fi
  if [[ -n "$excl" ]]; then
    rc=0
    out="$(printf '%s\n' "$out" | rg -v -- "$excl" 2>&1)" || rc=$?
    if [[ "$rc" -gt 1 ]]; then printf 'RG-ERROR(%s): %s' "$rc" "$out"; return 0; fi
  fi
  printf '%s' "$out"
}
