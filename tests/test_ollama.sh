#!/usr/bin/env bash
# Test end-to-end de modules/ollama.sh (todo lo privilegiado/de red stubbeado).
# Comprueba: el compose está endurecido (sin puertos, imagen fijada por digest,
# límites, una sola red); la lista de excepciones del firewall se valida y entra
# en la construcción atómica de las cadenas; las descargas de modelos son
# idempotentes; la integración con Hermes usa su CLI (sin reescribir
# config.yaml, sin tocar el modelo por defecto) y se omite si Hermes no está; el
# backup nunca incluye los modelos.

_OL_LAN="192.168.99.10"
_OL_SUBNET="10.213.144.0/24"
_OL_IP="10.213.144.250"
_OL_NET="hermes_hermes-net"
_OL_API_KEY="$(printf 'cd%.0s' {1..32})"
_OL_TASKS=(vision compression skills_hub approval review mcp title_generation
  memory_query_rewrite tts_audio_tags voice_chat triage_specifier
  kanban_decomposer profile_describer goal_judge curator monitor
  background_review moa_reference moa_aggregator)

_ol_setup() {
  harness_mark_canary_done
  export STUB_HOSTNAME_I="$_OL_LAN"
  export HLI2_HERMES_HEALTH_TIMEOUT=1 HLI2_HERMES_HEALTH_STEP=1
  export HLI2_OLLAMA_READY_TIMEOUT=1 HLI2_OLLAMA_READY_STEP=1
  export HLI2_HERMES_SBIN_DIR="$HLI2_TEST_SCRATCH/sbin"
  export HLI2_SYSTEMD_DIR="$HLI2_TEST_SCRATCH/systemd"
  export HLI2_DOCKER_DROPIN_DIR="$HLI2_TEST_SCRATCH/docker.service.d"
  export STUB_TEXTBOX_LOG="$HLI2_TEST_SCRATCH/textbox.log"
  : > "$STUB_TEXTBOX_LOG"
  export STUB_HERMES_ALIASES="gemma4-e4b-local gemma4-e2b-local"
}

_ol_dialog_text() { grep -F $'dialog\t' "$STUB_CALL_LOG" || true; }

_ol_secret_unlock() { chmod u+rwx "$SECRETS_DIR"; }
_ol_secret_lock() { chmod 000 "$SECRETS_DIR"; }

# Hermes "instalado": estado, script de aislamiento, red de Docker, secretos y
# un config.yaml con respaldo automático.
_ol_seed_hermes() {
  local fallback="${1:-list}"
  echo "hermes" >> "$STATE_FILE"
  mkdir -p "$HLI2_HERMES_SBIN_DIR"
  ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_render_egress_script "$_OL_SUBNET" "1.1.1.1 9.9.9.9" ) > "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress"
  chmod 0755 "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress"
  export STUB_DOCKER_NETWORKS="${_OL_NET} ${_OL_SUBNET}"
  export STUB_DOCKER_INSPECT_NETWORKS="$_OL_NET"
  _ol_secret_unlock
  printf 'API_SERVER_KEY=%s\nHLI_CREDENTIALS_PENDING=0\n' "$_OL_API_KEY" > "$SECRETS_DIR/hermes.env"
  chmod 0600 "$SECRETS_DIR/hermes.env"
  _ol_secret_lock
  mkdir -p "$APPDATA_ROOT/hermes"
  {
    printf '# editado por el usuario\nmodel:\n  provider: openrouter\n  default: deepseek/deepseek-v4.1-flash\n'
    if [[ "$fallback" == "list" ]]; then
      printf 'fallback_providers:\n- provider: openrouter\n  model: qwen/qwen3.7-flash\n'
    else
      printf 'fallback_providers: []\n'
    fi
  } > "$APPDATA_ROOT/hermes/config.yaml"
}

# Marcadores (root-only), como los deja el módulo: tareas auxiliares en 'auto'
# (hermes-aux-auto) e integración con Ollama completa (hermes-ollama-integrated).
_ol_marker_set() {
  _ol_secret_unlock
  printf '# listo\n# aux-version: 2 (reasoning_effort none en compression y title_generation)\n' > "$SECRETS_DIR/hermes-aux-auto"
  printf '# listo\n' > "$SECRETS_DIR/hermes-ollama-integrated"
  chmod 0600 "$SECRETS_DIR/hermes-aux-auto" "$SECRETS_DIR/hermes-ollama-integrated"
  _ol_secret_lock
}
# ¿Existe el marcador $1 (nombre de archivo en /etc/hli2)?
_ol_file_exists() {
  local rc=0
  _ol_secret_unlock
  [[ -f "$SECRETS_DIR/$1" ]] || rc=1
  _ol_secret_lock
  return "$rc"
}
_ol_marker_exists() { _ol_file_exists hermes-aux-auto; }

# Bloque 'auxiliary:' como lo dejaría 'hermes config set' tras migrar las tareas
# de la lista $@ (la CLI simulada no escribe el archivo): campos completos.
_ol_aux_block_local() {
  local t
  for t in "$@"; do
    printf '  %s:\n    provider: custom\n    model: gemma4:e2b\n    base_url: http://%s:11434/v1\n    api_key: no-key-required\n' "$t" "$_OL_IP"
    [[ "$t" == review ]] || printf '    timeout: 3600\n'
    case "$t" in review|memory_query_rewrite) ;; *) printf '    reasoning_effort: none\n' ;; esac
    [[ "$t" != compression ]] || printf '    no_progress_timeout: 900\n'
  done
}

_ol_standalone_env() {
  export STUB_DOCKER_INSPECT_NETWORKS="ollama_ollama-net"
}

_ol_calls() { grep -P "$1" "$STUB_CALL_LOG" || true; }

# Ejecuta el script de aislamiento instalado contra el 'iptables' falso. El
# archivo de excepciones vive en el área root-only: se destraba solo durante la
# corrida (en producción el script corre como root).
_ol_run_egress() {
  local action="$1" rc=0
  _ol_secret_unlock
  HLI2_EGRESS_EXPECT_UID="$(id -u)" HLI2_IPTABLES="$STUBS_DIR/iptables" bash "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" "$action" 2>"$HLI2_TEST_SCRATCH/egress.err" || rc=$?
  _ol_secret_lock
  return "$rc"
}

_ol_ipt_calls() {
  grep -F $'iptables\t' "$STUB_CALL_LOG" | sed 's/^iptables\t-w\t//; s/^iptables\t//' || true
}

# --- Compose ---------------------------------------------------------------------

test_ollama_compose_template_hardening() {
  local f="$REPO_ROOT/compose/ollama/docker-compose.yml" code
  code="$(grep -v '^[[:space:]]*#' "$f")"
  assert_not_contains "$code" "ports:" "sin puertos publicados" || return 1
  assert_not_contains "$code" "docker.sock" || return 1
  assert_not_contains "$code" "network_mode" || return 1
  assert_not_contains "$code" "privileged" || return 1
  assert_not_contains "$code" "cap_add" || return 1
  assert_not_contains "$code" ":latest" "imagen fijada" || return 1
  assert_not_contains "$code" "/home" || return 1
  assert_not_contains "$code" "traefik" || return 1
  assert_not_contains "$code" "dokploy-network" || return 1
  grep -Eq '^[[:space:]]*image: ollama/ollama:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$' <<<"$code" \
    || { fail "la imagen debe estar fijada a una versión X.Y.Z y a un digest sha256"; return 1; }
  assert_contains "$code" "no-new-privileges:true" || return 1
  assert_contains "$code" "restart: unless-stopped" || return 1
  assert_contains "$code" "container_name: ollama" || return 1
  # Límites: cada uno en UN solo lugar (Compose v2 rechaza duplicados con pids_limit).
  assert_contains "$code" "memory: 20G" || return 1
  assert_contains "$code" 'cpus: "8"' || return 1
  assert_contains "$code" "pids: 512" || return 1
  if [[ "$code" == *"pids_limit"* || "$code" == *"mem_limit"* ]]; then fail "límite duplicado fuera de deploy.resources.limits"; return 1; fi
  assert_eq "1" "$(grep -c 'memory:' <<<"$code")" "un solo límite de memoria" || return 1
  # Variables del servidor.
  local v
  for v in OLLAMA_HOST=0.0.0.0:11434 OLLAMA_CONTEXT_LENGTH=65536 OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_KEEP_ALIVE=30m; do
    assert_contains "$code" "- $v" "variable $v" || return 1
  done
  # Hermes exige >= 64.000 tokens: la ventana por defecto no puede ser menor.
  local ctx; ctx="$(grep -o 'OLLAMA_CONTEXT_LENGTH=[0-9]*' <<<"$code" | cut -d= -f2)"
  (( ctx >= 64000 )) || { fail "contexto $ctx por debajo del mínimo de Hermes (64000)"; return 1; }
  # Un único montaje: la carpeta de modelos.
  assert_eq "1" "$(grep -c '^[[:space:]]*- .*:/' <<<"$(sed -n '/volumes:/,/healthcheck:/p' <<<"$code")")" "un único montaje" || return 1
  assert_contains "$code" "__APPDATA__/ollama:/root/.ollama" || return 1
}

