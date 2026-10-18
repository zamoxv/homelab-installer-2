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
  HLI2_IPTABLES="$STUBS_DIR/iptables" bash "$HLI2_HERMES_SBIN_DIR/hli2-hermes-egress" "$action" 2>"$HLI2_TEST_SCRATCH/egress.err" || rc=$?
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
    echo "  10.213.144.22:8080/udp  # con espacios y comentario"
  } > "$SECRETS_DIR/hermes-egress-allow.conf"
  _ol_secret_lock
  : > "$STUB_CALL_LOG"
  _ol_run_egress apply || return 1
  local ipt; ipt="$(_ol_ipt_calls)"
  local chain
  for chain in FWD IN; do
    assert_contains "$ipt" $'-A\tHLI2-HERMES-'"${chain}"$'-new\t-d\t'"${_OL_IP}"$'\t-p\ttcp\t--dport\t11434\t-j\tACCEPT' "excepción en ${chain}" || return 1
    assert_contains "$ipt" $'-A\tHLI2-HERMES-'"${chain}"$'-new\t-d\t10.213.144.22\t-p\tudp\t--dport\t8080\t-j\tACCEPT' "línea con espacios y comentario" || return 1
  done
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

test_ollama_egress_script_without_allow_file_adds_no_exceptions() {
  _ol_setup
  _ol_seed_hermes
  : > "$STUB_CALL_LOG"
  _ol_run_egress apply || return 1
  # Solo DNS (puerto 53): ninguna otra regla con --dport.
  if _ol_ipt_calls | grep -F -- $'--dport' | grep -vF -- $'--dport\t53\t' | grep -q .; then fail "hay reglas con --dport (salvo DNS) sin archivo de excepciones"; return 1; fi
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
  assert_contains "$(_ol_dialog_text)" "Se quitó el respaldo automático" || return 1
  assert_contains "$(_ol_dialog_text)" "global" "explica por qué" || return 1

  # Rechazado: no se toca y se avisa claramente.
  : > "$STUB_CALL_LOG"
  sed -i '/^ollama$/d' "$STATE_FILE"
  echo "no" > "$DIALOG_YESNO_QUEUE"
  bash "$REPO_ROOT/modules/ollama.sh" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" $'fallback\tclear' "no se tocó el respaldo" || return 1
  assert_contains "$(_ol_dialog_text)" "AVISO: el respaldo automático hacia OpenRouter sigue activo" || return 1
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
  assert_eq "gemma4-e4b-local" "$( ( source "$REPO_ROOT/modules/ollama.sh"; _ollama_alias gemma4:e4b ) )" || return 1
  assert_eq "gemma4-e2b-local" "$( ( source "$REPO_ROOT/modules/ollama.sh"; _ollama_alias gemma4:e2b ) )" || return 1
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
