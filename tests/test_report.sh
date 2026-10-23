#!/usr/bin/env bash
# Tests del informe de diagnóstico del servidor (v2.6d): lib/report.sh,
# bin/hli2-report y la parte del módulo hermes (unidades, montaje de solo
# lectura, bloque de SOUL.md). Todo stubbeado; nunca como root.

_RP_SECRET_ENV="SECRETENVVALUE123456"

# Entorno: entrypoint como el usuario del test, docker/systemctl/tailscale propios.
_rp_setup() {
  export HLI2_BACKUP_ALLOW_NONROOT=1 HLI2_BACKUP_EXPECT_UID="$(id -u)"
  export STUB_RP_DIR="$HLI2_TEST_SCRATCH/rpdata"
  export STUB_RP_LIB="$STUBS_DIR/_stublib.sh"
  local d="$HLI2_TEST_SCRATCH/rpbin"
  mkdir -p "$d" "$STUB_RP_DIR/c" "$STUB_RP_DIR/logs" "$APPDATA_ROOT" "$MEDIA_ROOT" "$BACKUP_STATE_DIR"
  cat > "$d/docker" <<'EOF'
#!/usr/bin/env bash
source "$STUB_RP_LIB"
log_call docker "$@"
case "${1:-}" in
  info) exit 0 ;;
  inspect)
    # Cualquier consulta sin formato, o con campos fuera de la lista blanca, "filtra" un secreto.
    if [[ "${2:-}" != "-f" || "${3:-}" == *Env* || "${3:-}" == *Labels* || "${3:-}" == *Mounts* || "${3:-}" == *Cmd* || "${3:-}" == *Args* ]]; then
      echo "SECRETENVVALUE123456"; exit 0
    fi
    name="${*: -1}"
    [[ -f "$STUB_RP_DIR/c/$name" ]] || { echo "Error: No such object: $name" >&2; exit 1; }
    if [[ "$3" == '{{.State.Status}}' ]]; then cut -d'|' -f1 "$STUB_RP_DIR/c/$name"; exit 0; fi
    cat "$STUB_RP_DIR/c/$name"; exit 0 ;;
  logs) cat "$STUB_RP_DIR/logs/${*: -1}" 2>/dev/null; exit 0 ;;
  service) echo "1/1"; exit 0 ;;
esac
exit 0
EOF
  cat > "$d/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--failed" ]]; then
  [[ -z "${STUB_RP_FAILED:-}" ]] || printf '%s\n' "$STUB_RP_FAILED"
  exit 0
fi
[[ "${1:-}" == "is-active" ]] && { echo active; exit 0; }
exit 1
EOF
  chmod +x "$d/docker" "$d/systemctl"
  export PATH="$d:$PATH"
}

# Contenedor de prueba: nombre, estado, salud, reinicios, inicio, imagen.
_rp_container() {
  printf '%s|%s|%s|%s|%s\n' "${2:-running}" "${3:-healthy}" "${4:-0}" "${5:-2026-10-20T10:00:00.000000000Z}" "${6:-ghcr.io/x/app:1.2.3@sha256:$(printf 'a%.0s' {1..64})}" > "$STUB_RP_DIR/c/$1"
}

_rp_run() { bash "$REPO_ROOT/bin/hli2-report"; }
_rp_report() { cat "$APPDATA_ROOT/hermes-report/report.md"; }

_rp_env_file() {
  chmod u+rwx "$SECRETS_DIR"
  printf '%s' "$2" > "$SECRETS_DIR/$1"
  chmod 0600 "$SECRETS_DIR/$1"
  chmod 000 "$SECRETS_DIR"
}

# --- Redacción -------------------------------------------------------------------

_rp_redact() { ( source "$REPO_ROOT/lib/core.sh"; report_redact ); }