test_ollama_compose_render_modes_and_validation() {
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; compose_render_ollama hermes "$_OL_NET" "$_OL_IP" "1.1.1.1,9.9.9.9" ) | grep -v '^[[:space:]]*#' )" || return 1
  assert_contains "$out" $'    networks:\n      hermes-net:\n        ipv4_address: '"$_OL_IP" || return 1
  assert_contains "$out" $'networks:\n  hermes-net:\n    external: true\n    name: '"$_OL_NET" || return 1
  assert_contains "$out" $'    dns:\n      - 1.1.1.1\n      - 9.9.9.9' || return 1
  assert_not_contains "$out" "ollama-net" "solo la red de Hermes" || return 1
  assert_not_contains "$out" "ports:" || return 1
  assert_not_contains "$out" "__" "sin marcadores sin sustituir" || return 1
  assert_contains "$out" "$APPDATA_ROOT/ollama:/root/.ollama" || return 1

  out="$( ( source "$REPO_ROOT/lib/core.sh"; compose_render_ollama standalone ) | grep -v '^[[:space:]]*#' )" || return 1
  assert_contains "$out" $'    networks:\n      - ollama-net' || return 1
  assert_contains "$out" $'networks:\n  ollama-net:\n    driver: bridge' || return 1
  assert_not_contains "$out" "hermes-net" || return 1
  assert_not_contains "$out" "ipv4_address" || return 1
  assert_not_contains "$out" "dns:" || return 1
  assert_not_contains "$out" "__" || return 1

  local bad
  for bad in "bad net" "-x" "a/b" ""; do
    if ( source "$REPO_ROOT/lib/core.sh"; compose_render_ollama hermes "$bad" "$_OL_IP" "1.1.1.1" ) >/dev/null 2>&1; then fail "aceptó la red [$bad]"; return 1; fi
  done
  for bad in "0.0.0.0" "300.1.1.1" "abc" ""; do
    if ( source "$REPO_ROOT/lib/core.sh"; compose_render_ollama hermes "$_OL_NET" "$bad" "1.1.1.1" ) >/dev/null 2>&1; then fail "aceptó la IP [$bad]"; return 1; fi
  done
  if ( source "$REPO_ROOT/lib/core.sh"; compose_render_ollama hermes "$_OL_NET" "$_OL_IP" "no-ip" ) >/dev/null 2>&1; then fail "aceptó un DNS inválido"; return 1; fi
  if ( source "$REPO_ROOT/lib/core.sh"; compose_render_ollama hermes "$_OL_NET" "$_OL_IP" ) >/dev/null 2>&1; then fail "aceptó faltar el DNS"; return 1; fi
  if ( source "$REPO_ROOT/lib/core.sh"; compose_render_ollama otro ) >/dev/null 2>&1; then fail "aceptó un modo desconocido"; return 1; fi
}

# --- Lista de excepciones del firewall ----------------------------------------------

test_ollama_allow_entry_validation() {
  local ok bad
  for ok in "10.213.144.250:11434/tcp" "10.213.144.2:1/udp" "10.213.144.254:65535/tcp"; do
    ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_valid_allow_entry "$ok" "$_OL_SUBNET" ) || { fail "rechazó la entrada válida [$ok]"; return 1; }
  done
  for bad in "192.168.99.10:11434/tcp" "10.213.145.250:11434/tcp" "10.213.144.1:11434/tcp" "10.213.144.0:11434/tcp" \
             "10.213.144.255:11434/tcp" "10.213.144.250:0/tcp" "10.213.144.250:65536/tcp" "10.213.144.250:99999/tcp" \
             "10.213.144.250:11434/icmp" "10.213.144.250:11434" "10.213.144.250/tcp" "10.213.144.256:80/tcp" \
             "10.213.144.08:80/tcp" "10.213.144.250:080/tcp" "8.8.8.8:53/udp" "100.64.0.1:80/tcp" "127.0.0.1:80/tcp" \
             "hola" "" "10.213.144.250:11434/tcp; rm -rf /" " 10.213.144.250:11434/tcp"; do
    if ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_valid_allow_entry "$bad" "$_OL_SUBNET" ) 2>/dev/null; then fail "aceptó la entrada inválida [$bad]"; return 1; fi
  done
  # Subred inválida: nada se acepta.
  if ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_valid_allow_entry "10.213.144.250:11434/tcp" "10.213.144.0/16" ) 2>/dev/null; then fail "aceptó una subred /16"; return 1; fi
}

test_ollama_allow_add_is_idempotent_and_root_only() {
  _ol_setup
  ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_allow_add "${_OL_IP}:11434/tcp" "$_OL_SUBNET" ) || return 1
  assert_file_contains "$STUB_CALL_LOG" $'install\t-m\t0600\t-o\troot\t-g\troot\t/dev/null\t'"$SECRETS_DIR/hermes-egress-allow.conf" "archivo creado 0600 root" || return 1
  _ol_secret_unlock
  assert_eq "1" "$(grep -c "^${_OL_IP}:11434/tcp\$" "$SECRETS_DIR/hermes-egress-allow.conf")" "una línea" || { _ol_secret_lock; return 1; }
  _ol_secret_lock
  : > "$STUB_CALL_LOG"
  ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_allow_add "${_OL_IP}:11434/tcp" "$_OL_SUBNET" ) || return 1
  if grep -qF $'tee\t' "$STUB_CALL_LOG"; then fail "reescribió el archivo sin cambios"; return 1; fi
  # Una segunda excepción se agrega sin perder la primera.
  ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_allow_add "10.213.144.20:8080/tcp" "$_OL_SUBNET" ) || return 1
  _ol_secret_unlock
  assert_file_contains "$SECRETS_DIR/hermes-egress-allow.conf" "${_OL_IP}:11434/tcp" || { _ol_secret_lock; return 1; }
  assert_file_contains "$SECRETS_DIR/hermes-egress-allow.conf" "10.213.144.20:8080/tcp" || { _ol_secret_lock; return 1; }
  _ol_secret_lock
  # Fuera de la subred: se rechaza y no se escribe.
  if ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_allow_add "192.168.99.5:80/tcp" "$_OL_SUBNET" ) 2>/dev/null; then fail "aceptó una IP de la LAN"; return 1; fi
  _ol_secret_unlock
  assert_file_not_contains "$SECRETS_DIR/hermes-egress-allow.conf" "192.168.99.5" || { _ol_secret_lock; return 1; }
  _ol_secret_lock
}

test_ollama_egress_script_applies_allow_list_inside_atomic_build() {
  _ol_setup
  _ol_seed_hermes
  _ol_secret_unlock
  {
    echo "# comentario"
    echo "${_OL_IP}:11434/tcp"
    echo "192.168.99.5:80/tcp"            # LAN: inválida
    echo "10.213.144.1:80/tcp"            # puerta de enlace: inválida
    echo "10.213.145.9:80/tcp"            # otra subred: inválida
    echo "10.213.144.20:99999/tcp"        # puerto inválido
    echo "10.213.144.21:80/icmp"          # protocolo inválido
    echo "basura"
    echo "  10.213.144.22:8080/udp  "     # espacios en los extremos: se recortan
  } > "$SECRETS_DIR/hermes-egress-allow.conf"
  chmod 0600 "$SECRETS_DIR/hermes-egress-allow.conf"
  _ol_secret_lock
  : > "$STUB_CALL_LOG"
  _ol_run_egress apply || return 1
  local ipt; ipt="$(_ol_ipt_calls)"
  local chain
  assert_contains "$ipt" $'-A\tHLI2-HERMES-FWD-new\t-d\t'"${_OL_IP}"$'\t-p\ttcp\t--dport\t11434\t-j\tACCEPT' "excepción en FWD" || return 1
  assert_contains "$ipt" $'-A\tHLI2-HERMES-FWD-new\t-d\t10.213.144.22\t-p\tudp\t--dport\t8080\t-j\tACCEPT' "línea con espacios en los extremos" || return 1
  # La cadena IN (destinos del propio servidor) no lleva excepciones de la subred.
  assert_not_contains "$ipt" $'-A\tHLI2-HERMES-IN-new\t-d\t'"${_OL_IP}" "sin regla muerta en IN" || return 1
  for bad in 192.168.99.5 10.213.144.1 10.213.145.9 10.213.144.20 10.213.144.21; do
    assert_not_contains "$ipt" $'-d\t'"$bad"$'\t-p' "no se abre [$bad]" || return 1
  done
  assert_contains "$(< "$HLI2_TEST_SCRATCH/egress.err")" "excepción ignorada" "avisa de las líneas descartadas" || return 1
  # Orden: la excepción entra ANTES del salto a la cadena nueva (construcción
  # atómica) y antes del hook ALLOW.
  local n_rule n_hook n_jump
  n_rule="$(_ol_ipt_calls | grep -nF -- $'-A\tHLI2-HERMES-FWD-new\t-d\t'"${_OL_IP}" | head -1 | cut -d: -f1)"
  n_hook="$(_ol_ipt_calls | grep -nF -- $'-A\tHLI2-HERMES-FWD-new\t-j\tHLI2-HERMES-ALLOW' | head -1 | cut -d: -f1)"
  n_jump="$(_ol_ipt_calls | grep -nF -- $'-I\tDOCKER-USER\t1\t-s\t'"${_OL_SUBNET}"$'\t-j\tHLI2-HERMES-FWD-new' | head -1 | cut -d: -f1)"
  [[ -n "$n_rule" && -n "$n_hook" && -n "$n_jump" ]] || { fail "faltan operaciones: regla=$n_rule hook=$n_hook salto=$n_jump"; return 1; }
  (( n_rule < n_hook && n_hook < n_jump )) || { fail "la excepción debe armarse antes del hook y del salto a la cadena nueva"; return 1; }
  # La excepción va después de ESTABLISHED,RELATED y antes de los DROP hacia 10/8.
  local n_est n_drop
  n_est="$(_ol_ipt_calls | grep -nF -- $'-A\tHLI2-HERMES-FWD-new\t-m\tconntrack' | head -1 | cut -d: -f1)"
  n_drop="$(_ol_ipt_calls | grep -nF -- $'-A\tHLI2-HERMES-FWD-new\t-d\t10.0.0.0/8\t-j\tDROP' | head -1 | cut -d: -f1)"
  (( n_est < n_rule && n_rule < n_drop )) || { fail "orden de reglas incorrecto (ESTABLISHED < excepción < DROP 10/8)"; return 1; }
  # El hook y los DROP siguen presentes (el resto de la LAN sigue bloqueado).
  assert_contains "$ipt" $'-A\tHLI2-HERMES-FWD-new\t-d\t192.168.0.0/16\t-j\tDROP' || return 1
}

