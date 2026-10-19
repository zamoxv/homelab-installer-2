#!/usr/bin/env bash
# Test end-to-end de modules/hermes.sh (todo lo privilegiado/de red
# stubbeado). Comprueba: los secretos nunca viajan por argv, logs ni compose
# versionado; config.yaml se siembra solo si falta (aprobación manual,
# data_collection deny, todas las tareas auxiliares en 'auto'); los puertos se
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
  export HLI2_SYSCTL_DIR="$HLI2_TEST_SCRATCH/sysctl"
  export STUB_TEXTBOX_LOG="$HLI2_TEST_SCRATCH/textbox.log"
  : > "$STUB_TEXTBOX_LOG"
  # Zonas horarias: base de zonas de prueba y servidor en America/Santiago.
  export HLI2_ZONEINFO_DIR="$HLI2_TEST_SCRATCH/zoneinfo"
  mkdir -p "$HLI2_ZONEINFO_DIR/America" "$HLI2_ZONEINFO_DIR/Europe" "$HLI2_ZONEINFO_DIR/Etc"
  : > "$HLI2_ZONEINFO_DIR/America/Santiago"; : > "$HLI2_ZONEINFO_DIR/America/Bogota"
  : > "$HLI2_ZONEINFO_DIR/Europe/Madrid"; : > "$HLI2_ZONEINFO_DIR/UTC"; : > "$HLI2_ZONEINFO_DIR/Etc/UTC"
  export STUB_TIMEZONE="America/Santiago"
  export HLI2_TZ_FILE="$HLI2_TEST_SCRATCH/etc-timezone"
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