test_report_redacts_each_pattern() {
  local in out
  in="$(cat <<'EOF'
or sk-or-v1-abcdef1234567890abcdef
tg 123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw-abc
jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abc_DEF-123
Authorization: Bearer abc.def.ghi
curl -H "authorization: basic QWxhZGRpbjpvcGVuIHNlc2FtZQ=="
password=hunter2secret token: abcd1234 "api_key":"zzzz9999" API-KEY = foo secret=s3cr3t1
url https://bob:s3cr3t@example.com/p
mail carlos.m@example.com
ip 192.168.1.20 and 100.64.0.1 and 2001:db8::ff00:42:8329
hex 0123456789abcdef0123456789abcdef0123
b64 QWxhZGRpbjpvcGVuIHNlc2FtZVRoaXNJc0xvbmdFbm91Z2hGb3JCNjQ1Ng
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA1234567890abcdef+/=
-----END RSA PRIVATE KEY-----
EOF
)"
  out="$(_rp_redact <<<"$in")"
  local s
  for s in sk-or-v1-abcdef 123456789:AAH eyJhbGci "abc.def.ghi" QWxhZGRpbjpvcGVuIHNlc2FtZQ hunter2secret abcd1234 zzzz9999 "= foo" s3cr3t1 bob:s3cr3t "carlos.m" 192.168.1.20 100.64.0.1 2001:db8 0123456789abcdef0123 VGhpc0lzTG9uZw MIIEowIBAAKC "PRIVATE KEY"; do
    assert_not_contains "$out" "$s" "debía ocultar [$s]" || return 1
  done
  assert_contains "$out" "@example.com" "el dominio del correo se conserva" || return 1
  assert_contains "$out" "<IP>" || return 1
  assert_contains "$out" "<OCULTO>" || return 1
}

test_report_redaction_keeps_ordinary_text() {
  local out
  out="$(_rp_redact <<<'imagen authelia/authelia:4.38 auth-service:1.0 hora 2026-10-22T10:20:30 ruta /srv/appdata/hermes-report/report-with-a-very-long-name-here core::fmt')"
  assert_contains "$out" "authelia/authelia:4.38" || return 1
  assert_contains "$out" "auth-service:1.0" || return 1
  assert_contains "$out" "2026-10-22T10:20:30" || return 1
  assert_contains "$out" "/srv/appdata/hermes-report/report-with-a-very-long-name-here" || return 1
  assert_contains "$out" "core::fmt" || return 1
}

test_report_redaction_is_idempotent() {
  local once twice
  once="$(_rp_redact <<<'password=hunter2secret ip 10.0.0.1 mail a@b.org')"
  twice="$(_rp_redact <<<"$once")"
  assert_eq "$once" "$twice" || return 1
}

test_report_redacts_env_file_values_but_not_short_ones() {
  _rp_setup
  _rp_env_file hermes.env "OPENROUTER_API_KEY=plainvaluewithoutpattern
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD='Abcdefghijklmnopqrstuvwx'
SHORT=ab1
"
  _rp_env_file restic-password "restic-pass-literal-123"
  _rp_container hermes
  printf 'error: login with Abcdefghijklmnopqrstuvwx and plainvaluewithoutpattern and restic-pass-literal-123 ab1 failed\n' > "$STUB_RP_DIR/logs/hermes"
  _rp_run || return 1
  local r; r="$(_rp_report)"
  assert_not_contains "$r" "Abcdefghijklmnopqrstuvwx" || return 1
  assert_not_contains "$r" "plainvaluewithoutpattern" || return 1
  assert_not_contains "$r" "restic-pass-literal-123" || return 1
  assert_contains "$r" "ab1 failed" "un valor de menos de 6 caracteres no se enmascara" || return 1
}

# --- Contenido y lista blanca --------------------------------------------------------

test_report_services_whitelist_only_inspect_fields() {
  _rp_setup
  _rp_container hermes running healthy 2 2026-10-20T10:00:00.000000000Z
  _rp_container jellyfin running unhealthy 0
  _rp_container vaultwarden exited none 5
  _rp_run || return 1
  local r; r="$(_rp_report)"
  assert_not_contains "$r" "$_RP_SECRET_ENV" "no se consultaron campos fuera de la lista blanca" || return 1
  assert_contains "$r" "| Hermes Agent | contenedor | running | healthy | 2 |" || return 1
  assert_contains "$r" "| unhealthy |" || return 1
  assert_contains "$r" "stopped (exited)" || return 1
  assert_contains "$r" "no instalado" "contenedor inexistente" || return 1
  assert_contains "$r" "ghcr.io/x/app:1.2.3" "etiqueta de la imagen" || return 1
  assert_not_contains "$r" "sha256" "sin digest" || return 1
  # Toda llamada a 'inspect' usa -f con solo campos permitidos.
  local line
  while IFS= read -r line; do
    [[ "$line" == *$'\tinspect\t-f\t'* ]] || { fail "inspect sin formato: $line"; return 1; }
    case "$line" in *Env*|*Labels*|*Mounts*|*Cmd*|*Args*|*Entrypoint*) fail "campo prohibido: $line"; return 1 ;; esac
  done < <(grep -P '^docker\tinspect\t' "$STUB_CALL_LOG")
  grep -qP '^docker\tinspect\t' "$STUB_CALL_LOG" || { fail "no consultó docker"; return 1; }
}