# --- Despliegue con Hermes ------------------------------------------------------------

test_ollama_deploy_with_hermes() {
  _ol_setup
  _ol_seed_hermes
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_contains "$STATE_FILE" "ollama" "mark_done" || return 1

  # Compose: red externa de Hermes con IP fija, DNS de Hermes, sin puertos.
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "ipv4_address: ${_OL_IP}" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "name: ${_OL_NET}" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "external: true" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "- 1.1.1.1" "mismos DNS que Hermes" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "ollama/ollama:0.40.6@sha256:" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "ports:" "sin puertos" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "ollama/ollama:latest" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" '"composeType": "docker-compose"' || return 1

  # Carpeta de modelos: root, 0755.
  assert_file_contains "$STUB_CALL_LOG" $'install\t-d\t-m\t0755\t-o\troot\t-g\troot\t'"$APPDATA_ROOT/ollama" || return 1

  # Firewall: excepción guardada y reglas aplicadas ANTES del despliegue.
  _ol_secret_unlock
  assert_file_contains "$SECRETS_DIR/hermes-egress-allow.conf" "${_OL_IP}:11434/tcp" "excepción persistida" || { _ol_secret_lock; return 1; }
  assert_file_contains "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" 'ALLOW_FILE=' "script nuevo con lista de excepciones" || { _ol_secret_lock; return 1; }
  _ol_secret_lock
  local script="$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" l_apply l_deploy
  l_apply="$(grep -nF $'sudo\t'"$script"$'\tapply' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  l_deploy="$(grep -n 'compose.deploy' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  [[ -n "$l_apply" && -n "$l_deploy" && "$l_apply" -lt "$l_deploy" ]] || { fail "las reglas deben aplicarse antes del deploy"; return 1; }

  # Modelos descargados (los dos) con 'ollama pull' dentro del contenedor.
  assert_file_contains "$STUB_CALL_LOG" $'exec\tollama\tollama\tpull\tgemma4:e4b' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'exec\tollama\tollama\tpull\tgemma4:e2b' || return 1

  # Integración con la CLI de Hermes, con el uid/gid del agente.
  local ex=$'exec\t-u\t'"$(id -u):$(id -g)"$'\thermes\t/opt/hermes/.venv/bin/hermes\tconfig\tset\t'
  assert_file_contains "$STUB_CALL_LOG" "${ex}providers.ollama-local.api"$'\thttp://'"${_OL_IP}:11434/v1" || return 1
  assert_file_contains "$STUB_CALL_LOG" "${ex}providers.ollama-local.request_timeout_seconds"$'\t3600' "tiempo de espera largo" || return 1
  assert_file_contains "$STUB_CALL_LOG" "${ex}providers.ollama-local.stale_timeout_seconds"$'\t3600' || return 1
  assert_file_contains "$STUB_CALL_LOG" "${ex}providers.ollama-local.models.gemma4:e4b.context_length"$'\t65536' || return 1
  assert_file_contains "$STUB_CALL_LOG" "${ex}providers.ollama-local.models.gemma4:e2b.context_length"$'\t65536' || return 1
  assert_file_contains "$STUB_CALL_LOG" "${ex}platforms.api_server.model_routes.gemma4-e4b-local.model"$'\tgemma4:e4b' || return 1
  assert_file_contains "$STUB_CALL_LOG" "${ex}platforms.api_server.model_routes.gemma4-e4b-local.provider"$'\tollama-local' || return 1
  assert_file_contains "$STUB_CALL_LOG" "${ex}platforms.api_server.model_routes.gemma4-e2b-local.base_url"$'\thttp://'"${_OL_IP}:11434/v1" || return 1
  assert_file_contains "$STUB_CALL_LOG" "${ex}platforms.api_server.model_routes.gemma4-e4b-local.api_key"$'\tno-key-required' "clave ficticia: nunca la de OpenRouter" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'docker\trestart\thermes' || return 1
  if grep -F $'docker\texec\t' "$STUB_CALL_LOG" | grep -vE $'exec\t(-i\t)?-u\t|exec\t-t\tollama|exec\tollama' | grep -q .; then fail "un docker exec corrió sin -u"; return 1; fi

  # /v1/models se consultó con la clave por stdin (-K -), y la prueba desde Hermes corrió.
  grep -qF $'\t-K\t-\thttp://'"${_OL_LAN}:8642/v1/models" "$STUB_CALL_LOG" || { fail "/v1/models debe usar -K - para la clave"; return 1; }
  assert_file_not_contains "$STUB_CALL_LOG" "$_OL_API_KEY" "la clave nunca va por argv" || return 1
  assert_file_contains "$STUB_CALL_LOG" "${_OL_IP}:11434/api/tags" "prueba de alcance desde Hermes" || return 1

  # Mensaje final.
  local texts; texts="$(_ol_dialog_text)"
  assert_contains "$texts" "ollama ps" || return 1
  assert_contains "$texts" "gemma4-e4b-local" || return 1
  assert_contains "$texts" "primer mensaje" "latencia esperada" || return 1
  assert_contains "$texts" "Privacidad" || return 1
  assert_not_contains "$texts" "ATENCIÓN: No se" "sin avisos de error" || return 1
}

test_ollama_integration_never_touches_default_model_nor_rewrites_config() {
  _ol_setup
  _ol_seed_hermes
  local before; before="$(< "$APPDATA_ROOT/hermes/config.yaml")"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_eq "$before" "$(< "$APPDATA_ROOT/hermes/config.yaml")" "config.yaml intacto (solo la CLI de Hermes lo cambia)" || return 1
  # Ninguna escritura directa a config.yaml.
  if grep -E $'^sudo\t(tee|mv|cp|install)\t' "$STUB_CALL_LOG" | grep -qF "hermes/config.yaml"; then fail "el módulo escribió config.yaml directamente"; return 1; fi
  # El modelo por defecto no se toca.
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset\tmodel' "ningún 'config set model...'" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'set\tfallback_providers' || return 1
  # Pensamiento desactivado con 'false' ('none' se guardaría como null).
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tagent.reasoning_overrides.gemma4:e4b\tfalse' || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'agent.reasoning_overrides.gemma4:e4b\tnone' || return 1
}

test_ollama_rerun_with_existing_provider_only_updates_urls() {
  _ol_setup
  _ol_seed_hermes empty
  printf 'providers:\n  ollama-local:\n    api: http://10.213.144.9:11434/v1\n    request_timeout_seconds: 7200\n' >> "$APPDATA_ROOT/hermes/config.yaml"
  _ol_marker_set
  : > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  local ex=$'config\tset\t'
  assert_file_contains "$STUB_CALL_LOG" "${ex}providers.ollama-local.api"$'\thttp://'"${_OL_IP}:11434/v1" "actualiza la URL" || return 1
  assert_file_contains "$STUB_CALL_LOG" "${ex}platforms.api_server.model_routes.gemma4-e4b-local.base_url" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "request_timeout_seconds" "no pisa los tiempos de espera del usuario" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "reasoning_overrides" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "context_length" || return 1
  # Sin respaldo configurado: no hay pregunta ni 'fallback clear'.
  assert_file_not_contains "$STUB_CALL_LOG" $'fallback\tclear' || return 1
  assert_not_contains "$(_ol_dialog_text)" "Hermes tiene un respaldo automático" "no pregunta si no hay respaldo" || return 1
}

test_ollama_fallback_removed_when_accepted_and_kept_with_warning_when_declined() {
  _ol_setup
  _ol_seed_hermes
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'exec\t-i\t-u\t'"$(id -u):$(id -g)"$'\thermes\t/opt/hermes/.venv/bin/hermes\tfallback\tclear' "vacía la cadena" || return 1
  assert_contains "$(_ol_dialog_text)" "Respaldo automático quitado" || return 1
  assert_contains "$(_ol_dialog_text)" "GLOBAL" "explica por qué" || return 1

  # Rechazado: no se toca y se avisa claramente.
  : > "$STUB_CALL_LOG"
  sed -i '/^ollama$/d' "$STATE_FILE"
  echo "no" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'fallback\tclear' "no se tocó el respaldo" || return 1
  assert_contains "$(_ol_dialog_text)" "AVISO: el respaldo automático hacia OpenRouter sigue activo" || return 1
  assert_contains "$(_ol_dialog_text)" "FALLA" || return 1
  assert_contains "$(_ol_dialog_text)" "filtrarse" "dice que un chat local puede filtrarse" || return 1
}

test_ollama_models_missing_from_v1_models_or_unreachable_warn() {
  _ol_setup
  _ol_seed_hermes
  export STUB_HERMES_ALIASES=""
  export STUB_OLLAMA_REACH="000"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  local texts; texts="$(_ol_dialog_text)"
  assert_contains "$texts" "NO lista: gemma4-e4b-local gemma4-e2b-local" || return 1
  assert_contains "$texts" "NO se alcanzó http://${_OL_IP}:11434/api/tags" || return 1
  assert_contains "$texts" "HLI2-HERMES-FWD" "indica cómo revisar el firewall" || return 1
}

test_ollama_integration_failure_is_reported_not_fatal() {
  _ol_setup
  _ol_seed_hermes
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  # Una config.yaml sin 'model:' no es utilizable: se omite la integración.
  printf 'basura: x\n' > "$APPDATA_ROOT/hermes/config.yaml"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset' "no configura sobre un config.yaml inválido" || return 1
  assert_contains "$(_ol_dialog_text)" "No se integró con Hermes" || return 1
  assert_file_contains "$STATE_FILE" "ollama" "Ollama sí queda desplegado" || return 1
}

# --- Sin Hermes ---------------------------------------------------------------------------

test_ollama_standalone_skips_integration_and_firewall() {
  _ol_setup
  _ol_standalone_env
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_contains "$STATE_FILE" "ollama" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "ollama-net" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "external: true" "sin red de Hermes" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "ipv4_address" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "ports:" || return 1
  # Ni firewall, ni lista de excepciones, ni nada de Hermes.
  [[ ! -e "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" ]] || { fail "instaló el aislamiento sin Hermes"; return 1; }
  if grep -qF $'iptables\t' "$STUB_CALL_LOG"; then fail "tocó iptables sin Hermes"; return 1; fi
  assert_file_not_contains "$STUB_CALL_LOG" "hermes-egress-allow" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'hermes\t/opt/hermes' "ningún comando dentro de Hermes" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'restart\thermes' || return 1
  # Los modelos sí se descargan.
  assert_file_contains "$STUB_CALL_LOG" $'pull\tgemma4:e4b' || return 1
  assert_contains "$(_ol_dialog_text)" "Hermes no está instalado" || return 1
}

test_ollama_hermes_marked_done_but_network_missing_falls_back_to_standalone() {
  _ol_setup
  _ol_seed_hermes
  unset STUB_DOCKER_NETWORKS
  _ol_standalone_env
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_contains "$(_ol_dialog_text)" "no se encontró su red de Docker" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "ollama-net" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset' || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'sudo\t'"$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress"$'\tapply' || return 1
}

# --- IP y red ------------------------------------------------------------------------------

test_ollama_invalid_or_taken_ip_installs_nothing() {
  _ol_setup
  _ol_seed_hermes
  local bad
  for bad in "192.168.99.50" "10.213.144.1" "10.213.144.0" "10.213.144.255" "10.213.145.250" "abc" "10.213.144.08"; do
    : > "$STUB_CALL_LOG"; : > "$STUB_HTTP_BODIES_LOG"
    export HLI2_OLLAMA_IP="$bad"
    if bash "$REPO_ROOT/modules/ollama.sh"; then fail "aceptó la IP [$bad]"; return 1; fi
    assert_contains "$(_ol_dialog_text)" "HLI2_OLLAMA_IP" "mensaje para [$bad]" || return 1
    assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "compose" || return 1
    if grep -qF $'iptables\t' "$STUB_CALL_LOG"; then fail "tocó iptables con [$bad]"; return 1; fi
  done
  unset HLI2_OLLAMA_IP
  # IP ocupada por otro contenedor de la red.
  : > "$STUB_CALL_LOG"; : > "$STUB_HTTP_BODIES_LOG"
  export STUB_DOCKER_NET_CONTAINERS="hermes 10.213.144.250/24"
  if bash "$REPO_ROOT/modules/ollama.sh"; then fail "aceptó una IP ocupada"; return 1; fi
  assert_contains "$(_ol_dialog_text)" "ya la usa otro contenedor" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "compose" || return 1
  # Si la ocupa el propio ollama (re-ejecución) no es un conflicto.
  export STUB_DOCKER_NET_CONTAINERS="ollama 10.213.144.250/24"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
}

test_ollama_custom_ip_inside_subnet_is_used_everywhere() {
  _ol_setup
  _ol_seed_hermes
  export HLI2_OLLAMA_IP="10.213.144.77"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "ipv4_address: 10.213.144.77" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'providers.ollama-local.api\thttp://10.213.144.77:11434/v1' || return 1
  _ol_secret_unlock
  assert_file_contains "$SECRETS_DIR/hermes-egress-allow.conf" "10.213.144.77:11434/tcp" || { _ol_secret_lock; return 1; }
  _ol_secret_lock
}

test_ollama_warns_if_container_has_other_networks() {
  _ol_setup
  _ol_seed_hermes
  export STUB_DOCKER_INSPECT_NETWORKS="${_OL_NET} dokploy-network"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_contains "$(_ol_dialog_text)" "ATENCIÓN: el contenedor 'ollama' está conectado a estas redes: ${_OL_NET} dokploy-network" || return 1
}

# --- Modelos ---------------------------------------------------------------------------------

test_ollama_pull_is_idempotent() {
  _ol_setup
  _ol_standalone_env
  # Ambos ya presentes: ninguna descarga.
  export STUB_OLLAMA_MODELS="gemma4:e4b gemma4:e2b"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'ollama\tpull' "no vuelve a descargar" || return 1
  # Solo falta uno.
  : > "$STUB_CALL_LOG"
  export STUB_OLLAMA_MODELS="gemma4:e4b"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'pull\tgemma4:e4b' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'pull\tgemma4:e2b' || return 1
  # Una etiqueta parecida (otra variante) no cuenta como presente.
  : > "$STUB_CALL_LOG"
  export STUB_OLLAMA_MODELS="gemma4:e4b-it-q8_0 gemma4:e2b-it-q8_0"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'pull\tgemma4:e4b' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'pull\tgemma4:e2b' || return 1
}

test_ollama_pull_failure_is_clear_and_not_marked_done() {
  _ol_setup
  _ol_standalone_env
  export STUB_OLLAMA_PULL_FAIL=1
  if bash "$REPO_ROOT/modules/ollama.sh"; then fail "debió fallar si la descarga falla"; return 1; fi
  assert_contains "$(_ol_dialog_text)" "No se pudo descargar el modelo gemma4:e4b" || return 1
  assert_file_not_contains "$STATE_FILE" "ollama" || return 1
}

test_ollama_alias_names() {
  assert_eq "gemma4-e4b-local" "$(bash -c 'source "$1"; _ollama_alias gemma4:e4b' "$REPO_ROOT/modules/_" "$REPO_ROOT/modules/ollama.sh")" || return 1
  assert_eq "gemma4-e2b-local" "$(bash -c 'source "$1"; _ollama_alias gemma4:e2b' "$REPO_ROOT/modules/_" "$REPO_ROOT/modules/ollama.sh")" || return 1
}

# --- Registro y backup -------------------------------------------------------------------------

test_ollama_registry_and_backup_exclude_models() {
  local out
  out="$( ( source "$REPO_ROOT/lib/core.sh"; service_list ) )"
  grep -qx ollama <<<"$out" || { fail "ollama no aparece en service_list"; return 1; }
  out="$( ( source "$REPO_ROOT/lib/core.sh"
    echo "c=$(service_get ollama CONTAINER)"
    echo "k=$(service_get ollama BACKUP_KIND)"
    echo "d=$(service_get ollama DATA)"
    echo "p=[$(service_get ollama PORT)]" ) )"
  assert_contains "$out" "c=ollama" || return 1
  assert_contains "$out" "k=none" "sin parada ni base embebida" || return 1
  assert_contains "$out" "d=" || return 1
  assert_not_contains "$out" "d=$APPDATA_ROOT" "sin datos respaldables: los modelos se vuelven a descargar" || return 1
  assert_contains "$out" "p=[]" "sin puerto publicado" || return 1

  # Con modelos en disco, el backup NO los incluye (ni local ni nube) y no
  # detiene el contenedor.
  mkdir -p "$APPDATA_ROOT/ollama/models/blobs"
  echo "peso" > "$APPDATA_ROOT/ollama/models/blobs/sha256-abc"
  out="$( ( source "$REPO_ROOT/lib/core.sh"; _backup_collect
    printf 'full:%s\n' "${BK_PATHS[@]}"; printf 'cloud:%s\n' "${BK_CLOUD_PATHS[@]}"
    printf 'excl:%s\n' "${BK_EXCLUDE_ARGS[@]}"
    printf 'sqlite:%s\n' "$(_backup_sqlite_containers)" ) )"
  assert_not_contains "$out" "full:$APPDATA_ROOT/ollama" "fuera de la copia local" || return 1
  assert_not_contains "$out" "cloud:$APPDATA_ROOT/ollama" "fuera de la copia en la nube" || return 1
  assert_not_contains "$out" "sqlite:ollama" "el contenedor no se detiene en el backup" || return 1
  assert_not_contains "$out" "ollama" "ninguna ruta de ollama en la foto" || return 1
  # "Restaurar todo" no lo detiene ni lo reinicia (no hay nada que restaurar).
  ( source "$REPO_ROOT/lib/core.sh"; source "$REPO_ROOT/lib/restore.sh" 2>/dev/null; RS_TARGET=all; _restore_target_services ) | grep -qx ollama \
    && { fail "ollama no debe ser objetivo de una restauración"; return 1; }
  return 0
}

