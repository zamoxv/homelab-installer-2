#!/usr/bin/env bash
# Test end-to-end de modules/hermes.sh (todo lo privilegiado/de red
# stubbeado). Comprueba: los secretos nunca viajan por argv, logs ni compose
# versionado; config.yaml se siembra solo si falta (aprobación manual,
# data_collection deny, todas las tareas auxiliares fijadas); los puertos se
# publican solo en la IP de la LAN y en la de Tailscale; el compose no tiene
# docker.sock, red del host ni imagen ':latest'; una re-ejecución conserva
# los secretos; claves de OpenRouter inválidas se rechazan; un /health caído
# da un mensaje claro y no muestra credenciales; el registro de servicios es
# válido y el backup incluye los datos de Hermes.

_HM_LAN="192.0.2.10"
_HM_TS="100.64.0.1"
_HM_OR_KEY="sk-or-v1-$(printf 'ab%.0s' {1..32})"
_HM_TASKS=(vision compression skills_hub approval review mcp title_generation
  memory_query_rewrite tts_audio_tags voice_chat triage_specifier
  kanban_decomposer profile_describer goal_judge curator monitor
  background_review moa_reference moa_aggregator)

_hm_setup() {
  harness_mark_canary_done
  export STUB_HOSTNAME_I="$_HM_LAN"
  export HLI2_HERMES_HEALTH_TIMEOUT=1 HLI2_HERMES_HEALTH_STEP=1
  export STUB_TEXTBOX_LOG="$HLI2_TEST_SCRATCH/textbox.log"
  : > "$STUB_TEXTBOX_LOG"
  # Hermético: sin sesión de Tailscale aunque el equipo que corre los tests
  # tenga el 'tailscale' real instalado.
  local off="$HLI2_TEST_SCRATCH/tsoff"
  mkdir -p "$off"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$off/tailscale"
  chmod +x "$off/tailscale"
  export PATH="$off:$PATH"
}

# Tailscale "activo": el stub de tailscale (no está en el PATH base) en un
# directorio propio.
_hm_tailscale_up() {
  local bin="$HLI2_TEST_SCRATCH/tsbin"
  mkdir -p "$bin"
  cp "$REPO_ROOT/tests/stubs/fake/tailscale" "$bin/tailscale"
  export PATH="$bin:$PATH"
}

_hm_dialog_text() { grep -F $'dialog\t' "$STUB_CALL_LOG" || true; }

# Primera ejecución: clave de OpenRouter, dos modelos, y "sí" a "guardé las
# credenciales".
_hm_first_run_queues() {
  echo "$_HM_OR_KEY" > "$DIALOG_PASSWORDBOX_QUEUE"
  printf '%s\n%s\n' "deepseek/deepseek-v4.1-flash" "qwen/qwen3.7-flash" > "$DIALOG_INPUTBOX_QUEUE"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
}

# Estado de una instalación previa: secretos guardados (pendiente=0) y datos.
_hm_seed_previous() {
  local pending="${1:-0}"
  chmod u+rwx "$SECRETS_DIR"
  {
    echo "OPENROUTER_API_KEY=${_HM_OR_KEY}"
    echo "API_SERVER_KEY=$(printf 'cd%.0s' {1..32})"
    echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=Abcdefghijklmnopqrstuvwx"
    echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(printf 'ef%.0s' {1..32})"
    echo "HLI_CREDENTIALS_PENDING=${pending}"
  } > "$SECRETS_DIR/hermes.env"
  chmod 0600 "$SECRETS_DIR/hermes.env"
  chmod 000 "$SECRETS_DIR"
}

_hm_secret() { ( source "$REPO_ROOT/lib/core.sh"; secret_get hermes "$1" ); }

