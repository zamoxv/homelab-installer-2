#!/usr/bin/env bash
# HLI-MODULE: backup-setup
# HLI-DESC: Backups con restic (local + Cloudflare R2, diario 04:00)
# HLI-ORDER: 70
# HLI-DEFAULT: no
# HLI-TUI: yes
#
# Instala restic, genera la contraseña de cifrado (se muestra UNA vez), crea el
# repositorio local, configura opcionalmente el repositorio externo en
# Cloudflare R2 e instala el timer diario de systemd (hli2-backup.timer).
# Idempotente: no regenera la contraseña ni vuelve a inicializar repositorios.
#
# HLI-DEFAULT: no, a propósito: necesita que el usuario cree antes el bucket y
# el token de R2 (o decida no usar copia externa) y guarde la contraseña.
#
# Archivos (root 0600, ver lib/secrets.sh): /etc/hli2/restic-password y
# /etc/hli2/restic.env (RESTIC_REPOSITORY, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION). Nada de eso viaja por argv.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

# Donde se instalan las unidades; variable para que los tests no toquen el
# systemd real (mismo criterio HLI2_* que el resto del proyecto).
BACKUP_SYSTEMD_DIR="${HLI2_SYSTEMD_DIR:-/etc/systemd/system}"
BACKUP_PW_CONFIRMED_KEY="backup-password-confirmed"

# --- Validaciones de forma (nunca de red) -------------------------------------

_backup_valid_endpoint() {
  [[ "$1" =~ ^https://[0-9a-f]{32}(\.(eu|fedramp))?\.r2\.cloudflarestorage\.com$ ]]
}
_backup_valid_bucket() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]
}
_backup_valid_access_key() {
  [[ "$1" =~ ^[A-Za-z0-9]{16,64}$ ]]
}
_backup_valid_secret_key() {
  [[ "$1" =~ ^[A-Za-z0-9/+=_-]{20,128}$ ]]
}

_backup_trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# --- Contraseña de restic ----------------------------------------------------------

# Archivo temporal con la contraseña en claro: se borra SIEMPRE (salida normal,
# error o señal), nunca queda en disco si el módulo se interrumpe.
_BACKUP_PW_TMP=""
_backup_pw_cleanup() {
  [[ -z "$_BACKUP_PW_TMP" ]] || rm -f -- "$_BACKUP_PW_TMP"
  _BACKUP_PW_TMP=""
}

# Muestra la contraseña con 'dialog --textbox' sobre un archivo temporal 0600
# (nunca en argv, a diferencia de --msgbox) y no sale de acá hasta que el
# usuario confirme que la guardó en Vaultwarden Y en papel.
_backup_show_password_until_confirmed() {
  local pw="$1"
  trap _backup_pw_cleanup EXIT
  trap '_backup_pw_cleanup; exit 130' INT HUP
  trap '_backup_pw_cleanup; exit 143' TERM
  _BACKUP_PW_TMP="$(mktemp)"
  chmod 0600 "$_BACKUP_PW_TMP"
  {
    printf 'CONTRASEÑA DE CIFRADO DE LOS BACKUPS (se muestra UNA sola vez)\n\n'
    printf '    %s\n\n' "$pw"
    printf 'Sin esta contraseña los backups son IRRECUPERABLES, y la copia externa\n'
    printf 'no se puede abrir de ningún otro modo.\n\n'
    printf '1. Guárdela en Vaultwarden.\n'
    printf '2. Escríbala también EN PAPEL y guárdelo en un lugar seguro: si el\n'
    printf '   servidor se pierde, Vaultwarden se pierde con él.\n'
  } > "$_BACKUP_PW_TMP"
  while true; do
    hli_busy_end
    dialog --title "Contraseña de backups" --textbox "$_BACKUP_PW_TMP" 18 76 || true
    if confirm "¿Guardó la contraseña en Vaultwarden Y en papel?\n\nSi elige 'No', se mostrará de nuevo."; then
      break
    fi
  done
  _backup_pw_cleanup
  pw=""
  mark_done "$BACKUP_PW_CONFIRMED_KEY"
}