# Primera ejecución: clave de OpenRouter, el modelo principal, y "sí" a "guardé las
# credenciales".
_hm_first_run_queues() {
  echo "$_HM_OR_KEY" > "$DIALOG_PASSWORDBOX_QUEUE"
  echo "deepseek/deepseek-v4.1-flash" > "$DIALOG_INPUTBOX_QUEUE"
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
  # Ninguna línea puede superar el ancho visible del textbox (76 - bordes):
  # dialog no la parte, la corta, y el usuario copia una clave incompleta.
  local line
  while IFS= read -r line; do
    if (( ${#line} > 70 )); then fail "línea de credenciales demasiado larga (${#line}): se cortaría en el textbox"; return 1; fi
  done <<< "$shown"

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
  assert_file_not_contains "$cfg" "sk-or-" "sin secretos en config.yaml" || return 1
  local body; body="$(< "$cfg")"
  assert_contains "$body" $'  website_blocklist:\n    enabled: true' || return 1
  # Cada tarea auxiliar en 'auto' con modelo vacío: sigue al modelo del chat.
  for t in "${_HM_TASKS[@]}"; do
    assert_contains "$body" $'\n  '"${t}"$':\n    provider: auto\n    model: ""\n' "tarea auxiliar $t" || return 1
  done
  assert_eq "19" "${#_HM_TASKS[@]}" "las 19 tareas de v0.22.2" || return 1
  assert_eq "${#_HM_TASKS[@]}" "$(grep -c 'provider: auto' "$cfg")" "todas las tareas en auto" || return 1
  # Solo el principal y el respaldo van a OpenRouter; ninguna tarea fija base_url/api_key.
  assert_eq "2" "$(grep -c 'provider: openrouter' "$cfg")" "principal + respaldo" || return 1
  assert_file_not_contains "$cfg" "base_url" || return 1
  assert_file_not_contains "$cfg" "api_key" || return 1
  assert_file_not_contains "$cfg" "reasoning_effort" || return 1
  # Tiempos amplios para modelos locales (compresión y títulos).
  assert_contains "$body" $'  compression:\n    provider: auto\n    model: ""\n    timeout: 1800\n    no_progress_timeout: 900\n' || return 1
  assert_contains "$body" $'  title_generation:\n    provider: auto\n    model: ""\n    timeout: 120\n' || return 1
  # Zona horaria sembrada.
  assert_contains "$body" $'\ntimezone: America/Santiago\n' || return 1
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

test_hermes_rerun_can_rotate_api_key_and_change_main_model() {
  _hm_setup
  _hm_seed_previous 0
  mkdir -p "$APPDATA_ROOT/hermes"
  printf '# mio\nmodel:\n  default: x/y\n' > "$APPDATA_ROOT/hermes/config.yaml"
  # rotar API: sí; reemplazar OpenRouter: no; cambiar modelo: sí; guardé creds: sí
  printf 'yes\nno\nyes\nyes\n' > "$DIALOG_YESNO_QUEUE"
  echo "foo/bar-model" > "$DIALOG_INPUTBOX_QUEUE"
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
  # Ya no hay modelo auxiliar aparte: ninguna tarea se fija a un modelo.
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.vision.model\tfoo' || return 1
  assert_not_contains "$(_hm_dialog_text)" "Hermes — modelo auxiliar" "sin cuadro de modelo auxiliar" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'docker\trestart\thermes' || return 1
}

test_hermes_ports_only_on_lan_and_tailscale_ips() {
  _hm_setup
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$_HM_SUBNET" "1.1.1.1,9.9.9.9" America/Santiago "$_HM_LAN" "$_HM_TS" ) )" || return 1
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
    if ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$_HM_SUBNET" "1.1.1.1" America/Santiago "$bad" ) >/dev/null 2>&1; then
      fail "aceptó la IP inválida [$bad]"; return 1
    fi
  done
  if ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$_HM_SUBNET" "1.1.1.1" America/Santiago ) >/dev/null 2>&1; then
    fail "aceptó cero IPs"; return 1
  fi
  for bad in "8.8.8.0/24" "10.1.2.0/16" "10.1.2.3/24" "abc"; do
    if ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$bad" "1.1.1.1" America/Santiago "$_HM_LAN" ) >/dev/null 2>&1; then
      fail "aceptó la subred inválida [$bad]"; return 1
    fi
  done
  if ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$_HM_SUBNET" "no-ip" America/Santiago "$_HM_LAN" ) >/dev/null 2>&1; then
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
  assert_contains "$code" "pids: 512" || return 1
  if [[ "$code" == *"pids_limit"* ]]; then fail "pids_limit choca con deploy.resources.limits en Compose v2"; return 1; fi
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
  echo "modelo con espacios" > "$DIALOG_INPUTBOX_QUEUE"
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
  echo "deepseek/deepseek-v4.1-flash" > "$DIALOG_INPUTBOX_QUEUE"
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
  echo "deepseek/deepseek-v4.1-flash" > "$DIALOG_INPUTBOX_QUEUE"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$APPDATA_ROOT/hermes/config.yaml" "mode: manual" "reescrito" || return 1
}

test_hermes_invalid_config_is_backed_up_and_reseeded_atomically() {
  _hm_setup
  _hm_seed_previous 0
  mkdir -p "$APPDATA_ROOT/hermes"
  printf 'basura: sin la clave principal\n' > "$APPDATA_ROOT/hermes/config.yaml"
  : > "$DIALOG_YESNO_QUEUE"
  echo "deepseek/deepseek-v4.1-flash" > "$DIALOG_INPUTBOX_QUEUE"
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
  echo "deepseek/deepseek-v4.1-flash" > "$DIALOG_INPUTBOX_QUEUE"
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
  echo "deepseek/deepseek-v4.1-flash" > "$DIALOG_INPUTBOX_QUEUE"
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
  echo "foo/bar-model" > "$DIALOG_INPUTBOX_QUEUE"
  export STUB_HERMES_HEALTH_FAIL_AFTER_RESTART=1
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió fallar"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "no volvió a responder a tiempo" || return 1
  assert_file_not_contains "$STATE_FILE" "hermes" || return 1
}

# --- Orden de arranque con Tailscale (W4) -------------------------------------------------

# --- Aislamiento de salida (iptables) ----------------------------------------------------

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

# Ejecuta el script de aislamiento instalado contra el 'iptables' falso.
_hm_run_egress() {
  local action="$1"
  HLI2_IPTABLES="$STUBS_DIR/iptables" bash "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" "$action"
}

# Líneas de iptables (sin "-w") registradas, una por llamada, en orden.
_hm_ipt_calls() {
  grep -F $'iptables\t' "$STUB_CALL_LOG" | sed 's/^iptables\t-w\t//; s/^iptables\t//' || true
}

# --- Arranque con Tailscale: sin esperas (W5) ---------------------------------------------

test_hermes_tailscale_boot_support_has_no_waits_and_sets_nonlocal_bind() {
  _hm_setup
  _hm_tailscale_up
  export STUB_TAILSCALED_UNIT=1
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  local f="$HLI2_DOCKER_DROPIN_DIR/hli2-tailscale.conf" sc="$HLI2_TEST_SCRATCH/sysctl/90-hli2-hermes.conf"
  [[ -f "$f" ]] || { fail "no se instaló el drop-in"; return 1; }
  assert_file_contains "$f" "After=tailscaled.service" || return 1
  local c; c="$(grep -v '^[[:space:]]*#' "$f")"
  assert_not_contains "$c" "Wants=" "sin Wants" || return 1
  assert_not_contains "$c" "network-online" "sin network-online" || return 1
  assert_not_contains "$c" "ExecStartPre" "sin espera previa" || return 1
  assert_not_contains "$c" "sleep" || return 1
  [[ -f "$sc" ]] || { fail "no se instaló el sysctl"; return 1; }
  assert_file_contains "$sc" "net.ipv4.ip_nonlocal_bind = 1" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'sysctl\t-w\tnet.ipv4.ip_nonlocal_bind=1' "aplicado en vivo" || return 1
  # Segunda corrida: contenido idéntico, no se reescribe ni se vuelve a aplicar.
  : > "$STUB_CALL_LOG"
  printf 'no\nno\nno\n' > "$DIALOG_YESNO_QUEUE"
  : > "$DIALOG_PASSWORDBOX_QUEUE"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  if grep -P "^sudo\t(install|tee)\t" "$STUB_CALL_LOG" | grep -qE "hli2-tailscale.conf|90-hli2-hermes.conf"; then fail "reescribió archivos sin cambios"; return 1; fi
  if grep -qF $'sysctl\t-w' "$STUB_CALL_LOG"; then fail "volvió a aplicar el sysctl"; return 1; fi
}

test_hermes_no_tailscale_boot_support_without_tailscale_ip() {
  _hm_setup
  export STUB_TAILSCALED_UNIT=1
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  [[ ! -e "$HLI2_DOCKER_DROPIN_DIR/hli2-tailscale.conf" ]] || { fail "drop-in sin IP de Tailscale"; return 1; }
  [[ ! -e "$HLI2_TEST_SCRATCH/sysctl/90-hli2-hermes.conf" ]] || { fail "sysctl sin IP de Tailscale"; return 1; }
  # IP de Tailscale presente pero sin servicio tailscaled: sin drop-in, con sysctl.
  rm -f "$SECRETS_DIR/hermes.env" 2>/dev/null || { chmod u+rwx "$SECRETS_DIR"; rm -f "$SECRETS_DIR/hermes.env"; chmod 000 "$SECRETS_DIR"; }
  rm -f "$APPDATA_ROOT/hermes/config.yaml"
  unset STUB_TAILSCALED_UNIT
  _hm_tailscale_up
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  [[ ! -e "$HLI2_DOCKER_DROPIN_DIR/hli2-tailscale.conf" ]] || { fail "drop-in sin tailscaled"; return 1; }
}

# --- Aislamiento de salida (iptables) ----------------------------------------------------

test_hermes_egress_unit_dropin_and_start_before_deploy() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  local script="$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" unit="$HLI2_SYSTEMD_DIR/hli2-hermes-egress.service"
  local dropin="$HLI2_DOCKER_DROPIN_DIR/hli2-hermes-egress.conf"
  [[ -x "$script" && -f "$unit" && -f "$dropin" ]] || { fail "faltan el script, la unidad o el drop-in"; return 1; }
  local u; u="$(< "$unit")"
  assert_contains "$u" "Before=docker.service" "antes de Docker" || return 1
  assert_not_contains "$u" "After=docker.service" || return 1
  assert_not_contains "$u" "PartOf=" "sin PartOf" || return 1
  assert_contains "$u" "Type=oneshot" || return 1
  assert_contains "$u" "RemainAfterExit=yes" || return 1
  assert_contains "$u" "WantedBy=multi-user.target docker.service" "Docker la arrastra al arrancar" || return 1
  assert_contains "$u" "ExecStart=${script} apply" || return 1
  # Reaplicación tras 'systemctl restart docker': rápida, sin esperas, tolerante a fallos.
  assert_file_contains "$dropin" "ExecStartPost=-${script} apply" || return 1
  assert_file_not_contains "$dropin" "sleep" || return 1
  # Habilitada y arrancada, y las reglas aplicadas ANTES del despliegue.
  assert_file_contains "$STUB_CALL_LOG" $'systemctl\tenable\t--now\thli2-hermes-egress.service' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'sudo\t'"$script"$'\tapply' "aplicada de inmediato" || return 1
  local l_apply l_deploy
  l_apply="$(grep -nF $'sudo\t'"$script"$'\tapply' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  l_deploy="$(grep -n 'compose.deploy' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  [[ -n "$l_apply" && -n "$l_deploy" && "$l_apply" -lt "$l_deploy" ]] || { fail "las reglas deben aplicarse antes del deploy"; return 1; }
}

test_hermes_egress_script_rule_contents() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  : > "$STUB_CALL_LOG"
  _hm_run_egress apply || return 1
  local ipt; ipt="$(_hm_ipt_calls)"
  assert_contains "$ipt" $'-I\tDOCKER-USER\t1\t-s\t'"${_HM_SUBNET}"$'\t-j\tHLI2-HERMES-FWD-new' || return 1
  assert_contains "$ipt" $'-I\tINPUT\t1\t-s\t'"${_HM_SUBNET}"$'\t-j\tHLI2-HERMES-IN-new' || return 1
  assert_contains "$ipt" $'-E\tHLI2-HERMES-FWD-new\tHLI2-HERMES-FWD' || return 1
  assert_contains "$ipt" $'-E\tHLI2-HERMES-IN-new\tHLI2-HERMES-IN' || return 1
  assert_contains "$ipt" $'-A\tHLI2-HERMES-FWD-new\t-m\tconntrack\t--ctstate\tESTABLISHED,RELATED\t-j\tACCEPT' || return 1
  assert_contains "$ipt" $'-A\tHLI2-HERMES-IN-new\t-m\tconntrack\t--ctstate\tESTABLISHED,RELATED\t-j\tACCEPT' || return 1
  local r
  for r in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4; do
    assert_contains "$ipt" $'-A\tHLI2-HERMES-FWD-new\t-d\t'"$r"$'\t-j\tDROP' "DROP hacia $r" || return 1
  done
  assert_not_contains "$ipt" $'-d\t8.8.8.8' "Internet permitida" || return 1
  assert_contains "$ipt" $'-A\tHLI2-HERMES-FWD-new\t-j\tRETURN' || return 1
  assert_contains "$ipt" $'-A\tHLI2-HERMES-IN-new\t-j\tDROP' || return 1
  assert_contains "$ipt" $'-A\tHLI2-HERMES-FWD-new\t-j\tHLI2-HERMES-ALLOW' || return 1
  assert_contains "$ipt" $'-d\t1.1.1.1\t-p\tudp\t--dport\t53\t-j\tACCEPT' || return 1
  # Backend registrado y ruta absoluta por defecto en el script.
  assert_file_contains "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" '${HLI2_IPTABLES:-/usr/sbin/iptables}' || return 1
  assert_file_contains "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" 'backend $("$IPT" -V)' || return 1
  assert_contains "$ipt" "-V" "se consultó el backend" || return 1
}

test_hermes_egress_allows_dns_to_lan_ip_when_adguard_installed() {
  _hm_setup
  echo "adguard" >> "$STATE_FILE"
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  : > "$STUB_CALL_LOG"
  _hm_run_egress apply || return 1
  local ipt; ipt="$(_hm_ipt_calls)"
  assert_contains "$ipt" $'-A\tHLI2-HERMES-IN-new\t-d\t'"${_HM_LAN}"$'\t-p\tudp\t--dport\t53\t-j\tACCEPT' || return 1
  assert_contains "$ipt" $'-A\tHLI2-HERMES-IN-new\t-d\t'"${_HM_LAN}"$'\t-p\ttcp\t--dport\t53\t-j\tACCEPT' || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "- ${_HM_LAN}" || return 1
}

# Orden de operaciones de la aplicación atómica: la cadena nueva se arma por
# completo y recibe su salto ANTES de que se toque la anterior.
test_hermes_egress_apply_is_atomic_in_order() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  : > "$STUB_CALL_LOG"
  _hm_run_egress apply || return 1
  local calls n_new n_fill_last n_jump_new n_flush_old n_del_old n_rename
  calls="$(_hm_ipt_calls | grep -nF 'HLI2-HERMES-FWD' )"
  n_new="$(_hm_ipt_calls | grep -nF -- $'-N\tHLI2-HERMES-FWD-new' | head -1 | cut -d: -f1)"
  n_fill_last="$(_hm_ipt_calls | grep -nF -- $'-A\tHLI2-HERMES-FWD-new' | tail -1 | cut -d: -f1)"
  n_jump_new="$(_hm_ipt_calls | grep -nF -- $'-I\tDOCKER-USER\t1\t-s\t'"${_HM_SUBNET}"$'\t-j\tHLI2-HERMES-FWD-new' | head -1 | cut -d: -f1)"
  n_flush_old="$(_hm_ipt_calls | grep -nxF -- $'-F\tHLI2-HERMES-FWD' | head -1 | cut -d: -f1)"
  n_del_old="$(_hm_ipt_calls | grep -nxF -- $'-X\tHLI2-HERMES-FWD' | head -1 | cut -d: -f1)"
  n_rename="$(_hm_ipt_calls | grep -nF -- $'-E\tHLI2-HERMES-FWD-new\tHLI2-HERMES-FWD' | head -1 | cut -d: -f1)"
  local v
  for v in n_new n_fill_last n_jump_new n_flush_old n_del_old n_rename; do
    [[ -n "${!v}" ]] || { fail "falta la operación $v: $calls"; return 1; }
  done
  (( n_new < n_fill_last && n_fill_last < n_jump_new )) || { fail "el salto a la cadena nueva debe ir DESPUÉS de armarla por completo"; return 1; }
  (( n_jump_new < n_flush_old && n_flush_old < n_del_old && n_del_old < n_rename )) || { fail "la cadena anterior solo se toca después de enganchar la nueva, y el renombrado va al final"; return 1; }
}

test_hermes_egress_removes_stale_jumps_of_any_subnet() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  export STUB_IPTABLES_S_INPUT="-P INPUT ACCEPT
-A INPUT -s 10.99.1.0/24 -j HLI2-HERMES-IN
-A INPUT -s ${_HM_SUBNET} -j HLI2-HERMES-IN
-A INPUT -s 10.99.2.0/24 -j HLI2-HERMES-IN-new
-A INPUT -p tcp --dport 22 -j ACCEPT"
  export STUB_IPTABLES_S_DOCKER_USER="-N DOCKER-USER
-A DOCKER-USER -s 10.99.1.0/24 -j HLI2-HERMES-FWD
-A DOCKER-USER -j RETURN"
  : > "$STUB_CALL_LOG"
  _hm_run_egress apply || return 1
  local ipt; ipt="$(_hm_ipt_calls)"
  assert_contains "$ipt" $'-D\tINPUT\t-s\t10.99.1.0/24\t-j\tHLI2-HERMES-IN' "salto viejo de otra subred" || return 1
  assert_contains "$ipt" $'-D\tINPUT\t-s\t'"${_HM_SUBNET}"$'\t-j\tHLI2-HERMES-IN' || return 1
  assert_contains "$ipt" $'-D\tINPUT\t-s\t10.99.2.0/24\t-j\tHLI2-HERMES-IN-new' "resto de una aplicación interrumpida" || return 1
  assert_contains "$ipt" $'-D\tDOCKER-USER\t-s\t10.99.1.0/24\t-j\tHLI2-HERMES-FWD' || return 1
  assert_not_contains "$ipt" $'-D\tINPUT\t-p\ttcp' "no toca reglas ajenas" || return 1
  assert_not_contains "$ipt" $'-D\tDOCKER-USER\t-j\tRETURN' || return 1
  # 'remove' hace lo mismo y borra las cadenas, incluido el hook ALLOW.
  : > "$STUB_CALL_LOG"
  _hm_run_egress remove || return 1
  ipt="$(_hm_ipt_calls)"
  assert_contains "$ipt" $'-D\tINPUT\t-s\t10.99.1.0/24\t-j\tHLI2-HERMES-IN' || return 1
  assert_contains "$ipt" $'-D\tDOCKER-USER\t-s\t10.99.1.0/24\t-j\tHLI2-HERMES-FWD' || return 1
  local c
  for c in HLI2-HERMES-FWD HLI2-HERMES-IN HLI2-HERMES-ALLOW HLI2-HERMES-FWD-new HLI2-HERMES-IN-new; do
    assert_contains "$ipt" $'-F\t'"$c" || return 1
    assert_contains "$ipt" $'-X\t'"$c" || return 1
  done
  # ALLOW se borra después de las cadenas que la referencian.
  local n_allow n_fwd
  n_allow="$(_hm_ipt_calls | grep -nxF -- $'-X\tHLI2-HERMES-ALLOW' | head -1 | cut -d: -f1)"
  n_fwd="$(_hm_ipt_calls | grep -nxF -- $'-X\tHLI2-HERMES-FWD' | head -1 | cut -d: -f1)"
  (( n_fwd < n_allow )) || { fail "ALLOW debe borrarse después de FWD"; return 1; }
}

# --- Validación de la subred (W1) ---------------------------------------------------------

test_hermes_invalid_subnets_install_nothing() {
  _hm_setup
  local bad
  for bad in "127.0.0.0/24" "100.64.1.0/24" "8.8.8.0/24" "169.254.1.0/24" "10.1.2.0/16" "10.300.1.0/24" "abc" "172.32.0.0/24" "10.1.2.3/24"; do
    : > "$STUB_CALL_LOG"; : > "$STUB_HTTP_BODIES_LOG"
    export HLI2_HERMES_SUBNET="$bad"
    : > "$DIALOG_PASSWORDBOX_QUEUE"
    if bash "$REPO_ROOT/modules/hermes.sh"; then fail "aceptó la subred [$bad]"; return 1; fi
    assert_contains "$(_hm_dialog_text)" "HLI2_HERMES_SUBNET" "mensaje para [$bad]" || return 1
    # Nada instalado ni preguntado: ni script, ni unidad, ni secretos, ni compose, ni iptables.
    [[ ! -e "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" && ! -e "$HLI2_SYSTEMD_DIR/hli2-hermes-egress.service" ]] || { fail "instaló el aislamiento con [$bad]"; return 1; }
    ( source "$REPO_ROOT/lib/core.sh"; secret_file_exists hermes ) && { fail "guardó secretos con [$bad]"; return 1; }
    assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "compose" || return 1
    if grep -qF $'iptables\t' "$STUB_CALL_LOG"; then fail "tocó iptables con [$bad]"; return 1; fi
    if grep -qF -- '--passwordbox' "$STUB_CALL_LOG"; then fail "preguntó algo antes de validar [$bad]"; return 1; fi
  done
}

test_hermes_subnet_overlapping_a_route_or_docker_network_is_rejected() {
  _hm_setup
  export HLI2_HERMES_SUBNET="192.168.5.0/24"
  export STUB_ROUTES="default via 192.168.99.1 dev eth0
192.168.0.0/16 dev wlan0 proto kernel scope link src 192.168.1.4"
  : > "$DIALOG_PASSWORDBOX_QUEUE"
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "aceptó una subred dentro de una ruta /16"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "ruta 192.168.0.0/16" || return 1
  [[ ! -e "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" ]] || { fail "instaló algo"; return 1; }
  # Ruta más pequeña que contiene a la subred, y ruta de host dentro de ella.
  unset STUB_ROUTES
  export HLI2_HERMES_SUBNET="10.213.144.0/24"
  export STUB_ROUTES="10.213.0.0/16 dev eth1"
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "aceptó una subred dentro de una ruta /16"; return 1; fi
  export STUB_ROUTES="10.213.144.9 dev eth1"
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "aceptó una subred con una ruta de host dentro"; return 1; fi
  # Redes de Docker existentes.
  unset STUB_ROUTES
  export STUB_DOCKER_NETWORKS="bridge 172.17.0.0/16
dokploy-network 10.213.144.0/24"
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "aceptó una subred igual a una red de Docker"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "red de Docker dokploy-network" || return 1
}

test_hermes_own_existing_network_and_route_do_not_count_as_conflict() {
  _hm_setup
  _hm_first_run_queues
  export STUB_DOCKER_NETWORKS="hermes_hermes-net 10.213.144.0/24"
  export STUB_ROUTES="10.213.144.0/24 dev br-abc proto kernel scope link src 10.213.144.1"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
}

# --- Redes del contenedor (W7) ------------------------------------------------------------

test_hermes_warns_if_container_has_other_networks() {
  _hm_setup
  _hm_first_run_queues
  export STUB_DOCKER_INSPECT_NETWORKS="hermes_hermes-net dokploy-network"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_contains "$(_hm_dialog_text)" "ATENCIÓN: el contenedor 'hermes' está conectado a estas redes: hermes_hermes-net dokploy-network" || return 1
}

test_hermes_no_warning_when_only_own_network() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_not_contains "$(_hm_dialog_text)" "ATENCIÓN" || return 1
}