test_hermes_deploy_ok() {
  _hm_setup
  _hm_first_run_queues

  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$STATE_FILE" "hermes" "mark_done" || return 1

  # Secretos: root-only, con las cuatro claves y forma correcta.
  local f="$SECRETS_DIR/hermes.env" mode api pass sec
  mode="$(sudo -n stat -c '%a' -- "$f")" || return 1
  assert_eq "600" "$mode" "modo del archivo de secretos" || return 1
  assert_eq "$_HM_OR_KEY" "$(_hm_secret OPENROUTER_API_KEY)" || return 1
  api="$(_hm_secret API_SERVER_KEY)"
  [[ "$api" =~ ^[0-9a-f]{64}$ ]] || { fail "API_SERVER_KEY no son 64 hex: [$api]"; return 1; }
  pass="$(_hm_secret HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)"
  [[ "$pass" =~ ^[A-Za-z0-9]{24}$ ]] || { fail "contraseña del dashboard inesperada"; return 1; }
  sec="$(_hm_secret HERMES_DASHBOARD_BASIC_AUTH_SECRET)"
  [[ "$sec" =~ ^[0-9a-f]{64}$ ]] || { fail "secreto del dashboard inesperado"; return 1; }
  assert_eq "0" "$(_hm_secret HLI_CREDENTIALS_PENDING)" "credenciales confirmadas" || return 1

  # Llegan por el canal env, entre comillas simples; el compose usa referencias.
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "OPENROUTER_API_KEY='${_HM_OR_KEY}'" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "API_SERVER_KEY='${api}'" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD='${pass}'" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "HERMES_DASHBOARD_BASIC_AUTH_SECRET='${sec}'" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" '${OPENROUTER_API_KEY}' || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "gateway run" || return 1

  # Nunca en argv ni en logs.
  local s
  for s in "$_HM_OR_KEY" "$api" "$pass" "$sec"; do
    assert_file_not_contains "$STUB_CALL_LOG" "$s" "secreto fuera de argv" || return 1
    if grep -rqF -- "$s" "$LOG_DIR" 2>/dev/null; then fail "un secreto apareció en $LOG_DIR"; return 1; fi
  done

  # La clave de la API viaja a curl por stdin (-K -), no por argv.
  # (el formato de -w lleva un salto de línea: el log parte la llamada en dos líneas)
  grep -qF $'\t-K\t-\thttp://'"${_HM_LAN}:8642/v1/models" "$STUB_CALL_LOG" \
    || { fail "/v1/models debe usar -K - para la clave"; return 1; }
  grep -F "http://${_HM_LAN}:8642/health" "$STUB_CALL_LOG" >/dev/null \
    || { fail "no se consultó /health en la IP de la LAN"; return 1; }

  # Credenciales mostradas una vez (textbox), con el dato de conexión.
  local shown; shown="$(< "$STUB_TEXTBOX_LOG")"
  assert_contains "$shown" "$api" "clave de API mostrada" || return 1
  assert_contains "$shown" "$pass" "contraseña del dashboard mostrada" || return 1
  assert_contains "$shown" "Usuario: admin" || return 1

  # Mensaje final: APK, LAN/Tailscale únicamente.
  local texts; texts="$(_hm_dialog_text)"
  assert_contains "$texts" "github.com/rusty4444/hermes-android/releases" || return 1
  assert_contains "$texts" "solo se publican en la IP de la LAN y en la de Tailscale" || return 1
  assert_contains "$texts" "límite de crédito de 5 USD" "explica el límite mensual de la clave" || return 1
}

test_hermes_data_dir_ownership() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  local uid gid
  uid="$(id -u)"; gid="$(id -g)"
  assert_file_contains "$STUB_CALL_LOG" $'install\t-d\t-m\t0750\t-o\t'"${uid}"$'\t-g\t'"${gid}"$'\t'"$APPDATA_ROOT/hermes" "carpeta de datos 0750 uid/gid de SERVER_USER" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'install\t-m\t0640\t-o\t'"${uid}"$'\t-g\t'"${gid}"$'\t/dev/null\t'"$APPDATA_ROOT/hermes/config.yaml" "config.yaml con dueño HERMES_UID" || return 1
  # HERMES_UID/GID del compose coinciden con el dueño de la carpeta.
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "HERMES_UID=${uid}" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "HERMES_GID=${gid}" || return 1
}