_backup_generate_password() {
  # 32 bytes aleatorios en base64 'url-safe' sin relleno: sin '+', '/' ni '=',
  # fácil de copiar a mano al papel.
  head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '='
}

# ¿Existe el repositorio local? ($BACKUP_ROOT es root 0700: se pregunta con sudo.)
_backup_repo_exists() {
  sudo -n test -f "$BACKUP_ROOT/config" 2>/dev/null
}

# Escribe la contraseña de forma atómica: archivo temporal root 0600 en el mismo
# directorio y 'mv' (nunca queda un archivo vacío o a medias en la ruta final).
_backup_write_password() {
  local pw="$1" pw_stage="$SECRETS_DIR/.restic-password.$$"
  sudo install -d -m 0700 -o root -g root "$SECRETS_DIR" || return 1
  sudo install -m 0600 -o root -g root /dev/null "$pw_stage" || return 1
  if ! printf '%s\n' "$pw" | sudo tee "$pw_stage" >/dev/null; then
    sudo rm -f "$pw_stage"
    return 1
  fi
  sudo mv -f "$pw_stage" "$BACKUP_PASSWORD_FILE"
}

_backup_ensure_password() {
  local pw=""
  if priv_file_exists "$BACKUP_PASSWORD_FILE"; then
    pw="$(priv_file_read "$BACKUP_PASSWORD_FILE" 2>/dev/null || true)"
    pw="${pw%%$'\n'*}"
    if [[ "${#pw}" -ge 16 && "$pw" != *[[:space:]]* ]]; then
      if is_done "$BACKUP_PW_CONFIRMED_KEY"; then
        log "Contraseña de restic ya existente y confirmada: se conserva."
        pw=""
        return 0
      fi
      # Existe pero nunca se confirmó (el módulo se interrumpió): mostrarla de nuevo.
      _backup_show_password_until_confirmed "$pw"
      pw=""
      return 0
    fi
    # Archivo vacío o inválido. Con un repositorio ya creado NO se regenera: la
    # contraseña nueva no abriría los backups existentes.
    pw=""
    if _backup_repo_exists; then
      msg "El archivo de la contraseña de restic ($BACKUP_PASSWORD_FILE) está vacío o es inválido, y ya existe un repositorio de backups.\n\nNo se genera otra contraseña: no abriría los backups existentes. Restaure el archivo con la contraseña guardada en Vaultwarden o en papel y vuelva a correr este módulo."
      return 1
    fi
    log "Archivo de contraseña de restic vacío o inválido y sin repositorio: se genera de nuevo."
  fi

  pw="$(_backup_generate_password)"
  [[ -n "$pw" ]] || { msg "No se pudo generar la contraseña de restic."; return 1; }
  if ! _backup_write_password "$pw"; then
    pw=""
    msg "No se pudo guardar la contraseña de restic."
    return 1
  fi
  log "Contraseña de restic generada y guardada root-only (no se loguea el valor)."
  _backup_show_password_until_confirmed "$pw"
  pw=""
}

# --- Cloudflare R2 ------------------------------------------------------------------

_backup_r2_configured() {
  secret_file_exists restic && secret_get restic RESTIC_REPOSITORY >/dev/null 2>&1
}