# AdGuard con "Allowed clients" que no incluye la red de Hermes: el módulo
# avisa (sin esto Hermes no resuelve nombres; visto en el M70q).
_hm_adguard_with_clients() {
  echo "adguard" >> "$STATE_FILE"
  mkdir -p "$APPDATA_ROOT/adguard/conf"
  {
    echo "dns:"
    echo "  bind_hosts:"
    echo "    - 0.0.0.0"
    echo "  allowed_clients:"
    local c; for c in "$@"; do echo "    - $c"; done
    echo "  disallowed_clients: []"
  } > "$APPDATA_ROOT/adguard/conf/AdGuardHome.yaml"
}

test_hermes_warns_when_adguard_acl_excludes_subnet() {
  _hm_setup
  _hm_first_run_queues
  _hm_adguard_with_clients 192.168.99.0/24 100.64.0.0/10
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_contains "$(_hm_dialog_text)" "Allowed clients" "aviso de la lista de AdGuard" || return 1
  assert_contains "$(_hm_dialog_text)" "$_HM_SUBNET" || return 1
}

test_hermes_no_acl_warning_when_subnet_allowed() {
  _hm_setup
  _hm_first_run_queues
  _hm_adguard_with_clients 192.168.99.0/24 "$_HM_SUBNET"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  if _hm_dialog_text | grep -qF "Allowed clients"; then
    fail "no debe avisar si la red de Hermes ya está permitida"; return 1
  fi
}

