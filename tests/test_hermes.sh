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

_HM_LAN="192.168.99.10"
_HM_SUBNET="10.213.144.0/24"
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
  export HLI2_HERMES_SBIN_DIR="$HLI2_TEST_SCRATCH/sbin"
  export HLI2_SYSTEMD_DIR="$HLI2_TEST_SCRATCH/systemd"
  export HLI2_DOCKER_DROPIN_DIR="$HLI2_TEST_SCRATCH/docker.service.d"
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

# Tailscale con una IP concreta (por defecto la de la tailnet de prueba).
_hm_tailscale_ip_is() {
  local bin="$HLI2_TEST_SCRATCH/tsbin2"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\n[[ "${1:-}" == "ip" ]] && { echo "%s"; exit 0; }\nexit 1\n' "$1" > "$bin/tailscale"
  chmod +x "$bin/tailscale"
  export PATH="$bin:$PATH"
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
  printf '# mio\nmodel:\n  default: x/y\n' > "$APPDATA_ROOT/hermes/config.yaml"
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
  assert_eq $'# mio\nmodel:\n  default: x/y' "$(< "$APPDATA_ROOT/hermes/config.yaml")" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'exec\t-u\t'"$(id -u):$(id -g)"$'\thermes\t/opt/hermes/.venv/bin/hermes\tconfig\tset\tmodel.default\tfoo/bar-model' "docker exec con el uid/gid del agente" || return 1
  if grep -F $'docker\texec\t' "$STUB_CALL_LOG" | grep -vF $'exec\t-u\t' | grep -q .; then fail "un docker exec corrió sin -u"; return 1; fi
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.vision.model\tfoo/aux-model' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.moa_aggregator.model\tfoo/aux-model' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'docker\trestart\thermes' || return 1
}