# --- Revisión: lista de excepciones (script) ------------------------------------------

# Prepara el script y escribe el archivo de excepciones con el contenido $1 (sin
# salto final añadido) y el modo $2.
_ol_allow_file() {
  local content="$1" mode="${2:-600}"
  _ol_secret_unlock
  rm -f "$SECRETS_DIR/hermes-egress-allow.conf"
  printf '%s' "$content" > "$SECRETS_DIR/hermes-egress-allow.conf"
  chmod "$mode" "$SECRETS_DIR/hermes-egress-allow.conf"
  _ol_secret_lock
}

# Reglas con --dport que NO son de DNS ni del control positivo (puerto 9000).
_ol_unexpected_dport() {
  _ol_ipt_calls | grep -F -- $'--dport' | grep -vE -- $'--dport\t(53|9000)\t' | grep -q .
}
# Control positivo: una entrada válida en un archivo bueno SÍ se aplica (si el
# script se cayera, las pruebas negativas pasarían por la razón equivocada).
_OL_CONTROL="10.213.144.30:9000/tcp"
_ol_control_applied() {
  _ol_ipt_calls | grep -qF -- $'-A\tHLI2-HERMES-FWD-new\t-d\t10.213.144.30\t-p\ttcp\t--dport\t9000\t-j\tACCEPT'
}