# --- Zona horaria (HERMES_TIMEZONE) --------------------------------------------------------------

test_hermes_timezone_detected_from_host_goes_to_compose_and_config() {
  _hm_setup
  export STUB_TIMEZONE="Europe/Madrid"
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "HERMES_TIMEZONE=Europe/Madrid" "compose con la zona del servidor" || return 1
  assert_file_contains "$APPDATA_ROOT/hermes/config.yaml" "timezone: Europe/Madrid" || return 1
  if _hm_dialog_text | grep -qF "zona horaria"; then fail "preguntó la zona teniendo una detectada"; return 1; fi
  # Ningún secreto en esa variable ni en el compose versionado.
  assert_file_not_contains "$REPO_ROOT/compose/hermes/docker-compose.yml" "Europe/Madrid" || return 1
}

test_hermes_timezone_utc_host_asks_and_validates() {
  _hm_setup
  local utc
  for utc in UTC Etc/UTC ""; do
    : > "$STUB_CALL_LOG"; : > "$STUB_HTTP_BODIES_LOG"
    rm -rf "$APPDATA_ROOT/hermes"; ( source "$REPO_ROOT/lib/core.sh"; chmod u+rwx "$SECRETS_DIR" 2>/dev/null; rm -f "$SECRETS_DIR/hermes.env" ) || true
    chmod 000 "$SECRETS_DIR" 2>/dev/null || true
    export STUB_TIMEZONE="$utc"
    echo "$_HM_OR_KEY" > "$DIALOG_PASSWORDBOX_QUEUE"
    printf '%s\n%s\n' "deepseek/deepseek-v4.1-flash" "America/Bogota" > "$DIALOG_INPUTBOX_QUEUE"
    echo "yes" > "$DIALOG_YESNO_QUEUE"
    bash "$REPO_ROOT/modules/hermes.sh" || { fail "falló con el servidor en [$utc]"; return 1; }
    assert_contains "$(_hm_dialog_text)" "El servidor está en UTC" "pregunta con [$utc]" || return 1
    assert_file_contains "$STUB_HTTP_BODIES_LOG" "HERMES_TIMEZONE=America/Bogota" || return 1
    assert_file_contains "$APPDATA_ROOT/hermes/config.yaml" "timezone: America/Bogota" || return 1
    sed -i '/^hermes$/d' "$STATE_FILE"
  done
}