# 0 = quedó configurado (o se conserva lo guardado); 1 = el usuario no quiso
# o el dato era inválido (solo copia local, no es un error del módulo).
_backup_configure_r2() {
  if _backup_r2_configured; then
    confirm "Ya hay una copia externa (Cloudflare R2) configurada.\n\n¿Reconfigurarla con otro bucket o claves? (Elija 'No' para conservarla.)" \
      || return 0
  else
    confirm "¿Configurar ahora la copia externa en Cloudflare R2?\n\nSin ella solo habrá copia local: no sobrevive a la pérdida del equipo o de la casa. Puede hacerlo más tarde volviendo a correr este módulo." \
      || return 0
  fi

  msg "Antes de continuar, prepare R2 en Cloudflare:\n\n1. Panel de Cloudflare -> R2 -> 'Create bucket' (nombre propio, p. ej. 'hli2-backups').\n2. R2 -> 'Manage R2 API Tokens' -> 'Create API token' con permiso 'Object Read & Write', restringido SOLO a ese bucket.\n3. Anote: el endpoint S3 (https://<ACCOUNT_ID>.r2.cloudflarestorage.com), el Access Key ID y el Secret Access Key (este último se muestra una sola vez)."

  local endpoint bucket key secret
  endpoint=$(input_box "Cloudflare R2 — endpoint" "Endpoint S3 de la cuenta (https://<ACCOUNT_ID>.r2.cloudflarestorage.com):") \
    || { msg "Se omite la copia externa: no se ingresó el endpoint."; return 1; }
  endpoint="$(_backup_trim "$endpoint")"; endpoint="${endpoint%/}"
  bucket=$(input_box "Cloudflare R2 — bucket" "Nombre del bucket:") \
    || { msg "Se omite la copia externa: no se ingresó el bucket."; return 1; }
  bucket="$(_backup_trim "$bucket")"
  key=$(input_box "Cloudflare R2 — Access Key ID" "Access Key ID del token:") \
    || { msg "Se omite la copia externa: no se ingresó el Access Key ID."; return 1; }
  key="$(_backup_trim "$key")"
  secret=$(password_box "Cloudflare R2 — Secret Access Key" "Secret Access Key del token. No se muestra en pantalla ni se registra en logs.") \
    || { msg "Se omite la copia externa: no se ingresó el Secret Access Key."; return 1; }
  secret="$(_backup_trim "$secret")"

  if ! _backup_valid_endpoint "$endpoint"; then
    secret=""
    msg "El endpoint no tiene la forma esperada (https://<ACCOUNT_ID>.r2.cloudflarestorage.com, con el ID de 32 caracteres hexadecimales). Se omite la copia externa: vuelva a correr este módulo."
    return 1
  fi
  if ! _backup_valid_bucket "$bucket"; then
    secret=""
    msg "El nombre del bucket no es válido (3 a 63 caracteres: minúsculas, números y guiones). Se omite la copia externa: vuelva a correr este módulo."
    return 1
  fi
  if ! _backup_valid_access_key "$key" || ! _backup_valid_secret_key "$secret"; then
    secret=""
    msg "El Access Key ID o el Secret Access Key no tienen la forma esperada. Se omite la copia externa: vuelva a correr este módulo."
    return 1
  fi

  if ! secret_file_write restic "RESTIC_REPOSITORY=s3:${endpoint}/${bucket}
AWS_ACCESS_KEY_ID=${key}
AWS_SECRET_ACCESS_KEY=${secret}
AWS_DEFAULT_REGION=auto"; then
    secret=""
    msg "No se pudo guardar la configuración de R2 en /etc/hli2/restic.env. Se omite la copia externa."
    return 1
  fi
  secret=""
  log "Configuración de R2 guardada en /etc/hli2/restic.env (no se loguean los valores)."
  return 0
}

# --- Unidades systemd -------------------------------------------------------------------