test_ollama_egress_script_rejects_hostile_allow_lines() {
  _ol_setup
  _ol_seed_hermes
  local hostile=(
    "0.0.0.0:80/tcp" "10.213.144.0/24:80/tcp" "10.213.144.250:80-90/tcp" "10.213.144.250: 80/tcp"
    "10.213.144.250 :80/tcp" "10.213.144.08:80/tcp" "10.213.144.250:080/tcp" "010.213.144.250:80/tcp"
    "10.213.144.250:80/tcp extra" "10.213.144.250:80/tcp # comentario" "10.213.144.250:0/tcp"
    "10.213.144.250:70000/tcp" "10.213.144.250:80/TCP" "10.213.144.250:80" "10.213.144.1:80/tcp"
    "10.213.144.255:80/tcp" "10.213.144.5:80/tcp;rm -rf /" "\$(id):80/tcp" "10.213.144.5:80/tcp|x"
  )
  local h
  for h in "${hostile[@]}"; do
    _ol_allow_file "$h"$'\n'"$_OL_CONTROL"$'\n'
    : > "$STUB_CALL_LOG"
    _ol_run_egress apply || return 1
    _ol_control_applied || { fail "el control positivo no se aplicó con la línea [$h]"; return 1; }
    if _ol_unexpected_dport; then fail "abrió una excepción por la línea [$h]"; return 1; fi
    assert_contains "$(< "$HLI2_TEST_SCRATCH/egress.err")" "ignorada" "avisa por [$h]" || return 1
  done
  # CRLF: la línea válida con retorno de carro se descarta; la siguiente sí vale.
  _ol_allow_file "${_OL_IP}:11434/tcp"$'\r\n'"$_OL_CONTROL"$'\n'
  : > "$STUB_CALL_LOG"
  _ol_run_egress apply || return 1
  _ol_control_applied || { fail "control positivo ausente (CRLF)"; return 1; }
  if _ol_ipt_calls | grep -qF -- $'--dport\t11434\t'; then fail "aceptó una línea con CR"; return 1; fi
  assert_contains "$(< "$HLI2_TEST_SCRATCH/egress.err")" "retorno de carro" || return 1
}

test_ollama_egress_script_accepts_last_line_without_newline_and_trims_edges() {
  _ol_setup
  _ol_seed_hermes
  _ol_allow_file "   ${_OL_IP}:11434/tcp   "      # sin salto de línea final, espacios en los extremos
  : > "$STUB_CALL_LOG"
  _ol_run_egress apply || return 1
  assert_contains "$(_ol_ipt_calls)" $'-A\tHLI2-HERMES-FWD-new\t-d\t'"${_OL_IP}"$'\t-p\ttcp\t--dport\t11434\t-j\tACCEPT' || return 1
}

test_ollama_egress_script_ignores_allow_file_with_bad_mode_owner_or_symlink() {
  _ol_setup
  _ol_seed_hermes
  local mode
  for mode in 644 640 660 666 700 755; do
    _ol_allow_file "$_OL_CONTROL"$'\n' "$mode"
    : > "$STUB_CALL_LOG"
    _ol_run_egress apply || return 1
    if _ol_control_applied; then fail "leyó un archivo con modo $mode"; return 1; fi
    assert_contains "$(< "$HLI2_TEST_SCRATCH/egress.err")" "modo 600 o 400" "aviso para el modo $mode" || return 1
    # Control positivo: el MISMO contenido con modo 600 sí se aplica.
    _ol_allow_file "$_OL_CONTROL"$'\n' 600
    : > "$STUB_CALL_LOG"
    _ol_run_egress apply || return 1
    _ol_control_applied || { fail "el control positivo (modo 600) no se aplicó tras $mode"; return 1; }
  done
  # Modo 400 también vale.
  _ol_allow_file "$_OL_CONTROL"$'\n' 400
  : > "$STUB_CALL_LOG"
  _ol_run_egress apply || return 1
  _ol_control_applied || { fail "modo 400 rechazado"; return 1; }
  # Otro dueño: se espera uid 0; el archivo es del usuario del test -> se ignora.
  _ol_allow_file "$_OL_CONTROL"$'\n' 600
  _ol_secret_unlock
  : > "$STUB_CALL_LOG"
  HLI2_EGRESS_EXPECT_UID=0 HLI2_IPTABLES="$STUBS_DIR/iptables" bash "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" apply 2>"$HLI2_TEST_SCRATCH/egress.err" || true
  _ol_secret_lock
  assert_contains "$(< "$HLI2_TEST_SCRATCH/egress.err")" "debe ser de root" "otro dueño" || return 1
  if _ol_control_applied; then fail "leyó un archivo de otro dueño"; return 1; fi
  # El mismo archivo con el uid correcto sí se aplica (control).
  : > "$STUB_CALL_LOG"
  _ol_run_egress apply || return 1
  _ol_control_applied || { fail "control positivo (dueño correcto) ausente"; return 1; }
  # Enlace simbólico: se ignora aunque el destino sea válido y de modo 600.
  _ol_secret_unlock
  printf '%s\n' "$_OL_CONTROL" > "$HLI2_TEST_SCRATCH/real-allow.conf"
  chmod 600 "$HLI2_TEST_SCRATCH/real-allow.conf"
  rm -f "$SECRETS_DIR/hermes-egress-allow.conf"
  ln -s "$HLI2_TEST_SCRATCH/real-allow.conf" "$SECRETS_DIR/hermes-egress-allow.conf"
  _ol_secret_lock
  : > "$STUB_CALL_LOG"
  _ol_run_egress apply || return 1
  if _ol_control_applied; then fail "siguió un enlace simbólico"; return 1; fi
  assert_contains "$(< "$HLI2_TEST_SCRATCH/egress.err")" "no es un archivo regular" || return 1
  # Control: el mismo contenido como archivo regular sí se aplica.
  _ol_allow_file "$_OL_CONTROL"$'\n' 600
  : > "$STUB_CALL_LOG"
  _ol_run_egress apply || return 1
  _ol_control_applied || { fail "control positivo (archivo regular) ausente"; return 1; }
}

test_ollama_egress_script_without_allow_file_adds_no_exceptions() {
  _ol_setup
  _ol_seed_hermes
  : > "$STUB_CALL_LOG"
  _ol_run_egress apply || return 1
  # Solo DNS (puerto 53): ninguna otra regla con --dport.
  if _ol_ipt_calls | grep -F -- $'--dport' | grep -vF -- $'--dport\t53\t' | grep -q .; then fail "hay reglas con --dport (salvo DNS) sin archivo de excepciones"; return 1; fi
  assert_contains "$(_ol_ipt_calls)" $'-A\tHLI2-HERMES-FWD-new\t-d\t1.1.1.1\t-p\tudp\t--dport\t53\t-j\tACCEPT' "el script sí corre (DNS presente)" || return 1
  # Control positivo: con un archivo bueno aparece la excepción.
  _ol_allow_file "$_OL_CONTROL"$'\n' 600
  : > "$STUB_CALL_LOG"
  _ol_run_egress apply || return 1
  _ol_control_applied || { fail "control positivo ausente"; return 1; }
}

# --- Revisión: escritura atómica de la lista -------------------------------------------

