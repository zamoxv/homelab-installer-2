#!/usr/bin/env bash
# Test end-to-end de modules/cloudflared.sh (todo lo privilegiado/de red
# stubbeado). Comprueba: el token nunca viaja por argv ni por logs, queda
# root-only en /etc/hli2/cloudflared.env (simulado), llega a Dokploy por el
# campo "env" entre comillas simples, el compose versionado no lleva el valor
# literal, un token inválido se rechaza con mensaje, cancelar muestra un
# mensaje y una re-ejecución reutiliza el token guardado.

# Token con la forma real: Base64 de {"a":..,"t":..,"s":..} (empieza con eyJ).
_cf_token() {
  printf '{"a":"0123456789abcdef0123456789abcdef","t":"11111111-2222-3333-4444-555555555555","s":"c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0"}' | base64 -w0
}

_cf_dialog_text() { grep -F $'dialog\t' "$STUB_CALL_LOG" || true; }

test_cloudflared_deploy_ok() {
  harness_mark_canary_done
  local token; token="$(_cf_token)"
  echo "$token" > "$DIALOG_PASSWORDBOX_QUEUE"

  bash "$REPO_ROOT/modules/cloudflared.sh" || return 1

  assert_file_contains "$STATE_FILE" "cloudflared" "mark_done" || return 1

  # Guardado root-only, con el valor correcto.
  local f="$SECRETS_DIR/cloudflared.env" mode stored
  mode="$(sudo -n stat -c '%a' -- "$f")" || return 1
  assert_eq "600" "$mode" "modo del archivo de secreto" || return 1
  stored="$( ( source "$REPO_ROOT/lib/core.sh"; secret_get cloudflared TUNNEL_TOKEN ) )" || return 1
  assert_eq "$token" "$stored" "token guardado" || return 1

  # Llega por el campo env, entre comillas simples; el compose usa la referencia.
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "TUNNEL_TOKEN='${token}'" "env con comillas simples" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" '${TUNNEL_TOKEN}' "compose usa la referencia" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "tunnel --no-autoupdate run" "comando del túnel" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "dokploy-network" "red de Dokploy" || return 1

  # El compose versionado no contiene un token literal ni lo renderizado.
  assert_file_not_contains "$REPO_ROOT/compose/cloudflared/docker-compose.yml" "eyJ" "template sin token" || return 1
  local rendered
  rendered="$( ( source "$REPO_ROOT/lib/core.sh"; compose_render_cloudflared ) )" || return 1
  assert_not_contains "$rendered" "eyJ" "render sin token" || return 1
  assert_contains "$rendered" '${TUNNEL_TOKEN}' || return 1

  # Nunca en argv ni en logs.
  assert_file_not_contains "$STUB_CALL_LOG" "$token" "token fuera de argv" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "test-token-abc123" || return 1
  if grep -rqF -- "$token" "$LOG_DIR" 2>/dev/null; then
    fail "el token apareció en $LOG_DIR"; return 1
  fi

  # Mensaje final con las rutas en orden y sin puertos en el router.
  local texts; texts="$(_cf_dialog_text)"
  assert_contains "$texts" 'vault.<dominio>  ruta ^/admin' || return 1
  assert_contains "$texts" 'dokploy-traefik:80' || return 1
  assert_contains "$texts" ':8123' || return 1
  assert_contains "$texts" 'Ningún puerto del router se abre' || return 1
}

test_cloudflared_accepts_pasted_command() {
  harness_mark_canary_done
  local token; token="$(_cf_token)"
  echo "sudo cloudflared service install $token" > "$DIALOG_PASSWORDBOX_QUEUE"
  bash "$REPO_ROOT/modules/cloudflared.sh" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "TUNNEL_TOKEN='${token}'" || return 1
}

test_cloudflared_invalid_token_rejected() {
  harness_mark_canary_done
  local bad
  for bad in "hola" "eyJabc" "$(_cf_token)'; rm -rf /" "eyJ$(printf 'A%.0s' {1..60})"; do
    : > "$STUB_CALL_LOG"
    echo "$bad" > "$DIALOG_PASSWORDBOX_QUEUE"
    if bash "$REPO_ROOT/modules/cloudflared.sh"; then
      fail "aceptó un token inválido: [$bad]"; return 1
    fi
    assert_contains "$(_cf_dialog_text)" "no tiene la forma de un token" "mensaje de rechazo para [$bad]" || return 1
    ( source "$REPO_ROOT/lib/core.sh"; secret_file_exists cloudflared ) \
      && { fail "guardó un token inválido"; return 1; }
    assert_file_not_contains "$STATE_FILE" "cloudflared" || return 1
  done
}

test_cloudflared_cancel_shows_message() {
  harness_mark_canary_done
  : > "$DIALOG_PASSWORDBOX_QUEUE"   # cola vacía = Cancelar
  if bash "$REPO_ROOT/modules/cloudflared.sh"; then
    fail "debió fallar al cancelar"; return 1
  fi
  assert_contains "$(_cf_dialog_text)" "Se cancela el despliegue de Cloudflare Tunnel" || return 1
  assert_file_not_contains "$STATE_FILE" "cloudflared" || return 1
}

test_cloudflared_rerun_reuses_token() {
  harness_mark_canary_done
  local token; token="$(_cf_token)"
  chmod u+rwx "$SECRETS_DIR"
  printf 'TUNNEL_TOKEN=%s\n' "$token" > "$SECRETS_DIR/cloudflared.env"
  chmod 0600 "$SECRETS_DIR/cloudflared.env"
  chmod 000 "$SECRETS_DIR"

  echo "no" > "$DIALOG_YESNO_QUEUE"      # ¿reemplazar? -> No
  : > "$DIALOG_PASSWORDBOX_QUEUE"        # si pidiera token, cancelaría

  bash "$REPO_ROOT/modules/cloudflared.sh" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "TUNNEL_TOKEN='${token}'" "reutilizó el token" || return 1
  if grep -qF -- '--passwordbox' "$STUB_CALL_LOG"; then
    fail "volvió a pedir el token"; return 1
  fi
}

test_cloudflared_rerun_can_replace_token() {
  harness_mark_canary_done
  local old new
  old="$(_cf_token)"
  new="$(printf '{"a":"ffffffffffffffffffffffffffffffff","t":"99999999-2222-3333-4444-555555555555","s":"bm9tYXNub21hc25vbWFzbm9tYXM="}' | base64 -w0)"
  chmod u+rwx "$SECRETS_DIR"
  printf 'TUNNEL_TOKEN=%s\n' "$old" > "$SECRETS_DIR/cloudflared.env"
  chmod 0600 "$SECRETS_DIR/cloudflared.env"
  chmod 000 "$SECRETS_DIR"

  echo "yes" > "$DIALOG_YESNO_QUEUE"
  echo "$new" > "$DIALOG_PASSWORDBOX_QUEUE"
  bash "$REPO_ROOT/modules/cloudflared.sh" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "TUNNEL_TOKEN='${new}'" || return 1
  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" "$old" "no debe quedar el token viejo" || return 1
}