test_hermes_ports_only_on_lan_and_tailscale_ips() {
  _hm_setup
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$_HM_SUBNET" "1.1.1.1,9.9.9.9" "$_HM_LAN" "$_HM_TS" ) )" || return 1
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
    if ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$_HM_SUBNET" "1.1.1.1" "$bad" ) >/dev/null 2>&1; then
      fail "aceptó la IP inválida [$bad]"; return 1
    fi
  done
  if ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$_HM_SUBNET" "1.1.1.1" ) >/dev/null 2>&1; then
    fail "aceptó cero IPs"; return 1
  fi
  for bad in "8.8.8.0/24" "10.1.2.0/16" "10.1.2.3/24" "abc"; do
    if ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$bad" "1.1.1.1" "$_HM_LAN" ) >/dev/null 2>&1; then
      fail "aceptó la subred inválida [$bad]"; return 1
    fi
  done
  if ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$_HM_SUBNET" "no-ip" "$_HM_LAN" ) >/dev/null 2>&1; then
    fail "aceptó un DNS inválido"; return 1
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
  assert_contains "$(_hm_dialog_text)" "no es una dirección privada válida" || return 1
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
  grep -Eq '^[[:space:]]*image: nousresearch/hermes-agent:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$' <<<"$code" \
    || { fail "la imagen debe estar fijada a una versión vX.Y.Z y a un digest sha256"; return 1; }
  assert_contains "$code" "no-new-privileges:true" || return 1
  assert_contains "$code" "pids_limit: 512" || return 1
  assert_contains "$code" "subnet: __SUBNET__" "red propia con subred fija" || return 1
  assert_contains "$code" "- hermes-net" || return 1
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

# --- IPs (W1) ------------------------------------------------------------------

test_hermes_rejects_non_private_lan_ips() {
  _hm_setup
  local bad
  for bad in "8.8.8.8" "127.0.0.1" "169.254.10.20" "172.32.0.5" "100.64.0.9" "11.0.0.1"; do
    : > "$STUB_CALL_LOG"
    export STUB_HOSTNAME_I="$bad"
    _hm_first_run_queues
    if bash "$REPO_ROOT/modules/hermes.sh"; then fail "aceptó la IP de LAN [$bad]"; return 1; fi
    assert_contains "$(_hm_dialog_text)" "no es una dirección privada válida" "mensaje para [$bad]" || return 1
    assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "compose.create" || return 1
    rm -f "$SECRETS_DIR/hermes.env" 2>/dev/null || { chmod u+rwx "$SECRETS_DIR"; rm -f "$SECRETS_DIR/hermes.env"; chmod 000 "$SECRETS_DIR"; }
  rm -f "$APPDATA_ROOT/hermes/config.yaml"
  done
}

test_hermes_lan_ip_prefers_default_route_source() {
  _hm_setup
  export STUB_ROUTE_SRC="192.168.99.77"      # interfaz de la ruta por defecto
  export STUB_HOSTNAME_I="172.17.0.1 192.168.99.10"   # hostname -I trae primero el puente de Docker
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "192.168.99.77:8642:8642" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "172.17.0.1:8642" || return 1
}

test_hermes_tailscale_ip_must_be_in_cgnat_range_and_deduped() {
  _hm_setup
  _hm_tailscale_ip_is "8.8.8.8"
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "8.8.8.8:8642" "IP fuera de 100.64/10 ignorada" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "${_HM_LAN}:8642:8642" || return 1

  : > "$STUB_HTTP_BODIES_LOG"
  _hm_tailscale_ip_is "$_HM_LAN"          # duplicada con la de la LAN
  rm -f "$SECRETS_DIR/hermes.env" 2>/dev/null || { chmod u+rwx "$SECRETS_DIR"; rm -f "$SECRETS_DIR/hermes.env"; chmod 000 "$SECRETS_DIR"; }
  rm -f "$APPDATA_ROOT/hermes/config.yaml"
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_eq "1" "$(grep -o "${_HM_LAN}:8642:8642" "$STUB_HTTP_BODIES_LOG" | wc -l | tr -d ' ')" "sin duplicar la IP" || return 1
}

# --- config.yaml atómico (W3) ------------------------------------------------------

test_hermes_empty_config_is_reseeded() {
  _hm_setup
  _hm_seed_previous 0
  mkdir -p "$APPDATA_ROOT/hermes"
  : > "$APPDATA_ROOT/hermes/config.yaml"
  : > "$DIALOG_YESNO_QUEUE"
  printf '%s\n%s\n' "deepseek/deepseek-v4.1-flash" "qwen/qwen3.7-flash" > "$DIALOG_INPUTBOX_QUEUE"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$APPDATA_ROOT/hermes/config.yaml" "mode: manual" "reescrito" || return 1
}

test_hermes_invalid_config_is_backed_up_and_reseeded_atomically() {
  _hm_setup
  _hm_seed_previous 0
  mkdir -p "$APPDATA_ROOT/hermes"
  printf 'basura: sin la clave principal\n' > "$APPDATA_ROOT/hermes/config.yaml"
  : > "$DIALOG_YESNO_QUEUE"
  printf '%s\n%s\n' "deepseek/deepseek-v4.1-flash" "qwen/qwen3.7-flash" > "$DIALOG_INPUTBOX_QUEUE"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$APPDATA_ROOT/hermes/config.yaml" "default: deepseek/deepseek-v4.1-flash" || return 1
  local bak; bak="$(ls "$APPDATA_ROOT"/hermes/config.yaml.invalido-* 2>/dev/null | head -1)"
  [[ -n "$bak" ]] || { fail "no se conservó una copia del config.yaml inválido"; return 1; }
  assert_file_contains "$bak" "basura: sin la clave principal" || return 1
  # Atómico: temporal en la misma carpeta y 'mv' sobre el destino; sin restos.
  grep -qP "^sudo\tmv\t-f\t$APPDATA_ROOT/hermes/config\.yaml\.tmp\.[0-9]+\t$APPDATA_ROOT/hermes/config\.yaml$" "$STUB_CALL_LOG" \
    || { fail "la siembra no usó temporal + mv"; return 1; }
  if ls "$APPDATA_ROOT"/hermes/config.yaml.tmp.* >/dev/null 2>&1; then fail "quedó un temporal"; return 1; fi
}

# --- Secretos (W6) ---------------------------------------------------------------------

test_hermes_partial_secrets_file_loads_all_and_generates_only_missing() {
  _hm_setup
  chmod u+rwx "$SECRETS_DIR"
  printf 'OPENROUTER_API_KEY=%s\nHERMES_DASHBOARD_BASIC_AUTH_PASSWORD=Custom1234abcd\n' "$_HM_OR_KEY" > "$SECRETS_DIR/hermes.env"
  chmod 0600 "$SECRETS_DIR/hermes.env"; chmod 000 "$SECRETS_DIR"
  : > "$DIALOG_PASSWORDBOX_QUEUE"; : > "$DIALOG_YESNO_QUEUE"
  printf '%s\n%s\n' "deepseek/deepseek-v4.1-flash" "qwen/qwen3.7-flash" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'no\nno\nyes\n' > "$DIALOG_YESNO_QUEUE"   # rotar: no; reemplazar: no; credenciales guardadas: sí
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_eq "$_HM_OR_KEY" "$(_hm_secret OPENROUTER_API_KEY)" "la clave de OpenRouter no se pierde ni se vuelve a pedir" || return 1
  assert_eq "Custom1234abcd" "$(_hm_secret HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)" "contraseña existente conservada" || return 1
  [[ "$(_hm_secret API_SERVER_KEY)" =~ ^[0-9a-f]{64}$ ]] || { fail "no se generó la clave de API faltante"; return 1; }
  if grep -qF -- '--passwordbox' "$STUB_CALL_LOG"; then fail "volvió a pedir la clave de OpenRouter"; return 1; fi
}

test_hermes_missing_openrouter_key_in_existing_file_prompts_without_rotating_others() {
  _hm_setup
  chmod u+rwx "$SECRETS_DIR"
  printf 'API_SERVER_KEY=%s\nHERMES_DASHBOARD_BASIC_AUTH_PASSWORD=Custom1234abcd\nHERMES_DASHBOARD_BASIC_AUTH_SECRET=%s\nHLI_CREDENTIALS_PENDING=0\n' "$(printf 'ab%.0s' {1..32})" "$(printf 'cd%.0s' {1..32})" > "$SECRETS_DIR/hermes.env"
  chmod 0600 "$SECRETS_DIR/hermes.env"; chmod 000 "$SECRETS_DIR"
  echo "$_HM_OR_KEY" > "$DIALOG_PASSWORDBOX_QUEUE"
  printf '%s\n%s\n' "deepseek/deepseek-v4.1-flash" "qwen/qwen3.7-flash" > "$DIALOG_INPUTBOX_QUEUE"
  printf 'no\n' > "$DIALOG_YESNO_QUEUE"      # rotar API: no
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_eq "$_HM_OR_KEY" "$(_hm_secret OPENROUTER_API_KEY)" || return 1
  assert_eq "$(printf 'ab%.0s' {1..32})" "$(_hm_secret API_SERVER_KEY)" "no rota la clave de API" || return 1
  assert_eq "Custom1234abcd" "$(_hm_secret HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)" || return 1
}

test_hermes_unreadable_secrets_file_aborts_without_regenerating() {
  _hm_setup
  _hm_seed_previous 0
  export STUB_SUDO_FAIL_N=1          # sudo -n no disponible: no se puede leer el archivo
  : > "$DIALOG_YESNO_QUEUE"
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió abortar"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "para no regenerar claves" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "compose" || return 1
  unset STUB_SUDO_FAIL_N
  assert_eq "$_HM_OR_KEY" "$(_hm_secret OPENROUTER_API_KEY)" "el archivo sigue intacto" || return 1
}

test_hermes_malformed_stored_secret_aborts_instead_of_replacing() {
  _hm_setup
  chmod u+rwx "$SECRETS_DIR"
  printf 'OPENROUTER_API_KEY=%s\nAPI_SERVER_KEY=corta\n' "$_HM_OR_KEY" > "$SECRETS_DIR/hermes.env"
  chmod 0600 "$SECRETS_DIR/hermes.env"; chmod 000 "$SECRETS_DIR"
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió abortar"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "forma inesperada" || return 1
  assert_eq "corta" "$(_hm_secret API_SERVER_KEY)" "no se reemplazó" || return 1
}

# --- Health tras cambio de modelos (W2) --------------------------------------------------

test_hermes_health_failure_after_model_change_is_reported() {
  _hm_setup
  _hm_seed_previous 0
  mkdir -p "$APPDATA_ROOT/hermes"
  printf 'model:\n  default: x/y\n' > "$APPDATA_ROOT/hermes/config.yaml"
  printf 'no\nno\nyes\n' > "$DIALOG_YESNO_QUEUE"
  printf '%s\n%s\n' "foo/bar-model" "foo/aux-model" > "$DIALOG_INPUTBOX_QUEUE"
  export STUB_HERMES_HEALTH_FAIL_AFTER_RESTART=1
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió fallar"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "no volvió a responder a tiempo" || return 1
  assert_file_not_contains "$STATE_FILE" "hermes" || return 1
}

# --- Orden de arranque con Tailscale (W4) -------------------------------------------------

test_hermes_docker_dropin_installed_with_tailscale_and_idempotent() {
  _hm_setup
  _hm_tailscale_up
  export STUB_TAILSCALED_UNIT=1
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  local f="$HLI2_DOCKER_DROPIN_DIR/hli2-tailscale.conf"
  [[ -f "$f" ]] || { fail "no se instaló el drop-in"; return 1; }
  assert_file_contains "$f" "After=tailscaled.service network-online.target" || return 1
  assert_file_contains "$f" "Wants=tailscaled.service network-online.target" || return 1
  assert_file_contains "$f" "tailscale ip -4" "espera a la IP de Tailscale" || return 1
  assert_file_contains "$f" "ExecStartPre=-" "la espera nunca hace fallar a Docker" || return 1
  # Segunda corrida: contenido idéntico, no se reescribe.
  : > "$STUB_CALL_LOG"
  printf 'no\nno\nno\n' > "$DIALOG_YESNO_QUEUE"
  : > "$DIALOG_PASSWORDBOX_QUEUE"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  if grep -P "^sudo\t(install|tee)\t" "$STUB_CALL_LOG" | grep -qF "hli2-tailscale.conf"; then fail "reescribió el drop-in sin cambios"; return 1; fi
}

test_hermes_no_docker_dropin_without_tailscale() {
  _hm_setup
  export STUB_TAILSCALED_UNIT=1          # el servicio existe pero no hay IP: no se agrega
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  [[ ! -e "$HLI2_DOCKER_DROPIN_DIR/hli2-tailscale.conf" ]] || { fail "drop-in sin Tailscale"; return 1; }
  # IP de Tailscale presente pero sin servicio tailscaled: tampoco.
  rm -f "$SECRETS_DIR/hermes.env" 2>/dev/null || { chmod u+rwx "$SECRETS_DIR"; rm -f "$SECRETS_DIR/hermes.env"; chmod 000 "$SECRETS_DIR"; }
  rm -f "$APPDATA_ROOT/hermes/config.yaml"
  unset STUB_TAILSCALED_UNIT
  _hm_tailscale_up
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  [[ ! -e "$HLI2_DOCKER_DROPIN_DIR/hli2-tailscale.conf" ]] || { fail "drop-in sin tailscaled"; return 1; }
}

# --- Aislamiento de salida (iptables) ----------------------------------------------------

test_hermes_egress_unit_and_script_installed_before_deploy() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  local script="$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" unit="$HLI2_SYSTEMD_DIR/hli2-hermes-egress.service"
  [[ -x "$script" && -f "$unit" ]] || { fail "faltan el script o la unidad de aislamiento"; return 1; }
  assert_file_contains "$unit" "After=docker.service" || return 1
  assert_file_contains "$unit" "Type=oneshot" || return 1
  assert_file_contains "$unit" "RemainAfterExit=yes" || return 1
  assert_file_contains "$unit" "WantedBy=multi-user.target" || return 1
  assert_file_contains "$unit" "ExecStart=${script} apply" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'systemctl\tenable\thli2-hermes-egress.service' "habilitada para el arranque" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'sudo\t'"$script"$'\tapply' "aplicada de inmediato" || return 1
  # Las reglas se aplican ANTES del despliegue del contenedor.
  local l_apply l_deploy
  l_apply="$(grep -nF $'sudo\t'"$script"$'\tapply' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  l_deploy="$(grep -n 'compose.deploy' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  [[ -n "$l_apply" && -n "$l_deploy" && "$l_apply" -lt "$l_deploy" ]] || { fail "las reglas deben aplicarse antes del deploy"; return 1; }
}

test_hermes_egress_script_rules() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  local script="$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" ipt
  : > "$STUB_CALL_LOG"
  bash "$script" apply || return 1
  ipt="$(grep -F $'iptables\t' "$STUB_CALL_LOG")"
  # Cadenas y saltos: FORWARD (DOCKER-USER) e INPUT, solo desde la subred.
  assert_contains "$ipt" $'-I\tDOCKER-USER\t1\t-s\t'"${_HM_SUBNET}"$'\t-j\tHLI2-HERMES-FWD' || return 1
  assert_contains "$ipt" $'-I\tINPUT\t1\t-s\t'"${_HM_SUBNET}"$'\t-j\tHLI2-HERMES-IN' || return 1
  # ESTABLISHED,RELATED primero (las respuestas a 8642/9119 siguen funcionando).
  assert_contains "$ipt" $'-A\tHLI2-HERMES-FWD\t-m\tconntrack\t--ctstate\tESTABLISHED,RELATED\t-j\tACCEPT' || return 1
  assert_contains "$ipt" $'-A\tHLI2-HERMES-IN\t-m\tconntrack\t--ctstate\tESTABLISHED,RELATED\t-j\tACCEPT' || return 1
  # DROP hacia todas las redes privadas, CGNAT de Tailscale y link-local.
  local r
  for r in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
    assert_contains "$ipt" $'-A\tHLI2-HERMES-FWD\t-d\t'"$r"$'\t-j\tDROP' "DROP hacia $r" || return 1
  done
  # Internet: la cadena FWD termina en RETURN; INPUT termina en DROP.
  assert_contains "$ipt" $'-A\tHLI2-HERMES-FWD\t-j\tRETURN' || return 1
  assert_contains "$ipt" $'-A\tHLI2-HERMES-IN\t-j\tDROP' || return 1
  # Hook para destinos locales futuros (v2.6c), antes de los DROP.
  assert_contains "$ipt" $'-A\tHLI2-HERMES-FWD\t-j\tHLI2-HERMES-ALLOW' || return 1
  # Sin AdGuard: DNS públicos, así que no hay reglas especiales de DNS hacia el host... salvo las de los propios resolvers.
  assert_contains "$ipt" $'-d\t1.1.1.1\t-p\tudp\t--dport\t53\t-j\tACCEPT' || return 1
}