test_ollama_allow_add_is_atomic_and_keeps_old_file_on_failure() {
  _ol_setup
  local f="$SECRETS_DIR/hermes-egress-allow.conf" before
  ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_allow_add "${_OL_IP}:11434/tcp" "$_OL_SUBNET" ) || return 1
  _ol_secret_unlock; before="$(< "$f")"; _ol_secret_lock
  # Temporal en la misma carpeta + mv.
  grep -qP "^sudo\t-n\tmv\t-f\t$f\.tmp\.[0-9]+\t$f$" "$STUB_CALL_LOG" || { fail "la escritura no usó temporal + mv"; return 1; }
  # Falla 'tee': el archivo anterior queda intacto y no sobra el temporal.
  export STUB_SUDO_TEE_FAIL_TARGET="$f"
  if ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_allow_add "10.213.144.20:8080/tcp" "$_OL_SUBNET" ) 2>/dev/null; then fail "debió fallar si tee falla"; return 1; fi
  unset STUB_SUDO_TEE_FAIL_TARGET
  _ol_secret_unlock
  assert_eq "$before" "$(< "$f")" "archivo anterior intacto tras fallar tee" || { _ol_secret_lock; return 1; }
  if ls "$SECRETS_DIR"/hermes-egress-allow.conf.tmp.* >/dev/null 2>&1; then fail "quedó un temporal"; _ol_secret_lock; return 1; fi
  _ol_secret_lock
  # Falla 'mv': igual.
  export STUB_SUDO_MV_FAIL_TARGET="$f"
  if ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_allow_add "10.213.144.20:8080/tcp" "$_OL_SUBNET" ) 2>/dev/null; then fail "debió fallar si mv falla"; return 1; fi
  unset STUB_SUDO_MV_FAIL_TARGET
  _ol_secret_unlock
  assert_eq "$before" "$(< "$f")" "archivo anterior intacto tras fallar mv" || { _ol_secret_lock; return 1; }
  if ls "$SECRETS_DIR"/hermes-egress-allow.conf.tmp.* >/dev/null 2>&1; then fail "quedó un temporal tras mv"; _ol_secret_lock; return 1; fi
  _ol_secret_lock
}

test_ollama_allow_add_aborts_when_sudo_unavailable_instead_of_assuming_missing() {
  _ol_setup
  ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_allow_add "${_OL_IP}:11434/tcp" "$_OL_SUBNET" ) || return 1
  _ol_secret_unlock; local before; before="$(< "$SECRETS_DIR/hermes-egress-allow.conf")"; _ol_secret_lock
  export STUB_SUDO_FAIL_N=1
  : > "$STUB_CALL_LOG"
  if ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_allow_add "10.213.144.20:8080/tcp" "$_OL_SUBNET" ) 2>"$HLI2_TEST_SCRATCH/err"; then fail "debió abortar sin sudo"; return 1; fi
  unset STUB_SUDO_FAIL_N
  assert_contains "$(< "$HLI2_TEST_SCRATCH/err")" "'sudo' no está disponible" || return 1
  if grep -qE $'^sudo\t(tee|mv|install)\t' "$STUB_CALL_LOG"; then fail "escribió sin saber si el archivo existía"; return 1; fi
  _ol_secret_unlock
  assert_eq "$before" "$(< "$SECRETS_DIR/hermes-egress-allow.conf")" "archivo intacto" || { _ol_secret_lock; return 1; }
  _ol_secret_lock
}

# --- Revisión: red de Hermes con la subred del aislamiento -----------------------------------

test_ollama_hermes_network_must_match_egress_subnet() {
  _ol_setup
  _ol_seed_hermes
  # Existe '…hermes-net' pero con OTRA subred: no está cubierta por el firewall.
  export STUB_DOCKER_NETWORKS="${_OL_NET} 10.99.0.0/24"
  _ol_standalone_env
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_contains "$(_ol_dialog_text)" "no se encontró su red de Docker" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "ollama-net" "queda separado" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "external: true" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset' || return 1
  # Dos candidatas, solo una con la subred: se elige esa.
  : > "$STUB_CALL_LOG"; : > "$STUB_HTTP_BODIES_LOG"
  sed -i '/^ollama$/d' "$STATE_FILE"
  export STUB_DOCKER_NETWORKS="otro_hermes-net 10.99.0.0/24
${_OL_NET} ${_OL_SUBNET}"
  export STUB_DOCKER_INSPECT_NETWORKS="$_OL_NET"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "name: ${_OL_NET}" || return 1
}

# --- Revisión: respaldo automático (legado, registro, valor por defecto) -----------------------

test_ollama_fallback_confirm_defaults_to_no() {
  _ol_setup
  _ol_seed_hermes
  echo "no" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  grep -F $'dialog\t' "$STUB_CALL_LOG" | grep -F "respaldo automático" | grep -qF -- '--defaultno' \
    || { fail "la pregunta de quitar el respaldo debe tener 'No' por defecto"; return 1; }
}

test_ollama_fallback_removed_is_saved_root_only_before_clearing() {
  _ol_setup
  _ol_seed_hermes
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  local f="$SECRETS_DIR/hermes-fallback-removed.conf"
  assert_file_contains "$STUB_CALL_LOG" $'install\t-m\t0600\t-o\troot\t-g\troot\t/dev/null\t'"${f}.tmp." "creado 0600 root" || return 1
  _ol_secret_unlock
  assert_file_contains "$f" "fallback_providers:" || { _ol_secret_lock; return 1; }
  assert_file_contains "$f" "model: qwen/qwen3.7-flash" "entradas guardadas" || { _ol_secret_lock; return 1; }
  assert_file_contains "$f" "hermes fallback add" "cómo restituir" || { _ol_secret_lock; return 1; }
  _ol_secret_lock
  # Se guardó ANTES de vaciar la cadena.
  local l_save l_clear
  l_save="$(grep -nF "hermes-fallback-removed.conf.tmp." "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  l_clear="$(grep -nF $'fallback\tclear' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  [[ -n "$l_save" && -n "$l_clear" && "$l_save" -lt "$l_clear" ]] || { fail "debe guardarse antes de vaciar"; return 1; }
  assert_contains "$(_ol_dialog_text)" "qwen/qwen3.7-flash" "el mensaje final muestra lo quitado" || return 1
}

test_ollama_fallback_is_not_cleared_if_it_cannot_be_saved() {
  _ol_setup
  _ol_seed_hermes
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  export STUB_SUDO_TEE_FAIL_TARGET="$SECRETS_DIR/hermes-fallback-removed.conf"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  unset STUB_SUDO_TEE_FAIL_TARGET
  assert_file_not_contains "$STUB_CALL_LOG" $'fallback\tclear' "sin copia no se quita" || return 1
  assert_contains "$(_ol_dialog_text)" "NO se quitó" || return 1
}

test_ollama_legacy_fallback_model_key_is_detected_and_cleared() {
  _ol_setup
  _ol_seed_hermes empty
  printf 'fallback_model:\n  provider: openrouter\n  model: viejo/modelo\n' >> "$APPDATA_ROOT/hermes/config.yaml"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_contains "$(_ol_dialog_text)" "Hermes tiene un respaldo automático" "detecta la clave heredada" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'fallback\tclear' || return 1
  _ol_secret_unlock
  assert_file_contains "$SECRETS_DIR/hermes-fallback-removed.conf" "model: viejo/modelo" || { _ol_secret_lock; return 1; }
  _ol_secret_lock
  # Vacía o nula: no cuenta.
  local v
  for v in "fallback_model: null" "fallback_model: {}" "fallback_model: []" "fallback_model: ~" "fallback_model:"; do
    : > "$STUB_CALL_LOG"
    sed -i '/^ollama$/d' "$STATE_FILE"
    _ol_seed_hermes empty
    printf '%s\n' "$v" >> "$APPDATA_ROOT/hermes/config.yaml"
    : > "$DIALOG_YESNO_QUEUE"
    bash "$REPO_ROOT/modules/ollama.sh" || return 1
    if _ol_dialog_text | grep -qF "Hermes tiene un respaldo automático"; then fail "preguntó por un respaldo vacío [$v]"; return 1; fi
  done
}

# --- Tareas auxiliares locales ------------------------------------------------------------------

test_ollama_never_pins_aux_tasks_and_leaves_them_on_auto() {
  _ol_setup
  _ol_seed_hermes
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  # Instalación sin 'auxiliary': solo se agrega el razonamiento apagado de compresión y títulos; ninguna tarea se fija.
  assert_eq "2" "$(grep -cP '^docker\t.*config\tset\tauxiliary' "$STUB_CALL_LOG")" "solo los dos reasoning_effort" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.compression.reasoning_effort\tnone' || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'.provider\tauto' "ninguna tarea se fija" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tunset' || return 1
  assert_eq "19" "${#_OL_TASKS[@]}" "las 19 tareas de v0.22.2" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset\tmodel' "el modelo por defecto no se toca" || return 1
  # Lo que SÍ se conserva: proveedor local, rutas, tiempos largos y razonamiento apagado del chat.
  local ex=$'config\tset\t'
  assert_file_contains "$STUB_CALL_LOG" "${ex}providers.ollama-local.request_timeout_seconds"$'\t3600' || return 1
  assert_file_contains "$STUB_CALL_LOG" "${ex}agent.reasoning_overrides.gemma4:e4b"$'\tfalse' || return 1
  assert_file_contains "$STUB_CALL_LOG" "${ex}platforms.api_server.model_routes.gemma4-e4b-local.provider"$'\tollama-local' || return 1
  _ol_marker_exists || { fail "debió dejar el marcador de tareas en auto"; return 1; }
  _ol_file_exists hermes-ollama-integrated || { fail "debió dejar el marcador de integración"; return 1; }
}