test_hermes_timezone_falls_back_to_etc_timezone_when_timedatectl_fails() {
  _hm_setup
  export STUB_TIMEDATECTL_FAIL=1
  echo "Europe/Madrid" > "$HLI2_TZ_FILE"
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "HERMES_TIMEZONE=Europe/Madrid" || return 1
}

test_hermes_timezone_default_proposal_is_santiago_or_the_saved_one() {
  _hm_setup
  export STUB_TIMEZONE="UTC"
  _hm_first_run_queues
  printf '%s\n%s\n' "deepseek/deepseek-v4.1-flash" "America/Santiago" > "$DIALOG_INPUTBOX_QUEUE"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  # El valor propuesto (último argumento del cuadro de entrada) es America/Santiago.
  grep -F $'dialog\t' "$STUB_CALL_LOG" | grep -F "zona horaria" | grep -qP $'\tAmerica/Santiago$' \
    || { fail "la zona propuesta por defecto debe ser America/Santiago"; return 1; }
  # Con config.yaml ya sembrado, se propone la guardada.
  : > "$STUB_CALL_LOG"
  sed -i '/^hermes$/d' "$STATE_FILE"
  sed -i 's#^timezone: .*#timezone: Europe/Madrid#' "$APPDATA_ROOT/hermes/config.yaml"
  printf '%s\n' "Europe/Madrid" > "$DIALOG_INPUTBOX_QUEUE"
  : > "$DIALOG_PASSWORDBOX_QUEUE"; : > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  grep -F $'dialog\t' "$STUB_CALL_LOG" | grep -F "zona horaria" | grep -qP $'\tEurope/Madrid$' \
    || { fail "debe proponer la zona ya guardada en config.yaml"; return 1; }
}

test_hermes_timezone_invalid_answers_are_rejected_before_installing() {
  _hm_setup
  export STUB_TIMEZONE="UTC"
  local bad
  for bad in "Mars/Olympus" "../../etc/passwd" "America/Santiago; rm -rf /" "UTC" "Etc/UTC" "America/Santiago extra" "a b"; do
    : > "$STUB_CALL_LOG"; : > "$STUB_HTTP_BODIES_LOG"
    echo "$_HM_OR_KEY" > "$DIALOG_PASSWORDBOX_QUEUE"
    printf '%s\n%s\n' "deepseek/deepseek-v4.1-flash" "$bad" > "$DIALOG_INPUTBOX_QUEUE"
    if bash "$REPO_ROOT/modules/hermes.sh"; then fail "aceptó la zona [$bad]"; return 1; fi
    assert_contains "$(_hm_dialog_text)" "no es una zona horaria válida" "mensaje para [$bad]" || return 1
    assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "compose.create" "no se desplegó con [$bad]" || return 1
    assert_file_not_contains "$STATE_FILE" "hermes" || return 1
    [[ ! -e "$APPDATA_ROOT/hermes/config.yaml" ]] || { fail "sembró config.yaml con una zona inválida [$bad]"; return 1; }
  done
}

test_hermes_timezone_cancel_stops_cleanly() {
  _hm_setup
  export STUB_TIMEZONE="UTC"
  echo "$_HM_OR_KEY" > "$DIALOG_PASSWORDBOX_QUEUE"
  echo "deepseek/deepseek-v4.1-flash" > "$DIALOG_INPUTBOX_QUEUE"     # la zona queda sin respuesta: cancelar
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió cancelar"; return 1; fi
  assert_contains "$(_hm_dialog_text)" "no se indicó la zona horaria" || return 1
  assert_file_not_contains "$STATE_FILE" "hermes" || return 1
}

test_hermes_compose_rejects_invalid_timezone_and_renders_valid_one() {
  _hm_setup
  local out bad
  out="$( ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$_HM_SUBNET" "1.1.1.1" Europe/Madrid "$_HM_LAN" ) )" || return 1
  assert_contains "$out" "- HERMES_TIMEZONE=Europe/Madrid" || return 1
  assert_not_contains "$out" "__TIMEZONE__" "sin marcadores sin sustituir" || return 1
  for bad in "" "UTC; x" "../etc" "a b" 'x"y' "A/B/C/D" "-"; do
    if ( source "$REPO_ROOT/lib/core.sh"; compose_render_hermes "$_HM_SUBNET" "1.1.1.1" "$bad" "$_HM_LAN" ) >/dev/null 2>&1; then
      fail "aceptó la zona inválida [$bad]"; return 1
    fi
  done
}

# --- Tareas auxiliares: siguen al modelo del chat (auto) -----------------------------------------