test_report_includes_local_service_failed_units_backup_and_tailscale() {
  _rp_setup
  mkdir -p "$HLI2_LOCAL_SERVICES_DIR"
  chmod 0755 "$HLI2_LOCAL_SERVICES_DIR" "$(dirname "$HLI2_LOCAL_SERVICES_DIR")"
  cat > "$HLI2_LOCAL_SERVICES_DIR/miapp.conf" <<'CONF'
SERVICE_NAME="Mi App"
SERVICE_KIND="container"
SERVICE_CONTAINER="miapp"
SERVICE_PORT=""
SERVICE_URL_SCHEME=""
SERVICE_DATA=()
SERVICE_BACKUP_KIND="none"
CONF
  chmod 0644 "$HLI2_LOCAL_SERVICES_DIR/miapp.conf"
  _rp_container miapp
  export STUB_RP_FAILED="foo.service loaded failed failed Foo thing"
  mkdir -p "$BACKUP_STATE_DIR"
  printf 'timestamp=2026-10-22T04:00:00+00:00\nresult=warning\nlocal=ok\ncloud=error\ncheck=skipped\nmessage=la copia externa fallo\n' > "$BACKUP_STATE_DIR/backup-status"
  local tsb="$HLI2_TEST_SCRATCH/rpbin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tsb/tailscale"; chmod +x "$tsb/tailscale"
  _rp_run || return 1
  local r; r="$(_rp_report)"
  assert_contains "$r" "Mi App (local)" || return 1
  assert_contains "$r" "foo.service loaded failed failed" || return 1
  assert_contains "$r" "Resultado: warning" || return 1
  assert_contains "$r" "Copia externa: error" || return 1
  assert_contains "$r" "Conectado." "Tailscale arriba, sin IP" || return 1
  assert_contains "$r" "zona horaria" || return 1
  assert_contains "$r" "## Disco" || return 1
}

test_report_log_errors_are_filtered_and_limited() {
  _rp_setup
  _rp_container hermes
  { local i; for i in $(seq 1 60); do echo "2026-10-22 info all fine $i"; echo "2026-10-22 ERROR boom number $i"; done; } > "$STUB_RP_DIR/logs/hermes"
  _rp_run || return 1
  local r; r="$(_rp_report)"
  assert_contains "$r" "boom number 60" || return 1
  assert_not_contains "$r" "boom number 40" "solo las últimas 20" || return 1
  assert_not_contains "$r" "all fine" "solo líneas con error|warn|fail" || return 1
  assert_eq "20" "$(grep -c 'boom number' <<<"$r")" || return 1
}

# --- Tamaño y escritura atómica --------------------------------------------------------