test_hermes_config_seeded_contents() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  local cfg="$APPDATA_ROOT/hermes/config.yaml" t
  [[ -f "$cfg" ]] || { fail "no se sembró config.yaml"; return 1; }
  assert_file_contains "$cfg" "mode: manual" "aprobaciones manuales" || return 1
  assert_file_contains "$cfg" "data_collection: deny" || return 1
  assert_file_contains "$cfg" "backend: local" || return 1
  assert_file_contains "$cfg" "default: deepseek/deepseek-v4.1-flash" || return 1
  assert_file_contains "$cfg" "fallback_providers:" || return 1
  assert_file_contains "$cfg" "website_blocklist:" || return 1
  assert_file_not_contains "$cfg" "provider: auto" "nada en auto" || return 1
  assert_file_not_contains "$cfg" "sk-or-" "sin secretos en config.yaml" || return 1
  local body; body="$(< "$cfg")"
  assert_contains "$body" $'  website_blocklist:\n    enabled: true' || return 1
  # Cada tarea auxiliar fijada a OpenRouter + el modelo barato.
  for t in "${_HM_TASKS[@]}"; do
    assert_contains "$body" $'\n  '"${t}"$':\n    provider: openrouter\n    model: qwen/qwen3.7-flash\n' "tarea auxiliar $t" || return 1
  done
  # 1 principal + 1 respaldo + N auxiliares.
  assert_eq "$(( ${#_HM_TASKS[@]} + 2 ))" "$(grep -c 'provider: openrouter' "$cfg")" "cantidad de proveedores fijados" || return 1
  # YAML válido, si hay PyYAML disponible.
  if python3 -I -c 'import yaml' 2>/dev/null; then
    python3 -I -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$cfg" || { fail "config.yaml no es YAML válido"; return 1; }
  fi
}

test_hermes_config_not_overwritten_and_secrets_kept_on_rerun() {
  _hm_setup
  _hm_seed_previous 0
  mkdir -p "$APPDATA_ROOT/hermes"
  printf '# editado por el usuario\nmodel:\n  default: otro/modelo\n' > "$APPDATA_ROOT/hermes/config.yaml"
  : > "$DIALOG_PASSWORDBOX_QUEUE"     # si pidiera la clave, cancelaría
  : > "$DIALOG_YESNO_QUEUE"           # todas las preguntas -> No

  bash "$REPO_ROOT/modules/hermes.sh" || return 1

  assert_eq $'# editado por el usuario\nmodel:\n  default: otro/modelo' "$(< "$APPDATA_ROOT/hermes/config.yaml")" "config.yaml intacto" || return 1
  assert_eq "$(printf 'cd%.0s' {1..32})" "$(_hm_secret API_SERVER_KEY)" "API_SERVER_KEY conservada" || return 1
  assert_eq "$_HM_OR_KEY" "$(_hm_secret OPENROUTER_API_KEY)" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "API_SERVER_KEY='$(printf 'cd%.0s' {1..32})'" "el compose reutiliza la clave" || return 1
  if grep -qF -- '--passwordbox' "$STUB_CALL_LOG"; then fail "volvió a pedir la clave de OpenRouter"; return 1; fi
  assert_eq "" "$(< "$STUB_TEXTBOX_LOG")" "no se vuelven a mostrar credenciales ya confirmadas" || return 1
}