test_ollama_migrates_previous_local_pins_to_auto_without_openrouter_values() {
  _ol_setup
  _ol_seed_hermes
  _ol_config_with_local_aux "${_OL_TASKS[@]}"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  local ex=$'config\tset\t' t
  for t in "${_OL_TASKS[@]}"; do
    assert_file_contains "$STUB_CALL_LOG" "${ex}auxiliary.${t}.provider"$'\tauto' "provider auto en $t" || return 1
    assert_file_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary.'"${t}"$'.base_url' || return 1
    assert_file_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary.'"${t}"$'.api_key' || return 1
  done
  assert_file_contains "$STUB_CALL_LOG" "${ex}auxiliary.compression.timeout"$'\t1800' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary.vision.reasoning_effort' || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary.review.timeout' "review no tenía timeout" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary.review.reasoning_effort' || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary.memory_query_rewrite.reasoning_effort' || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "auxiliary.compression.no_progress_timeout" "ya estaba en 900" || return 1
  # Nada nuevo apunta a OpenRouter ni a Ollama desde 'auxiliary'.
  if grep -P $'config\tset\tauxiliary[^\t]*\t.*(openrouter|11434)' "$STUB_CALL_LOG" | grep -q .; then fail "algún valor auxiliar nuevo apunta a un proveedor fijo"; return 1; fi
  _ol_marker_exists || { fail "sin marcador tras migrar todo"; return 1; }
  assert_file_contains "$STATE_FILE" "ollama" || return 1
  assert_not_contains "$(_ol_dialog_text)" "migración incompleta" || return 1
}

test_ollama_leaves_user_custom_aux_pins_alone_and_lists_them() {
  _ol_setup
  _ol_seed_hermes
  { printf 'auxiliary:\n'; _ol_aux_block_local $(_ol_all_but vision); printf '  vision:\n    provider: openrouter\n    model: google/gemini-3-flash\n'; } >> "$APPDATA_ROOT/hermes/config.yaml"
  echo "no" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "auxiliary.vision" "no pisa la decisión del usuario" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.compression.provider\tauto' || return 1
  assert_contains "$(_ol_dialog_text)" "vision (openrouter/google/gemini-3-flash)" "el mensaje final la lista" || return 1
  assert_contains "$(_ol_dialog_text)" "valores propios que NO se tocaron" || return 1
  assert_file_contains "$STATE_FILE" "ollama" || return 1
}

test_ollama_with_aux_marker_present_does_not_touch_auxiliary() {
  _ol_setup
  _ol_seed_hermes empty
  # El módulo 'hermes' ya dejó el marcador; el usuario fijó 'vision' a mano después.
  _ol_secret_unlock; printf '# listo\n# aux-version: 2 (reasoning_effort none en compression y title_generation)\n' > "$SECRETS_DIR/hermes-aux-auto"; chmod 0600 "$SECRETS_DIR/hermes-aux-auto"; _ol_secret_lock
  { printf 'auxiliary:\n  vision:\n    provider: openrouter\n    model: qwen/qwen3.7-flash\n'; } >> "$APPDATA_ROOT/hermes/config.yaml"
  : > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary' "respeta la decisión posterior del usuario" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary' || return 1
  assert_file_contains "$STATE_FILE" "ollama" || return 1
}

test_ollama_legacy_marker_means_integrated_and_is_replaced() {
  _ol_setup
  _ol_seed_hermes empty
  printf 'providers:\n  ollama-local:\n    api: http://10.213.144.9:11434/v1\n    request_timeout_seconds: 7200\n' >> "$APPDATA_ROOT/hermes/config.yaml"
  _ol_secret_unlock; printf '# migrado\n' > "$SECRETS_DIR/hermes-aux-migrated"; chmod 0600 "$SECRETS_DIR/hermes-aux-migrated"; _ol_secret_lock
  : > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tproviders.ollama-local.api' "refresca la URL" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "request_timeout_seconds" "no pisa los tiempos del usuario" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "reasoning_overrides" || return 1
  _ol_file_exists hermes-ollama-integrated || { fail "falta el marcador nuevo"; return 1; }
  _ol_file_exists hermes-aux-migrated && { fail "el marcador heredado debía borrarse"; return 1; }
  _ol_marker_exists || { fail "falta el marcador de auxiliares"; return 1; }
}

test_ollama_aux_previous_settings_recorded_once_and_shown() {
  _ol_setup
  _ol_seed_hermes
  printf 'auxiliary:\n  vision:\n    provider: openrouter\n    model: qwen/qwen3.7-flash\n  compression:\n    provider: openrouter\n    model: qwen/qwen3.7-flash\n    timeout: 120\napprovals:\n  mode: manual\n' >> "$APPDATA_ROOT/hermes/config.yaml"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  local f="$SECRETS_DIR/hermes-aux-previous.conf"
  assert_file_contains "$STUB_CALL_LOG" $'install\t-m\t0600\t-o\troot\t-g\troot\t/dev/null\t'"${f}.tmp." || return 1
  _ol_secret_unlock
  assert_file_contains "$f" "provider: openrouter" || { _ol_secret_lock; return 1; }
  assert_file_contains "$f" "compression:" || { _ol_secret_lock; return 1; }
  assert_file_not_contains "$f" "approvals" "solo el bloque auxiliary" || { _ol_secret_lock; return 1; }
  local before; before="$(< "$f")"
  _ol_secret_lock
  local texts; texts="$(_ol_dialog_text)"
  assert_contains "$texts" "vision: openrouter/qwen/qwen3.7-flash" "el mensaje final lista los valores previos" || return 1
  assert_contains "$texts" "compression: openrouter/qwen/qwen3.7-flash" || return 1
  assert_contains "$texts" "$f" || return 1
  # Una re-ejecución (sin marcador, con tareas que aún hay que pasar) NO pisa el registro original.
  sed -i '/^ollama$/d' "$STATE_FILE"
  _ol_secret_unlock; rm -f "$SECRETS_DIR/hermes-aux-auto"; _ol_secret_lock
  printf 'auxiliary:\n  mcp:\n    provider: custom\n    model: gemma4:e2b\n    base_url: http://10.213.144.9:11434/v1\n' >> "$APPDATA_ROOT/hermes/config.yaml"
  : > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  _ol_secret_unlock
  assert_eq "$before" "$(< "$f")" "registro original intacto" || { _ol_secret_lock; return 1; }
  _ol_secret_lock
}

# --- Revisión: mensaje de privacidad ---------------------------------------------------------------

test_ollama_final_message_states_privacy_exceptions_and_no_overclaim() {
  _ol_setup
  _ol_seed_hermes
  echo "no" > "$DIALOG_YESNO_QUEUE"      # se conserva el respaldo
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  local texts; texts="$(_ol_dialog_text)"
  assert_contains "$texts" "Privacidad (alcance real, no es total)" || return 1
  assert_contains "$texts" "las tareas auxiliares de esos mismos chats" "aux local en chats locales" || return 1
  assert_contains "$texts" "todas están en 'auto', o sea usan el modelo del chat" || return 1
  assert_contains "$texts" "NO saltan solas a OpenRouter" "qué pasa si Ollama falla" || return 1
  assert_contains "$texts" "solo puede usar el respaldo automático ('fallback_providers') si está configurado" "con el matiz exacto" || return 1
  assert_contains "$texts" "los chats con el modelo por defecto van a OpenRouter, y también sus tareas auxiliares" "excepción 1" || return 1
  assert_contains "$texts" "herramientas web" "excepción 2: búsqueda web" || return 1
  assert_contains "$texts" "puede reenviarse a OpenRouter y filtrarse" "excepción 3: respaldo conservado" || return 1
  assert_contains "$texts" "Visión" "visión explícita" || return 1
  assert_not_contains "$texts" "no salen de la casa" "sin promesa absoluta" || return 1
  assert_not_contains "$texts" "privacidad total" || return 1
  assert_not_contains "$texts" "con gemma4:e2b" "las auxiliares ya no se fijan a e2b" || return 1
  assert_not_contains "$texts" "19 tareas" || return 1
  # Con el respaldo quitado, lo dice.
  : > "$STUB_CALL_LOG"; sed -i '/^ollama$/d' "$STATE_FILE"
  _ol_seed_hermes
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_contains "$(_ol_dialog_text)" "Respaldo automático quitado" || return 1
}

# --- Migración de las tareas auxiliares: reanudable, completa y sin pisar al usuario ---------

# config.yaml de Hermes con el bloque 'auxiliary:' de las tareas $@ totalmente
# migradas (lo que dejaría la CLI real).
_ol_config_with_local_aux() {
  { printf 'auxiliary:\n'; _ol_aux_block_local "$@"; } >> "$APPDATA_ROOT/hermes/config.yaml"
}
_ol_all_but() {
  local t x
  for t in "${_OL_TASKS[@]}"; do
    for x in "$@"; do [[ "$t" == "$x" ]] && continue 2; done
    printf '%s\n' "$t"
  done
}