# Líneas "tarea\top\tclave\tvalor" que planificaría la migración para el YAML $1.
_hm_aux_plan() {
  bash -c 'source "$1"; _hermes_aux_plan "$2"; printf "%s\n" "${H_AUX_OPS[@]}"; echo "PLANNED:${H_AUX_PLANNED[*]}"; echo "CUSTOM:${H_AUX_CUSTOM[*]}"' \
    "$REPO_ROOT/modules/_" "$REPO_ROOT/modules/hermes.sh" "$1"
}

# Bloque 'auxiliary:' de la versión 2.6a: provider openrouter + modelo $1 en las tareas $2...
_hm_aux_block_or() {
  local model="$1" t; shift
  for t in "$@"; do printf '  %s:\n    provider: openrouter\n    model: %s\n' "$t" "$model"; done
}

# Bloque de la versión 2.6c: gemma4:e2b local con todo lo que escribía.
_hm_aux_block_local() {
  local t
  for t in "$@"; do
    printf '  %s:\n    provider: custom\n    model: gemma4:e2b\n    base_url: http://10.213.144.250:11434/v1\n    api_key: no-key-required\n' "$t"
    [[ "$t" == review ]] || printf '    timeout: 3600\n'
    case "$t" in review|memory_query_rewrite) ;; *) printf '    reasoning_effort: none\n' ;; esac
    [[ "$t" != compression ]] || printf '    no_progress_timeout: 900\n'
  done
}

test_hermes_aux_plan_converts_openrouter_pins_and_adds_local_timeouts() {
  _hm_setup
  local yaml out
  yaml="$(printf 'auxiliary:\n'; _hm_aux_block_or qwen/qwen3.7-flash "${_HM_TASKS[@]}")"
  out="$(_hm_aux_plan "$yaml")"
  local t
  for t in "${_HM_TASKS[@]}"; do
    assert_contains "$out" "aux:${t}"$'\tset\tauxiliary.'"${t}"$'.provider\tauto' "provider auto en $t" || return 1
    assert_contains "$out" "aux:${t}"$'\tset\tauxiliary.'"${t}"$'.model\t' "model vacío en $t" || return 1
    assert_not_contains "$out" "auxiliary.${t}.base_url" || return 1
  done
  assert_contains "$out" $'auxiliary.compression.timeout\t1800' "compresión con tiempo amplio" || return 1
  assert_contains "$out" $'auxiliary.compression.no_progress_timeout\t900' || return 1
  assert_contains "$out" $'auxiliary.title_generation.timeout\t120' || return 1
  assert_not_contains "$out" "auxiliary.vision.timeout" "solo compresión y títulos llevan tiempos" || return 1
  assert_contains "$out" "CUSTOM:" || return 1
  assert_contains "$out" "PLANNED:${_HM_TASKS[*]}" || return 1
}

test_hermes_aux_plan_removes_only_local_pins_it_wrote() {
  _hm_setup
  local yaml out
  yaml="$(printf 'auxiliary:\n'; _hm_aux_block_local "${_HM_TASKS[@]}")"
  out="$(_hm_aux_plan "$yaml")"
  # Se quitan base_url, api_key, razonamiento y el timeout de 3600 (con 'unset', no con valores inventados).
  assert_contains "$out" "aux:vision"$'\tunset\tauxiliary.vision.base_url' || return 1
  assert_contains "$out" "aux:vision"$'\tunset\tauxiliary.vision.api_key' || return 1
  assert_contains "$out" "aux:vision"$'\tunset\tauxiliary.vision.reasoning_effort' || return 1
  assert_contains "$out" "aux:vision"$'\tunset\tauxiliary.vision.timeout' || return 1
  assert_contains "$out" "aux:vision"$'\tset\tauxiliary.vision.provider\tauto' || return 1
  assert_contains "$out" "aux:vision"$'\tset\tauxiliary.vision.model\t' || return 1
  # review no tenía timeout ni razonamiento.
  assert_not_contains "$out" "auxiliary.review.timeout" || return 1
  assert_not_contains "$out" "auxiliary.review.reasoning_effort" || return 1
  # Compresión: el 3600 pasa a 1800 (set, no unset); el no_progress_timeout ya es 900.
  assert_contains "$out" "aux:compression"$'\tset\tauxiliary.compression.timeout\t1800' || return 1
  assert_not_contains "$out" "auxiliary.compression.no_progress_timeout" "ya está en 900" || return 1
  assert_contains "$out" "aux:title_generation"$'\tset\tauxiliary.title_generation.timeout\t120' || return 1
  # Orden: el proveedor es lo ÚLTIMO de cada tarea (una interrupción deja la tarea reconocible).
  local last
  last="$(grep -F "aux:vision"$'\t' <<<"$out" | tail -1)"
  assert_contains "$last" $'auxiliary.vision.provider\tauto' "provider al final" || return 1
}

test_hermes_aux_plan_leaves_user_custom_pins_alone_and_reports_them() {
  _hm_setup
  local yaml out
  # 17 tareas con el modelo de la versión anterior; 'vision' con otro modelo; 'curator' hacia un servidor propio.
  yaml="$(printf 'auxiliary:\n'
    _hm_aux_block_or qwen/qwen3.7-flash $(printf '%s\n' "${_HM_TASKS[@]}" | grep -vxE 'vision|curator')
    printf '  vision:\n    provider: openrouter\n    model: google/gemini-3-flash\n'
    printf '  curator:\n    provider: custom\n    model: mi-modelo\n    base_url: http://192.168.1.50:8080/v1\n    api_key: secreto-mio\n')"
  out="$(_hm_aux_plan "$yaml")"
  assert_not_contains "$out" "auxiliary.vision." "no toca vision" || return 1
  assert_not_contains "$out" "auxiliary.curator." "no toca curator" || return 1
  assert_contains "$out" "auxiliary.mcp.provider" || return 1
  assert_contains "$out" "CUSTOM:vision (openrouter/google/gemini-3-flash)" || return 1
  assert_contains "$out" "curator (custom/mi-modelo, http://192.168.1.50:8080/v1)" || return 1
  # Un puerto distinto de 11434 o una clave real nunca cuentan como "propios del HLI".
  yaml="$(printf 'auxiliary:\n  vision:\n    provider: custom\n    model: gemma4:e2b\n    base_url: http://10.0.0.5:11434/v1\n    api_key: clave-real\n  mcp:\n    provider: custom\n    model: gemma4:e2b\n    base_url: http://10.0.0.5:8080/v1\n    api_key: no-key-required\n')"
  out="$(_hm_aux_plan "$yaml")"
  assert_eq "PLANNED:" "$(grep '^PLANNED:' <<<"$out")" "ninguna tarea del HLI" || return 1
  assert_not_contains "$out" "auxiliary.vision." || return 1
  assert_not_contains "$out" "auxiliary.mcp." || return 1
}