test_hermes_egress_allows_dns_to_lan_ip_when_adguard_installed() {
  _hm_setup
  echo "adguard" >> "$STATE_FILE"
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  : > "$STUB_CALL_LOG"
  bash "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" apply || return 1
  local ipt; ipt="$(grep -F $'iptables\t' "$STUB_CALL_LOG")"
  assert_contains "$ipt" $'-A\tHLI2-HERMES-IN\t-d\t'"${_HM_LAN}"$'\t-p\tudp\t--dport\t53\t-j\tACCEPT' || return 1
  assert_contains "$ipt" $'-A\tHLI2-HERMES-IN\t-d\t'"${_HM_LAN}"$'\t-p\ttcp\t--dport\t53\t-j\tACCEPT' || return 1
  # El compose apunta el DNS del contenedor a la IP de la LAN.
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "- ${_HM_LAN}" || return 1
}

test_hermes_egress_script_is_idempotent() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  : > "$STUB_CALL_LOG"
  STUB_IPTABLES_HAVE=1 bash "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" apply || return 1
  # Con los saltos ya presentes ('-C' tiene éxito) no se vuelven a insertar.
  if grep -F $'iptables\t' "$STUB_CALL_LOG" | grep -qF $'\t-I\t'; then fail "insertó saltos duplicados"; return 1; fi
  # Pero las cadenas sí se reconstruyen (vaciar y rearmar).
  assert_file_contains "$STUB_CALL_LOG" $'-F\tHLI2-HERMES-FWD' || return 1
  # Quitar: borra los saltos y las cadenas.
  : > "$STUB_CALL_LOG"
  bash "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" remove || return 1
  assert_file_contains "$STUB_CALL_LOG" $'-X\tHLI2-HERMES-FWD' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'-X\tHLI2-HERMES-IN' || return 1
}

test_hermes_deploy_aborts_if_egress_rules_cannot_be_applied() {
  _hm_setup
  _hm_first_run_queues
  export STUB_IPTABLES_MISSING=1
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió abortar sin iptables"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "No se encontró 'iptables'" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "compose.create" || return 1
  assert_file_not_contains "$STATE_FILE" "hermes" || return 1
}

test_hermes_compose_uses_own_network_dns_and_no_wide_binds() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "subnet: ${_HM_SUBNET}" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "hermes-net" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "- 1.1.1.1" "DNS público sin AdGuard" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "no-new-privileges:true" || return 1
  # Subred configurable; una que choca con la LAN se rechaza.
  rm -f "$SECRETS_DIR/hermes.env" 2>/dev/null || { chmod u+rwx "$SECRETS_DIR"; rm -f "$SECRETS_DIR/hermes.env"; chmod 000 "$SECRETS_DIR"; }
  rm -f "$APPDATA_ROOT/hermes/config.yaml"
  : > "$STUB_HTTP_BODIES_LOG"
  export HLI2_HERMES_SUBNET="192.168.99.0/24"
  _hm_first_run_queues
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "aceptó una subred igual a la LAN"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "HLI2_HERMES_SUBNET" || return 1
}
