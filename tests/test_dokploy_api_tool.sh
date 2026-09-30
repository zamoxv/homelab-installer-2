#!/usr/bin/env bash
# Herramienta "Configurar API de Dokploy" (modules/dokploy-api.sh): si el
# token nuevo no funciona, se conserva la configuración anterior.

_write_previous_config() {
  ( source "$REPO_ROOT/lib/core.sh"
    printf 'DOKPLOY_URL=http://10.0.0.1:3000\nDOKPLOY_TOKEN=tokenAnterior123\n' \
      | sudo tee "$DOKPLOY_ENV_FILE" >/dev/null )
}

_read_token() {
  ( source "$REPO_ROOT/lib/core.sh"; _dokploy_env_get DOKPLOY_TOKEN )
}

test_dokploy_api_tool_rejected_token_keeps_previous() {
  _write_previous_config
  printf '192.168.1.20\n3000\n' > "$DIALOG_INPUTBOX_QUEUE"
  echo "tokenNuevoMalo456" > "$DIALOG_PASSWORDBOX_QUEUE"

  if STUB_CURL_REJECT_TOKEN="tokenNuevoMalo456" bash "$REPO_ROOT/modules/dokploy-api.sh"; then
    fail "debería fallar si Dokploy rechaza el token"
    return 1
  fi
  assert_eq "tokenAnterior123" "$(_read_token)" "se conserva el token anterior" || return 1
}

test_dokploy_api_tool_valid_token_replaces_previous() {
  _write_previous_config
  printf '192.168.1.20\n3000\n' > "$DIALOG_INPUTBOX_QUEUE"
  echo "tokenNuevoBueno789" > "$DIALOG_PASSWORDBOX_QUEUE"

  bash "$REPO_ROOT/modules/dokploy-api.sh" || { fail "debería aceptar un token válido"; return 1; }
  assert_eq "tokenNuevoBueno789" "$(_read_token)" "queda el token nuevo" || return 1
}
