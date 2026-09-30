#!/usr/bin/env bash
# Test end-to-end de modules/vaultwarden.sh: corre el módulo REAL (no una
# función mockeada) con todo lo privilegiado/de red stubbeado (PATH-stubs de
# tests/stubs), y comprueba:
#   1. El módulo termina en éxito y marca 'vaultwarden' hecho.
#   2. El ADMIN_TOKEN queda guardado como hash Argon2id PHC en
#      /etc/hli2/vaultwarden.env (real, en el scratch), root-only, SIN
#      ningún '\r' colado (CRÍTICO 2, ronda 2 de revisión — ver
#      test_vaultwarden_admin_token_strips_pty_carriage_return más abajo).
#   3. Ese hash llega al campo "env" del compose.create/update de Dokploy
#      (STUB_HTTP_BODIES_LOG) — el canal de secretos funciona de punta a
#      punta.
#   4. El hash NUNCA aparece como argumento de ningún proceso real invocado
#      (STUB_CALL_LOG: docker/curl/jq/sudo) — ni el token de la API de
#      Dokploy tampoco.
#   5. El compose renderizado y enviado a Dokploy usa "${ADMIN_TOKEN}"
#      (sustitución de Dokploy), nunca el valor real, embebido.
#
# Regex completa de un PHC Argon2id (la misma que usa modules/vaultwarden.sh,
# anclada a AMBOS lados): se repite acá para poder afirmar "el hash
# guardado tiene la forma COMPLETA correcta", no solo "contiene $argon2id$".
PHC_REGEX='^\$argon2id\$v=[0-9]+\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$'

test_vaultwarden_deploy_ok() {
  harness_mark_canary_done

  echo "vault.example.com" > "$DIALOG_INPUTBOX_QUEUE"

  bash "$REPO_ROOT/modules/vaultwarden.sh" || return 1

  assert_file_contains "$STATE_FILE" "vaultwarden" "mark_done vaultwarden" || return 1

  local hash
  hash="$( ( source "$REPO_ROOT/lib/core.sh"; secret_get vaultwarden ADMIN_TOKEN ) )" || return 1
  [[ "$hash" =~ $PHC_REGEX ]] || { fail "hash guardado no tiene la forma PHC completa: [$hash]"; return 1; }

  # El hash llegó al body real que se mandó a compose.create/update.
  # Entre comillas simples en el env: Compose interpolaría '$argon2id', '$v',
  # '$m'... de un valor sin comillas y el token llegaría roto.
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "ADMIN_TOKEN='${hash}'" "hash entre comillas simples en el env" || return 1

  # El compose renderizado (dentro del body JSON) referencia la variable,
  # nunca un valor embebido.
  assert_file_contains "$STUB_HTTP_BODIES_LOG" '${ADMIN_TOKEN}' "compose usa la referencia, no un literal" || return 1

  # El hash NUNCA aparece en el log de argv de ningún proceso real
  # (docker/curl/jq/sudo) — solo debe existir en el log de BODIES (que lee
  # contenido de archivo, no argv) y en el propio secret_file.
  assert_file_not_contains "$STUB_CALL_LOG" "$hash" "el hash nunca debe estar en argv de ningún proceso" || return 1

  # El token de la API de Dokploy tampoco debe aparecer nunca en ningún argv.
  assert_file_not_contains "$STUB_CALL_LOG" "test-token-abc123" "el token de la API nunca en argv" || return 1

  # Se configuró un dominio en Traefik vía la API (domain.create).
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "vault.example.com" "dominio enviado a domain.create" || return 1

  # SIGNUPS_ALLOWED=false: registro público deshabilitado por decisión de
  # v2.3 (ver ROADMAP.md).
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "SIGNUPS_ALLOWED=false" "signups deshabilitados en el compose" || return 1
}

# CRÍTICO 2 (ronda 2 de revisión): el stub de 'docker' (tests/stubs/docker)
# emite la línea "ADMIN_TOKEN=..." terminada en '\r\n', reproduciendo lo que
# hace de verdad un 'docker run -it' (pty con ONLCR). Si modules/
# vaultwarden.sh no limpiara ese '\r' (o si la validación solo anclara el
# PRINCIPIO de la regex, como en la versión anterior), este test fallaría:
# el hash guardado/enviado terminaría con un '\r' colado que nunca
# coincidiría con el hash real que compara Vaultwarden, dejando el login de
# /admin roto.
test_vaultwarden_admin_token_strips_pty_carriage_return() {
  harness_mark_canary_done

  echo "vault.example.com" > "$DIALOG_INPUTBOX_QUEUE"

  bash "$REPO_ROOT/modules/vaultwarden.sh" || return 1

  local hash
  hash="$( ( source "$REPO_ROOT/lib/core.sh"; secret_get vaultwarden ADMIN_TOKEN ) )" || return 1

  case "$hash" in
    *$'\r'*)
      fail "el hash guardado contiene un '\\r' (no se limpió la salida de la pty de 'docker run -it')"
      return 1
      ;;
  esac
  [[ "$hash" =~ $PHC_REGEX ]] || { fail "hash guardado no matchea la regex COMPLETA (¿quedó un '\\r' u otra basura al final?): [$hash]"; return 1; }

  # El valor que de verdad se mandó a Dokploy (el body real, no el argv)
  # tampoco debe llevar el '\r'.
  case "$(cat "$STUB_HTTP_BODIES_LOG")" in
    *"ADMIN_TOKEN=${hash}"$'\r'*)
      fail "el '\\r' llegó hasta el body enviado a Dokploy"
      return 1
      ;;
  esac
}

# Redeploy: si ya hay un ADMIN_TOKEN guardado, el módulo NO debe volver a
# pedirlo (ni tocar docker para regenerarlo) — reutiliza el existente.
test_vaultwarden_redeploy_reuses_token() {
  harness_mark_canary_done

  # Sembrar un secreto YA guardado como lo haría secret_file_write (el
  # directorio queda 000 apenas termina harness_setup_env — ver
  # tests/lib/harness.sh — así que hay que destrabarlo para esta escritura
  # de fixture y volver a trabarlo, igual que hace tests/stubs/sudo
  # alrededor de cada operación privilegiada real).
  chmod u+rwx "$SECRETS_DIR"
  printf 'ADMIN_TOKEN=$argon2id$v=19$m=19456,t=2,p=1$existente$yaguardado\n' > "$SECRETS_DIR/vaultwarden.env"
  chmod 0600 "$SECRETS_DIR/vaultwarden.env"
  chmod 000 "$SECRETS_DIR"

  echo "vault.example.com" > "$DIALOG_INPUTBOX_QUEUE"
  echo "no" > "$DIALOG_YESNO_QUEUE"   # "¿generar uno nuevo?" -> No, reusar

  bash "$REPO_ROOT/modules/vaultwarden.sh" || return 1

  # No debe haber invocado 'docker run ... /vaultwarden hash' en absoluto.
  if grep -qF $'\t/vaultwarden\thash' "$STUB_CALL_LOG" 2>/dev/null; then
    fail "se re-generó el ADMIN_TOKEN aunque ya había uno y el usuario dijo que no"
    return 1
  fi

  assert_file_contains "$STUB_HTTP_BODIES_LOG" 'existente$yaguardado' "reutilizó el hash existente" || return 1
}