test_report_size_cap() {
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; head -c 5000 /dev/zero | tr '\0' 'x' | _report_cap 100 ) )"
  (( ${#out} < 200 )) || { fail "no recortó (${#out})"; return 1; }
  assert_contains "$out" "recortado" || return 1
  _rp_setup
  _rp_container hermes
  { local i; for i in $(seq 1 400); do printf 'error %s %0400d\n' "$i" 7; done; } > "$STUB_RP_DIR/logs/hermes"
  _rp_run || return 1
  local size; size="$(stat -c %s "$APPDATA_ROOT/hermes-report/report.md")"
  (( size <= 65536 + 100 )) || { fail "informe de $size bytes"; return 1; }
}

test_report_atomic_write_permissions_and_no_leftovers() {
  _rp_setup
  mkdir -p "$APPDATA_ROOT/hermes-report"
  printf 'VIEJO\n' > "$APPDATA_ROOT/hermes-report/report.md"
  _rp_run || return 1
  assert_eq "644" "$(stat -c %a "$APPDATA_ROOT/hermes-report/report.md")" || return 1
  assert_eq "755" "$(stat -c %a "$APPDATA_ROOT/hermes-report")" || return 1
  assert_not_contains "$(_rp_report)" "VIEJO" || return 1
  assert_eq "report.md" "$(ls -A "$APPDATA_ROOT/hermes-report")" "sin temporales" || return 1
}

test_report_failed_write_keeps_previous_report() {
  _rp_setup
  mkdir -p "$APPDATA_ROOT/hermes-report"
  printf 'VIEJO\n' > "$APPDATA_ROOT/hermes-report/report.md"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$HLI2_TEST_SCRATCH/rpbin/mv"; chmod +x "$HLI2_TEST_SCRATCH/rpbin/mv"
  if _rp_run; then fail "debió fallar si mv falla"; return 1; fi
  assert_eq "VIEJO" "$(_rp_report)" "el informe anterior queda intacto" || return 1
  assert_eq "report.md" "$(ls -A "$APPDATA_ROOT/hermes-report")" "no sobra el temporal" || return 1
}

test_report_refuses_symlinked_directory() {
  _rp_setup
  mkdir -p "$HLI2_TEST_SCRATCH/elsewhere"
  ln -s "$HLI2_TEST_SCRATCH/elsewhere" "$APPDATA_ROOT/hermes-report"
  if _rp_run; then fail "debió negarse"; return 1; fi
  [[ -z "$(ls -A "$HLI2_TEST_SCRATCH/elsewhere")" ]] || { fail "escribió a través del enlace"; return 1; }
}

# --- Guardia de root y copia instalada ---------------------------------------------------

test_report_entrypoint_root_guards() {
  _rp_setup
  local out
  out="$(env -u HLI2_BACKUP_EXPECT_UID bash "$REPO_ROOT/bin/hli2-report" 2>&1)" && { fail "debió negarse a correr código del usuario"; return 1; }
  assert_contains "$out" "no es de root" || return 1
  out="$(env -u HLI2_BACKUP_ALLOW_NONROOT bash "$REPO_ROOT/bin/hli2-report" 2>&1)" && { fail "debió exigir root"; return 1; }
  assert_contains "$out" "debe correr como root" || return 1
  if bash "$REPO_ROOT/bin/hli2-report" extra >/dev/null 2>&1; then fail "debió rechazar argumentos"; return 1; fi
}

test_report_refresh_install_copies_the_report_entrypoint() {
  _rp_setup
  local fake="$HLI2_TEST_SCRATCH/co"
  mkdir -p "$fake"/{bin,lib,services,config}
  cp "$REPO_ROOT/bin/hli2-backup" "$REPO_ROOT/bin/hli2-report" "$fake/bin/"
  cp "$REPO_ROOT"/lib/*.sh "$fake/lib/"; cp "$REPO_ROOT"/services/*.conf "$fake/services/"; cp "$REPO_ROOT/config/default.conf" "$fake/config/"
  ( cd / && source "$fake/lib/core.sh" && backup_refresh_install ) || { fail "refresh falló"; return 1; }
  assert_eq "755" "$(stat -c %a "$BACKUP_INSTALL_DIR/bin/hli2-report")" || return 1
  cmp -s "$REPO_ROOT/lib/report.sh" "$BACKUP_INSTALL_DIR/lib/report.sh" || { fail "falta lib/report.sh"; return 1; }
  bash "$BACKUP_INSTALL_DIR/bin/hli2-report" || { fail "el informe desde la copia debió funcionar"; return 1; }
}

test_report_dir_is_not_in_backups() {
  _rp_setup
  mkdir -p "$APPDATA_ROOT/hermes" "$APPDATA_ROOT/hermes-report"
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; _backup_collect; printf '%s\n' "${BK_PATHS[@]}" ) )"
  assert_contains "$out" "$APPDATA_ROOT/hermes" "los datos de Hermes sí" || return 1
  assert_not_contains "$out" "hermes-report" "el informe es regenerable" || return 1
}

# --- Compose ----------------------------------------------------------------------------------

test_report_compose_mount_is_readonly_valid_and_matches_soul_path() {
  _rp_setup
  local out vols
  out="$( ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes 10.213.144.0/24 1.1.1.1 America/Santiago 192.168.99.10 ) )" || return 1
  assert_contains "$out" "- $APPDATA_ROOT/hermes-report:/opt/host-report:ro" || return 1
  vols="$(sed -n '/volumes:/,/deploy:/p' <<<"$out" | grep -c '^[[:space:]]*- ')"
  assert_eq "2" "$vols" "solo dos montajes" || return 1
  assert_eq "/opt/host-report" "$( ( source "$REPO_ROOT/modules/hermes.sh"; echo "$HERMES_REPORT_CONTAINER_DIR" ) )" "ruta única en módulo y compose" || return 1
  if PATH="$ORIGINAL_PATH" docker compose version >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$HLI2_TEST_SCRATCH/compose.yml"
    PATH="$ORIGINAL_PATH" docker compose -f "$HLI2_TEST_SCRATCH/compose.yml" config -q 2>/dev/null || { fail "docker compose config rechazó el compose"; return 1; }
  fi
}



# --- SOUL.md ------------------------------------------------------------------------------------------

_rp_soul() { ( source "$REPO_ROOT/modules/hermes.sh"; "$@" ); }

test_report_soul_block_inserted_updated_and_content_preserved() {
  local f="$APPDATA_ROOT/hermes/SOUL.md" out
  mkdir -p "$APPDATA_ROOT/hermes"
  printf 'Persona base.\n\nMi regla propia.\n' > "$f"
  _rp_soul _hermes_soul_apply || return 1
  out="$(< "$f")"
  assert_contains "$out" "Persona base." || return 1
  assert_contains "$out" "<!-- HLI2:BEGIN -->" || return 1
  assert_contains "$out" "/opt/host-report/report.md" || return 1
  assert_contains "$out" "Responda siempre en español" || return 1
  assert_contains "$out" "cronjob" || return 1
  # Contenido agregado después (por el agente) y bloque viejo: se actualiza solo el bloque.
  sed -i 's/Responda siempre en español/TEXTO VIEJO/' "$f"
  printf '\nNota del agente.\n' >> "$f"
  _rp_soul _hermes_soul_apply || return 1
  out="$(< "$f")"
  assert_not_contains "$out" "TEXTO VIEJO" || return 1
  assert_contains "$out" "Responda siempre en español" || return 1
  assert_contains "$out" "Mi regla propia." || return 1
  assert_contains "$out" "Nota del agente." || return 1
  assert_eq "1" "$(grep -c 'HLI2:BEGIN' "$f")" "un solo bloque" || return 1
  # Idempotente.
  local before; before="$(< "$f")"
  _rp_soul _hermes_soul_apply || return 1
  assert_eq "$before" "$(< "$f")" || return 1
}

test_report_soul_refuses_broken_markers_symlink_and_missing_file() {
  local f="$APPDATA_ROOT/hermes/SOUL.md" rc=0
  mkdir -p "$APPDATA_ROOT/hermes"
  _rp_soul _hermes_soul_apply || rc=$?
  assert_eq "2" "$rc" "sin SOUL.md no se crea" || return 1
  [[ ! -e "$f" ]] || { fail "creó SOUL.md"; return 1; }
  printf 'a\n<!-- HLI2:BEGIN -->\nsin fin\n' > "$f"
  rc=0; _rp_soul _hermes_soul_apply || rc=$?
  assert_eq "1" "$rc" "marcadores incompletos" || return 1
  assert_eq $'a\n<!-- HLI2:BEGIN -->\nsin fin' "$(< "$f")" "el archivo queda intacto" || return 1
  rm -f "$f"; printf 'x\n' > "$APPDATA_ROOT/target"; ln -s "$APPDATA_ROOT/target" "$f"
  rc=0; _rp_soul _hermes_soul_apply || rc=$?
  assert_eq "1" "$rc" "enlace simbólico" || return 1
  assert_eq "x" "$(< "$APPDATA_ROOT/target")" || return 1
}