test_hermes_aux_plan_recognizes_the_users_aux_model_when_shared_by_most_tasks() {
  _hm_setup
  local yaml out
  yaml="$(printf 'auxiliary:\n'; _hm_aux_block_or foo/aux-model "${_HM_TASKS[@]}")"
  out="$(_hm_aux_plan "$yaml")"
  assert_contains "$out" "PLANNED:${_HM_TASKS[*]}" "el modelo elegido por el usuario en la versión anterior también era del HLI" || return 1
  # Pocas tareas con un modelo ajeno: no es del HLI.
  yaml="$(printf 'auxiliary:\n'; _hm_aux_block_or foo/aux-model vision mcp)"
  out="$(_hm_aux_plan "$yaml")"
  assert_eq "PLANNED:" "$(grep '^PLANNED:' <<<"$out")" "un modelo ajeno en pocas tareas no es del HLI" || return 1
  assert_not_contains "$out" "auxiliary.vision." || return 1
}

test_hermes_aux_plan_is_empty_for_clean_config_and_resumes_partial_states() {
  _hm_setup
  local out yaml
  out="$(_hm_aux_plan $'model:\n  default: x/y\n')"
  assert_contains "$out" "PLANNED:" || return 1
  assert_not_contains "$out" "aux:" "sin bloque auxiliary no hay nada que migrar" || return 1
  yaml="$(printf 'auxiliary:\n'; for t in "${_HM_TASKS[@]}"; do printf '  %s:\n    provider: auto\n    model: ""\n' "$t"; done)"
  out="$(_hm_aux_plan "$yaml")"
  assert_not_contains "$out" "aux:" "todo en auto: nada que hacer" || return 1
  # Interrumpida: proveedor ya en auto pero el modelo anterior sigue; o ya sin base_url pero con provider custom.
  yaml="$(printf 'auxiliary:\n  vision:\n    provider: auto\n    model: qwen/qwen3.7-flash\n  mcp:\n    provider: custom\n    model: gemma4:e2b\n  approval:\n    provider: auto\n    model: ""\n    api_key: no-key-required\n')"
  out="$(_hm_aux_plan "$yaml")"
  assert_contains "$out" "aux:vision"$'\tset\tauxiliary.vision.model\t' "completa vision" || return 1
  assert_not_contains "$out" "auxiliary.vision.provider" || return 1
  assert_contains "$out" "aux:mcp"$'\tset\tauxiliary.mcp.model\t' || return 1
  assert_contains "$out" "aux:mcp"$'\tset\tauxiliary.mcp.provider\tauto' || return 1
  assert_contains "$out" "aux:approval"$'\tunset\tauxiliary.approval.api_key' || return 1
}

test_hermes_fresh_install_has_no_aux_prompt_no_cli_calls_and_leaves_marker() {
  _hm_setup
  _hm_first_run_queues
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_not_contains "$(_hm_dialog_text)" "Hermes — modelo auxiliar" "sin cuadro de modelo auxiliar" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary' "la siembra ya deja todo en auto" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tunset' || return 1
  chmod u+rwx "$SECRETS_DIR"
  [[ -f "$SECRETS_DIR/hermes-aux-auto" ]] || { chmod 000 "$SECRETS_DIR"; fail "falta el marcador hermes-aux-auto"; return 1; }
  assert_eq "600" "$(stat -c '%a' "$SECRETS_DIR/hermes-aux-auto")" "marcador root-only" || { chmod 000 "$SECRETS_DIR"; return 1; }
  chmod 000 "$SECRETS_DIR"
  # Ni el registro previo: no había nada que guardar.
  chmod u+rwx "$SECRETS_DIR"; [[ ! -e "$SECRETS_DIR/hermes-aux-previous.conf" ]] || { chmod 000 "$SECRETS_DIR"; fail "registro previo innecesario"; return 1; }; chmod 000 "$SECRETS_DIR"
  assert_contains "$(_hm_dialog_text)" "siguen al modelo de cada chat" || return 1
}

# Instalación previa con config.yaml que trae el bloque $1 (texto YAML de 'auxiliary:').
_hm_seed_existing_with_aux() {
  _hm_seed_previous 0
  mkdir -p "$APPDATA_ROOT/hermes"
  printf 'model:\n  provider: openrouter\n  default: x/y\n%s' "$1" > "$APPDATA_ROOT/hermes/config.yaml"
  : > "$DIALOG_PASSWORDBOX_QUEUE"
  : > "$DIALOG_YESNO_QUEUE"
}

_hm_cfg_call() { grep -qP "$1" "$STUB_CALL_LOG"; }

test_hermes_rerun_migrates_openrouter_pins_to_auto_records_previous_and_restarts() {
  _hm_setup
  _hm_seed_existing_with_aux "$(printf 'auxiliary:\n'; _hm_aux_block_or qwen/qwen3.7-flash "${_HM_TASKS[@]}")"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  local t uid_gid; uid_gid="$(id -u):$(id -g)"
  for t in "${_HM_TASKS[@]}"; do
    _hm_cfg_call "exec\t-u\t${uid_gid}\thermes\t/opt/hermes/.venv/bin/hermes\tconfig\tset\tauxiliary\.${t}\.provider\tauto$" || { fail "falta provider auto en $t"; return 1; }
    _hm_cfg_call "config\tset\tauxiliary\.${t}\.model\t$" || { fail "falta model vacío en $t"; return 1; }
  done
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.compression.timeout\t1800' || return 1
  # Registro previo (root 0600, una vez), marcador, reinicio y /health.
  chmod u+rwx "$SECRETS_DIR"
  assert_file_contains "$SECRETS_DIR/hermes-aux-previous.conf" "model: qwen/qwen3.7-flash" "valores previos guardados" || { chmod 000 "$SECRETS_DIR"; return 1; }
  [[ -f "$SECRETS_DIR/hermes-aux-auto" ]] || { chmod 000 "$SECRETS_DIR"; fail "falta el marcador"; return 1; }
  chmod 000 "$SECRETS_DIR"
  local l_prev l_set
  l_prev="$(grep -nF 'hermes-aux-previous.conf.tmp.' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  l_set="$(grep -nF $'config\tset\tauxiliary.' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  [[ -n "$l_prev" && -n "$l_set" && "$l_prev" -lt "$l_set" ]] || { fail "el registro previo debe guardarse antes de tocar nada"; return 1; }
  assert_file_contains "$STUB_CALL_LOG" $'docker\trestart\thermes' || return 1
  assert_contains "$(_hm_dialog_text)" "hermes-aux-previous.conf" "el mensaje final cita el registro" || return 1
  assert_file_contains "$STATE_FILE" "hermes" || return 1
  # Con el marcador, una nueva ejecución no vuelve a tocar nada (ni pisa decisiones del usuario).
  : > "$STUB_CALL_LOG"; sed -i '/^hermes$/d' "$STATE_FILE"
  printf 'auxiliary:\n' >> "$APPDATA_ROOT/hermes/config.yaml"; _hm_aux_block_or qwen/qwen3.7-flash vision >> "$APPDATA_ROOT/hermes/config.yaml"
  : > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary' "con marcador no se revisa 'auxiliary'" || return 1
}

test_hermes_rerun_migrates_local_pins_with_unset_and_reports_custom_ones() {
  _hm_setup
  local custom_t=curator
  _hm_seed_existing_with_aux "$(printf 'auxiliary:\n'; _hm_aux_block_local $(printf '%s\n' "${_HM_TASKS[@]}" | grep -vx "$custom_t")
    printf '  curator:\n    provider: openrouter\n    model: google/gemini-3-flash\n')"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary.vision.base_url' "quita la URL local con 'config unset'" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary.vision.api_key' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary.vision.reasoning_effort' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary.vision.timeout' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.vision.provider\tauto' || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "auxiliary.curator" "no toca la tarea con valores propios" || return 1
  local texts; texts="$(_hm_dialog_text)"
  assert_contains "$texts" "valores propios que NO se tocaron" || return 1
  assert_contains "$texts" "curator (openrouter/google/gemini-3-flash)" || return 1
  assert_file_contains "$STATE_FILE" "hermes" "las tareas propias no impiden terminar" || return 1
  chmod u+rwx "$SECRETS_DIR"; [[ -f "$SECRETS_DIR/hermes-aux-auto" ]] || { chmod 000 "$SECRETS_DIR"; fail "falta el marcador"; return 1; }; chmod 000 "$SECRETS_DIR"
}