test_hermes_rerun_can_rotate_api_key_and_change_models() {
  _hm_setup
  _hm_seed_previous 0
  mkdir -p "$APPDATA_ROOT/hermes"
  printf '# mio\n' > "$APPDATA_ROOT/hermes/config.yaml"
  # rotar API: sí; reemplazar OpenRouter: no; cambiar modelos: sí; guardé creds: sí
  printf 'yes\nno\nyes\nyes\n' > "$DIALOG_YESNO_QUEUE"
  printf '%s\n%s\n' "foo/bar-model" "foo/aux-model" > "$DIALOG_INPUTBOX_QUEUE"
  : > "$DIALOG_PASSWORDBOX_QUEUE"

  bash "$REPO_ROOT/modules/hermes.sh" || return 1

  local new; new="$(_hm_secret API_SERVER_KEY)"
  [[ "$new" =~ ^[0-9a-f]{64}$ && "$new" != "$(printf 'cd%.0s' {1..32})" ]] || { fail "la clave de API no rotó"; return 1; }
  assert_eq "$_HM_OR_KEY" "$(_hm_secret OPENROUTER_API_KEY)" "la clave de OpenRouter se conserva" || return 1
  assert_contains "$(< "$STUB_TEXTBOX_LOG")" "$new" "la clave nueva se muestra" || return 1
  assert_eq "0" "$(_hm_secret HLI_CREDENTIALS_PENDING)" || return 1
  # El archivo del usuario no se toca; los modelos se cambian con la CLI de Hermes.
  assert_eq "# mio" "$(< "$APPDATA_ROOT/hermes/config.yaml")" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tmodel.default\tfoo/bar-model' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.vision.model\tfoo/aux-model' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.moa_aggregator.model\tfoo/aux-model' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'docker\trestart\thermes' || return 1
}

test_hermes_ports_only_on_lan_and_tailscale_ips() {
  _hm_setup
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$_HM_LAN" "$_HM_TS" ) )" || return 1
  assert_contains "$out" "- \"${_HM_LAN}:8642:8642\"" || return 1
  assert_contains "$out" "- \"${_HM_LAN}:9119:9119\"" || return 1
  assert_contains "$out" "- \"${_HM_TS}:8642:8642\"" || return 1
  assert_contains "$out" "- \"${_HM_TS}:9119:9119\"" || return 1
  assert_not_contains "$out" '"0.0.0.0:' "nunca 0.0.0.0 del host" || return 1
  # Ningún puerto "pelado" (publicado en todas las interfaces).
  if grep -Eq '^[[:space:]]*-[[:space:]]*"?(8642|9119)(:|")' <<<"$out"; then
    fail "hay un puerto sin IP"; return 1
  fi
  if grep -Eq '^[[:space:]]*-[[:space:]]*"?[0-9]+:[0-9]+' <<<"$out"; then
    fail "hay un puerto publicado sin IP"; return 1
  fi
  assert_not_contains "$out" "__" "sin marcadores sin sustituir" || return 1
  # Entradas inválidas.
  local bad
  for bad in "0.0.0.0" "" "300.1.1.1" "abc" "1.2.3"; do
    if ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$bad" ) >/dev/null 2>&1; then
      fail "aceptó la IP inválida [$bad]"; return 1
    fi
  done
  if ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes ) >/dev/null 2>&1; then
    fail "aceptó cero IPs"; return 1
  fi
}

test_hermes_deploy_binds_lan_only_without_tailscale() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "${_HM_LAN}:8642:8642" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "${_HM_TS}:8642" "sin Tailscale no hay IP de Tailscale" || return 1
  assert_contains "$(_hm_dialog_text)" "Tailscale no está activo" || return 1
}

test_hermes_deploy_binds_lan_and_tailscale() {
  _hm_setup
  _hm_tailscale_up
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "${_HM_LAN}:8642:8642" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "${_HM_TS}:8642:8642" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "${_HM_TS}:9119:9119" || return 1
  assert_file_contains "$STUB_TEXTBOX_LOG" "http://${_HM_TS}:8642" "dato de conexión por Tailscale" || return 1
}

test_hermes_invalid_lan_ip_aborts() {
  _hm_setup
  export STUB_HOSTNAME_I=" "
  _hm_first_run_queues
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió fallar sin IP de LAN"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "No se pudo determinar la IP de la LAN" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "compose.create" || return 1
  assert_file_not_contains "$STATE_FILE" "hermes" || return 1
}