# 15 llamadas de proveedor/rutas/overrides (primera integración) preceden a las de las tareas.
test_ollama_aux_failure_midway_is_reported_and_rerun_completes_the_rest() {
  _ol_setup
  _ol_seed_hermes
  _ol_config_with_local_aux "${_OL_TASKS[@]}"
  printf 'no\nno\n' > "$DIALOG_YESNO_QUEUE"
  # 15 base + vision (6: timeout, razonamiento, api_key, base_url, model, provider) = 21; la 22 es la
  # primera de compression.
  export STUB_HERMES_CONFIG_SET_FAIL_N="22"
  if bash "$REPO_ROOT/modules/ollama.sh"; then fail "debió terminar con error si la migración quedó incompleta"; return 1; fi
  unset STUB_HERMES_CONFIG_SET_FAIL_N
  local texts; texts="$(_ol_dialog_text)"
  assert_contains "$texts" "migración incompleta: 1 de 19 tareas auxiliares quedaron sin pasar a 'auto' o a medias" || return 1
  assert_contains "$texts" "compression: custom/gemma4:e2b" "dice dónde quedó la tarea" || return 1
  assert_contains "$texts" "vuelva a correr el módulo" || return 1
  # Hermes se reinició igual (proceso = disco), no hay marcadores y el módulo no figura como hecho.
  assert_file_contains "$STUB_CALL_LOG" $'docker\trestart\thermes' || return 1
  _ol_marker_exists && { fail "se escribió el marcador con la migración incompleta"; return 1; }
  _ol_file_exists hermes-ollama-integrated && { fail "marcador de integración con la migración incompleta"; return 1; }
  assert_file_not_contains "$STATE_FILE" "ollama" "no se marca como hecho" || return 1
  # Re-ejecución: la CLI simulada no escribe el archivo, así que se deja el estado que habría quedado
  # (todo en auto menos compression, que sigue fijada).
  : > "$STUB_CALL_LOG"
  _ol_seed_hermes
  { printf 'auxiliary:\n'; _ol_aux_block_local compression
    local t; for t in $(_ol_all_but compression); do printf '  %s:\n    provider: auto\n    model: ""\n' "$t"; done; } >> "$APPDATA_ROOT/hermes/config.yaml"
  printf 'no\nno\n' > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.compression.provider\tauto' "completa la que faltaba" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "auxiliary.vision." "no repite lo ya hecho" || return 1
  _ol_marker_exists || { fail "debió dejar el marcador al completar"; return 1; }
  _ol_file_exists hermes-ollama-integrated || { fail "debió dejar el marcador de integración"; return 1; }
  assert_file_contains "$STATE_FILE" "ollama" "ahora sí figura como hecho" || return 1
  assert_not_contains "$(_ol_dialog_text)" "migración incompleta" || return 1
}

test_ollama_aux_migration_resumes_even_when_provider_already_exists() {
  _ol_setup
  _ol_seed_hermes empty
  # Estado de una primera ejecución interrumpida: el proveedor ya está, las tareas siguen fijadas.
  printf 'providers:\n  ollama-local:\n    api: http://10.213.144.9:11434/v1\n' >> "$APPDATA_ROOT/hermes/config.yaml"
  _ol_config_with_local_aux "${_OL_TASKS[@]}"
  : > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  local t
  for t in "${_OL_TASKS[@]}"; do
    assert_file_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.'"${t}"$'.provider\tauto' "migra $t" || return 1
  done
  # Sin marcador de integración, el proveedor se completa entero (tiempos incluidos).
  assert_file_contains "$STUB_CALL_LOG" "providers.ollama-local.request_timeout_seconds" || return 1
  _ol_marker_exists || { fail "sin marcador tras migrar todo"; return 1; }
}

test_ollama_completed_migration_respects_task_pinned_again_by_the_user() {
  _ol_setup
  _ol_seed_hermes empty
  _ol_config_with_local_aux "${_OL_TASKS[@]}"
  : > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  _ol_marker_exists || { fail "primera migración sin marcador"; return 1; }
  # El usuario volvió a fijar 'vision' a OpenRouter (con el mismo modelo que el HLI usaba antes).
  : > "$STUB_CALL_LOG"
  sed -i '/^ollama$/d' "$STATE_FILE"
  _ol_seed_hermes empty
  printf 'auxiliary:\n  vision:\n    provider: openrouter\n    model: qwen/qwen3.7-flash\n' >> "$APPDATA_ROOT/hermes/config.yaml"
  export HLI2_OLLAMA_IP="10.213.144.77"
  : > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  unset HLI2_OLLAMA_IP
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary' "no pisa la decisión del usuario" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tunset\tauxiliary' || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tproviders.ollama-local.api\thttp://10.213.144.77:11434/v1' "refresca la URL del proveedor" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "reasoning_overrides" "solo URL" || return 1
  assert_file_contains "$STATE_FILE" "ollama" || return 1
}

test_ollama_aux_migration_aborts_if_previous_values_cannot_be_saved() {
  _ol_setup
  _ol_seed_hermes
  printf 'auxiliary:\n  vision:\n    provider: openrouter\n    model: qwen/qwen3.7-flash\n' >> "$APPDATA_ROOT/hermes/config.yaml"
  printf 'no\n' > "$DIALOG_YESNO_QUEUE"
  export STUB_SUDO_TEE_FAIL_TARGET="$SECRETS_DIR/hermes-aux-previous.conf"
  if bash "$REPO_ROOT/modules/ollama.sh"; then fail "debió terminar con error"; return 1; fi
  unset STUB_SUDO_TEE_FAIL_TARGET
  assert_file_not_contains "$STUB_CALL_LOG" $'config\tset\tauxiliary.' "no toca las auxiliares sin registro previo" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'config\tset\tproviders.ollama-local.api' "el proveedor sí se configura" || return 1
  assert_contains "$(_ol_dialog_text)" "no se pudo guardar el registro de sus valores previos" || return 1
  assert_contains "$(_ol_dialog_text)" "migración incompleta: 3 de 3" || return 1
  _ol_marker_exists && { fail "marcador sin migrar"; return 1; }
  assert_file_not_contains "$STATE_FILE" "ollama" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'docker\trestart\thermes' "Hermes se reinicia igual" || return 1
}

test_ollama_interrupt_during_config_prints_incomplete_note_and_exits() {
  _ol_setup
  _ol_seed_hermes
  _ol_config_with_local_aux "${_OL_TASKS[@]}"
  printf 'no\nno\n' > "$DIALOG_YESNO_QUEUE"
  export STUB_HERMES_CONFIG_SET_INT_N=22 STUB_HERMES_CONFIG_SET_SIGNAL=TERM
  local rc=0
  bash "$REPO_ROOT/modules/ollama.sh" || rc=$?
  unset STUB_HERMES_CONFIG_SET_INT_N STUB_HERMES_CONFIG_SET_SIGNAL
  assert_eq "130" "$rc" "sale con 130" || return 1
  local texts; texts="$(_ol_dialog_text)"
  assert_contains "$texts" "Se interrumpió la configuración de Hermes" || return 1
  assert_contains "$texts" "migración incompleta:" "mismo aviso que un fallo" || return 1
  assert_contains "$texts" "vuelva a correr el módulo" || return 1
  assert_file_contains "$STUB_CALL_LOG" $'docker\trestart\thermes' "reinicia Hermes para que coincida con el disco" || return 1
  _ol_marker_exists && { fail "marcador tras interrupción"; return 1; }
  assert_file_not_contains "$STATE_FILE" "ollama" || return 1
  # Dejó de configurar apenas llegó la señal.
  if (( $(grep -cP '^docker\t.*config\t(set|unset)\t' "$STUB_CALL_LOG") > 22 )); then fail "siguió configurando tras la interrupción"; return 1; fi
}

# --- Escritura de archivos root: siempre 'sudo -n' y sin restos ------------------------------

test_ollama_root_write_uses_sudo_n_and_cleans_stale_temporaries() {
  _ol_setup
  local f="$SECRETS_DIR/hermes-egress-allow.conf"
  # Resto de una escritura interrumpida de otro proceso.
  _ol_secret_unlock
  printf 'viejo\n' > "$f.tmp.99999"
  ( source "$REPO_ROOT/modules/hermes.sh"; _hermes_allow_add "${_OL_IP}:11434/tcp" "$_OL_SUBNET" ) || return 1
  _ol_secret_unlock
  [[ ! -e "$f.tmp.99999" ]] || { _ol_secret_lock; fail "no limpió el temporal huérfano"; return 1; }
  assert_file_contains "$f" "${_OL_IP}:11434/tcp" || { _ol_secret_lock; return 1; }
  _ol_secret_lock
  # Ninguna operación privilegiada sin -n.
  if grep -E $'^sudo\t(install|tee|mv|rm)\t' "$STUB_CALL_LOG" | grep -q .; then fail "una escritura privilegiada corrió sin 'sudo -n'"; return 1; fi
  assert_file_contains "$STUB_CALL_LOG" $'sudo\t-n\tinstall\t-m\t0600\t-o\troot\t-g\troot\t/dev/null\t'"$f.tmp." || return 1
}