test_hermes_aux_migration_failure_is_incomplete_and_rerun_resumes() {
  _hm_setup
  _hm_seed_existing_with_aux "$(printf 'auxiliary:\n'; _hm_aux_block_or qwen/qwen3.7-flash "${_HM_TASKS[@]}")"
  # Orden de vision: provider (1ª llamada) y model (2ª).
  export STUB_HERMES_CONFIG_SET_FAIL_N="2"
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió terminar con error si la migración quedó incompleta"; return 1; fi
  unset STUB_HERMES_CONFIG_SET_FAIL_N
  local texts; texts="$(_hm_dialog_text)"
  assert_contains "$texts" "migración incompleta: 1 de 19 tareas auxiliares" || return 1
  assert_contains "$texts" "vision: openrouter/qwen/qwen3.7-flash" "dice dónde quedó la tarea" || return 1
  assert_contains "$texts" "vuelva a correr el módulo" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'docker\trestart\thermes' "Hermes se reinicia igual (proceso = disco)" || return 1
  assert_file_not_contains "$STATE_FILE" "hermes" "no se marca como hecho" || return 1
  chmod u+rwx "$SECRETS_DIR"; [[ ! -e "$SECRETS_DIR/hermes-aux-auto" ]] || { chmod 000 "$SECRETS_DIR"; fail "marcador con la migración incompleta"; return 1; }; chmod 000 "$SECRETS_DIR"
  # Re-ejecución: la CLI simulada no escribe el archivo; se deja el estado que habría quedado.
  : > "$STUB_CALL_LOG"
  printf 'model:\n  provider: openrouter\n  default: x/y\nauxiliary:\n  vision:\n    provider: auto\n    model: qwen/qwen3.7-flash\n' > "$APPDATA_ROOT/hermes/config.yaml"
  _hm_aux_block_or qwen/qwen3.7-flash $(printf '%s\n' "${_HM_TASKS[@]}" | grep -vx vision) >> "$APPDATA_ROOT/hermes/config.yaml"
  : > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.vision.model\t' "completa la que faltaba" || return 1
  chmod u+rwx "$SECRETS_DIR"; [[ -f "$SECRETS_DIR/hermes-aux-auto" ]] || { chmod 000 "$SECRETS_DIR"; fail "debió dejar el marcador al completar"; return 1; }; chmod 000 "$SECRETS_DIR"
  assert_file_contains "$STATE_FILE" "hermes" || return 1
}

test_hermes_aux_migration_aborts_if_previous_values_cannot_be_saved() {
  _hm_setup
  _hm_seed_existing_with_aux "$(printf 'auxiliary:\n'; _hm_aux_block_or qwen/qwen3.7-flash "${_HM_TASKS[@]}")"
  export STUB_SUDO_TEE_FAIL_TARGET="$SECRETS_DIR/hermes-aux-previous.conf"
  if bash "$REPO_ROOT/modules/hermes.sh"; then fail "debió terminar con error"; return 1; fi
  unset STUB_SUDO_TEE_FAIL_TARGET
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary' "no toca nada sin registro previo" || return 1
  assert_contains "$(_hm_dialog_text)" "no se pudo guardar el registro de sus valores previos" || return 1
  assert_file_not_contains "$STATE_FILE" "hermes" || return 1
}

test_hermes_aux_migration_interrupt_prints_incomplete_note_and_exits() {
  _hm_setup
  _hm_seed_existing_with_aux "$(printf 'auxiliary:\n'; _hm_aux_block_or qwen/qwen3.7-flash "${_HM_TASKS[@]}")"
  # El stub manda la señal al proceso 'modules/ollama.sh'; acá corre hermes.sh, así que se envía a este.
  local rc=0
  ( export STUB_HERMES_CONFIG_SET_INT_N=5 STUB_HERMES_CONFIG_SET_SIGNAL=TERM; bash -c 'exec -a modules/ollama.sh bash "$1"' _ "$REPO_ROOT/modules/hermes.sh" ) || rc=$?
  assert_eq "130" "$rc" "sale con 130" || return 1
  assert_contains "$(_hm_dialog_text)" "Se interrumpió la configuración de Hermes" || return 1
  assert_contains "$(_hm_dialog_text)" "migración incompleta:" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'docker\trestart\thermes' "reinicia Hermes para que coincida con el disco" || return 1
  assert_file_not_contains "$STATE_FILE" "hermes" || return 1
  if (( $(grep -cP '^docker\t.*config\tset\t' "$STUB_CALL_LOG") > 6 )); then fail "siguió configurando tras la interrupción"; return 1; fi
  chmod u+rwx "$SECRETS_DIR"; [[ ! -e "$SECRETS_DIR/hermes-aux-auto" ]] || { chmod 000 "$SECRETS_DIR"; fail "marcador tras interrupción"; return 1; }; chmod 000 "$SECRETS_DIR"
}

test_hermes_rerun_with_existing_config_without_auxiliary_block_only_leaves_marker() {
  _hm_setup
  _hm_seed_existing_with_aux ""
  bash "$REPO_ROOT/modules/hermes.sh" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary' || return 1
  chmod u+rwx "$SECRETS_DIR"; [[ -f "$SECRETS_DIR/hermes-aux-auto" ]] || { chmod 000 "$SECRETS_DIR"; fail "falta el marcador"; return 1; }; chmod 000 "$SECRETS_DIR"
}