test_hermes_compose_template_hardening() {
  local f="$REPO_ROOT/compose/hermes/docker-compose.yml" code
  # Sin comentarios para no confundir las búsquedas con la documentación.
  code="$(grep -v '^[[:space:]]*#' "$f")"
  assert_not_contains "$code" "docker.sock" "sin socket de Docker" || return 1
  assert_not_contains "$code" "network_mode" "sin red del host" || return 1
  assert_not_contains "$code" "privileged" || return 1
  assert_not_contains "$code" "cap_add" || return 1
  assert_not_contains "$code" ":latest" "imagen fijada" || return 1
  assert_not_contains "$code" "/srv" "sin /srv" || return 1
  assert_not_contains "$code" "/home" "sin el home" || return 1
  assert_not_contains "$code" "dokploy-network" "sin Traefik" || return 1
  assert_not_contains "$code" "traefik" || return 1
  grep -Eq '^[[:space:]]*image: nousresearch/hermes-agent:v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$code" \
    || { fail "la imagen debe estar fijada a una versión vX.Y.Z"; return 1; }
  assert_contains "$code" "command: gateway run" || return 1
  assert_contains "$code" "restart: unless-stopped" || return 1
  assert_contains "$code" "shm_size: 1g" || return 1
  assert_contains "$code" "memory: 4G" || return 1
  assert_contains "$code" 'cpus: "2.0"' || return 1
  assert_contains "$code" "container_name: hermes" || return 1
  # Solo el directorio de datos está montado.
  assert_eq "1" "$(grep -c '^[[:space:]]*- .*:/' <<<"$(sed -n '/volumes:/,/deploy:/p' <<<"$code")")" "un único montaje" || return 1
  assert_contains "$code" "__APPDATA__/hermes:/opt/data" || return 1
  # Los secretos son solo referencias ${VAR}; ningún valor literal.
  local v
  for v in OPENROUTER_API_KEY API_SERVER_KEY HERMES_DASHBOARD_BASIC_AUTH_PASSWORD HERMES_DASHBOARD_BASIC_AUTH_SECRET; do
    assert_contains "$code" "- ${v}=\${${v}}" "referencia de $v" || return 1
  done
  assert_not_contains "$code" "sk-or-" || return 1
  # Dashboard con autenticación y API habilitada con clave.
  assert_contains "$code" "HERMES_DASHBOARD=1" || return 1
  assert_contains "$code" "API_SERVER_ENABLED=true" || return 1
  # Lo que realmente se envía a Dokploy tampoco lleva docker.sock ni host.
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "/docker.sock" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "network_mode" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "hermes-agent:latest" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" '"composeType": "docker-compose"' "composeType docker-compose" || return 1
}

test_hermes_invalid_openrouter_key_rejected() {
  _hm_setup
  local bad
  for bad in "hola" "sk-or-" "sk-or-corta" "sk-ant-$(printf 'a%.0s' {1..40})" "${_HM_OR_KEY}'; rm -rf /" "${_HM_OR_KEY} extra"; do
    : > "$STUB_CALL_LOG"
    echo "$bad" > "$DIALOG_PASSWORDBOX_QUEUE"
    : > "$DIALOG_INPUTBOX_QUEUE"
    if bash "$REPO_ROOT/modules/hermes.sh"; then fail "aceptó una clave inválida: [$bad]"; return 1; fi
    assert_contains "$(_hm_dialog_text)" "no tiene la forma de una clave de OpenRouter" "mensaje para [$bad]" || return 1
    ( source "$REPO_ROOT/lib/core.sh"; secret_file_exists hermes ) && { fail "guardó una clave inválida"; return 1; }
    assert_file_not_contains "$STATE_FILE" "hermes" || return 1
  done
}

test_hermes_cancel_shows_message() {
  _hm_setup
  : > "$DIALOG_PASSWORDBOX_QUEUE"
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió fallar al cancelar"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "Se cancela el despliegue de Hermes" || return 1
}

test_hermes_invalid_model_id_rejected() {
  _hm_setup
  echo "$_HM_OR_KEY" > "$DIALOG_PASSWORDBOX_QUEUE"
  printf '%s\n%s\n' "modelo con espacios" "qwen/qwen3.7-flash" > "$DIALOG_INPUTBOX_QUEUE"
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "aceptó un id de modelo inválido"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "no tiene la forma autor/modelo" || return 1
  [[ ! -e "$APPDATA_ROOT/hermes/config.yaml" ]] || { fail "sembró config.yaml con un modelo inválido"; return 1; }
}