# Todas apuntan a la copia root-owned ($BACKUP_INSTALL_DIR), nunca al checkout.
# Sin NoNewPrivileges: el backup usa 'sudo' (hli_docker, lib/secrets.sh) aun
# corriendo como root, y ese flag lo rompería.
_backup_install_units() {
  case "$BACKUP_INSTALL_DIR" in
    *[[:space:]%\"\']*)
      msg "La ruta de instalación del backup ($BACKUP_INSTALL_DIR) tiene espacios o caracteres que systemd no admite en ExecStart."
      return 1
      ;;
  esac
  local exe="$BACKUP_INSTALL_DIR/bin/hli2-backup"

  printf '%s\n' \
    "[Unit]" \
    "Description=HLI 2 backup (restic: local + Cloudflare R2)" \
    "Wants=network-online.target" \
    "After=docker.service network-online.target local-fs.target" \
    "RequiresMountsFor=$BACKUP_ROOT" \
    "" \
    "[Service]" \
    "Type=oneshot" \
    "Environment=USER=root HOME=/root" \
    "ExecStart=$exe run" \
    "ExecStopPost=$exe recover" \
    "PrivateTmp=yes" \
    "TimeoutStartSec=6h" \
    "Nice=10" \
    "IOSchedulingClass=idle" \
    | sudo tee "$BACKUP_SYSTEMD_DIR/hli2-backup.service" >/dev/null

  printf '%s\n' \
    "[Unit]" \
    "Description=HLI 2 backup diario" \
    "" \
    "[Timer]" \
    "OnCalendar=*-*-* 04:00:00" \
    "Persistent=true" \
    "" \
    "[Install]" \
    "WantedBy=timers.target" \
    | sudo tee "$BACKUP_SYSTEMD_DIR/hli2-backup.timer" >/dev/null

  # Tras un corte de luz a mitad de la ventana de parada, 'restart:
  # unless-stopped' no levanta lo parado a mano: esta unidad lo hace al arrancar.
  printf '%s\n' \
    "[Unit]" \
    "Description=HLI 2: levantar contenedores que un backup interrumpido dejó detenidos" \
    "After=docker.service" \
    "Wants=docker.service" \
    "" \
    "[Service]" \
    "Type=oneshot" \
    "Environment=USER=root HOME=/root" \
    "ExecStart=$exe recover" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target" \
    | sudo tee "$BACKUP_SYSTEMD_DIR/hli2-backup-recover.service" >/dev/null

  sudo systemctl daemon-reload
  sudo systemctl enable --now hli2-backup.timer
  sudo systemctl enable hli2-backup-recover.service
}

_backup_setup_main() {
  hli_apt install restic
  command -v restic >/dev/null 2>&1 || { msg "No se pudo instalar restic (revise $LOG_DIR/backup-setup.log)."; return 1; }

  _backup_ensure_password || return 1
  _backup_configure_r2 || true

  # Copia root-owned del código y, desde ahí, inicialización como root (la
  # lógica y las credenciales no pasan por este proceso).
  if ! backup_refresh_install; then
    msg "No se pudo instalar la copia del código del backup en $BACKUP_INSTALL_DIR."
    return 1
  fi
  local out
  if ! out="$(sudo -n "$BACKUP_INSTALL_DIR/bin/hli2-backup" init 2>&1)"; then
    hli_error "inicialización de repositorios: $(printf '%s' "$out" | tail -n 3)"
    msg "No se pudieron inicializar los repositorios de backup:\n\n$(printf '%s' "$out" | tail -n 5)\n\nSi el disco de media no está montado aparte del sistema, móntelo y vuelva a correr este módulo."
    return 1
  fi

  _backup_install_units || return 1

  local r2_note="Solo hay copia local (R2 sin configurar): vuelva a correr este módulo para agregarla."
  if _backup_r2_configured; then r2_note="La copia externa en R2 está configurada."; fi
  msg "Backups listos.\n\n- Repositorio local: $BACKUP_ROOT\n- $r2_note\n- Se ejecutan todos los días a las 04:00 (hli2-backup.timer).\n- El código del backup se instaló en $BACKUP_INSTALL_DIR (copia de root). Tras actualizar el HLI 2 con git, vuelva a correr este módulo o 'Hacer backup ahora' para refrescarla.\n- Para probar ahora: Herramientas -> 'Hacer backup ahora'.\n\nRecuerde: sin la contraseña de restic los backups no se pueden restaurar."

  mark_done backup-setup
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _backup_setup_main
fi