test_hermes_health_failure_gives_clear_message() {
  _hm_setup
  _hm_first_run_queues
  export STUB_HERMES_HEALTH_FAIL=1
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió fallar con /health caído"; return 1; fi
  local texts; texts="$(_hm_dialog_text)"
  assert_contains "$texts" "/health no respondió OK a tiempo" || return 1
  assert_contains "$texts" "docker logs" "indica cómo ver los logs" || return 1
  assert_eq "" "$(< "$STUB_TEXTBOX_LOG")" "sin credenciales si la API no responde" || return 1
  assert_file_not_contains "$STATE_FILE" "hermes" "no se marca como hecho" || return 1
}

test_hermes_models_endpoint_rejection_gives_clear_message() {
  _hm_setup
  _hm_first_run_queues
  export STUB_HERMES_MODELS_CODE=401
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió fallar con /v1/models 401"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "/v1/models con la clave de API no devolvió 200" || return 1
  assert_eq "" "$(< "$STUB_TEXTBOX_LOG")" || return 1
  assert_file_not_contains "$STATE_FILE" "hermes" || return 1
}

test_hermes_credentials_shown_again_until_confirmed() {
  _hm_setup
  echo "$_HM_OR_KEY" > "$DIALOG_PASSWORDBOX_QUEUE"
  printf '%s\n%s\n' "deepseek/deepseek-v4.1-flash" "qwen/qwen3.7-flash" > "$DIALOG_INPUTBOX_QUEUE"
  : > "$DIALOG_YESNO_QUEUE"      # nunca confirma
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió fallar sin confirmar"; return 1; fi
  assert_eq "1" "$(_hm_secret HLI_CREDENTIALS_PENDING)" "queda pendiente" || return 1
  assert_file_not_contains "$STATE_FILE" "hermes" || return 1
  # Re-ejecución: rotar no, reemplazar no, cambiar modelos no, guardadas sí.
  : > "$STUB_TEXTBOX_LOG"
  printf 'no\nno\nno\nyes\n' > "$DIALOG_YESNO_QUEUE"
  : > "$DIALOG_PASSWORDBOX_QUEUE"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_contains "$(< "$STUB_TEXTBOX_LOG")" "$(_hm_secret API_SERVER_KEY)" "se muestran de nuevo" || return 1
  assert_eq "0" "$(_hm_secret HLI_CREDENTIALS_PENDING)" || return 1
  assert_file_contains "$STATE_FILE" "hermes" || return 1
}

test_hermes_registry_and_backup_paths() {
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; service_list ) )"
  grep -qx hermes <<<"$out" || { fail "hermes no aparece en service_list"; return 1; }
  out="$( ( source "$REPO_ROOT/lib/core.sh"
    echo "c=$(service_get hermes CONTAINER)"
    echo "k=$(service_get hermes BACKUP_KIND)"
    echo "d=$(service_get hermes DATA)"
    echo "p=$(service_get hermes PORT)" ) )"
  assert_contains "$out" "c=hermes" || return 1
  assert_contains "$out" "k=sqlite" "se detiene durante la foto (SQLite)" || return 1
  assert_contains "$out" "d=$APPDATA_ROOT/hermes" || return 1
  assert_contains "$out" "p=9119" || return 1
  # El backup incluye la carpeta de datos y detiene el contenedor.
  mkdir -p "$APPDATA_ROOT/hermes"
  out="$( ( source "$REPO_ROOT/lib/core.sh"; _backup_collect
    printf 'full:%s\n' "${BK_PATHS[@]}"; printf 'cloud:%s\n' "${BK_CLOUD_PATHS[@]}"
    printf 'sqlite:%s\n' "$(_backup_sqlite_containers)" ) )"
  assert_contains "$out" "full:$APPDATA_ROOT/hermes" || return 1
  assert_contains "$out" "cloud:$APPDATA_ROOT/hermes" || return 1
  assert_contains "$out" "hermes" "contenedor sqlite" || return 1
}
