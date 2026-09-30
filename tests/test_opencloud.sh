#!/usr/bin/env bash
# Test end-to-end de modules/opencloud.sh: dominio + INITIAL_ADMIN_PASSWORD
# como secreto (canal "env" de Dokploy, igual que Vaultwarden), y que el
# valor nunca aparece en argv de ningún proceso real.

test_opencloud_deploy_ok() {
  harness_mark_canary_done

  echo "cloud.example.com" > "$DIALOG_INPUTBOX_QUEUE"
  {
    echo 'Super$ecreta123!'
    echo 'Super$ecreta123!'
  } > "$DIALOG_PASSWORDBOX_QUEUE"

  bash "$REPO_ROOT/modules/opencloud.sh" || return 1

  assert_file_contains "$STATE_FILE" "opencloud" "mark_done opencloud" || return 1

  # NUNCA '[[ -f "$SECRETS_DIR/opencloud.env" ]]' directo: /etc/hli2 (acá
  # simulado por STUB_ROOT_AREA) es root-only también en el test —
  # exactamente lo que exige la ronda 2 de revisión de seguridad. Hay que
  # leerlo con la función real (usa 'sudo -n' por dentro), igual que en
  # tests/test_vaultwarden.sh.
  local pass
  pass="$( ( source "$REPO_ROOT/lib/core.sh"; secret_get opencloud INITIAL_ADMIN_PASSWORD ) )" || return 1
  assert_eq 'Super$ecreta123!' "$pass" "contraseña guardada" || return 1

  # Entre comillas simples en el env: Compose no interpola '$' dentro de
  # comillas simples en .env (un '$ecreta' sin comillas se perdería).
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "INITIAL_ADMIN_PASSWORD='Super\$ecreta123!'" "contraseña entre comillas simples en el env" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" '${INITIAL_ADMIN_PASSWORD}' "compose usa la referencia, no un literal" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "cloud.example.com" "dominio enviado a domain.create" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "opencloudeu/opencloud-rolling" "imagen oficial" || return 1

  assert_file_not_contains "$STUB_CALL_LOG" 'Super$ecreta123!' "la contraseña nunca en argv de ningún proceso" || return 1
}

# Contraseñas que no coinciden: el módulo debe cancelar sin guardar nada.
test_opencloud_password_mismatch_aborts() {
  harness_mark_canary_done

  echo "cloud.example.com" > "$DIALOG_INPUTBOX_QUEUE"
  {
    echo "Password111!"
    echo "Password222!"
  } > "$DIALOG_PASSWORDBOX_QUEUE"

  if bash "$REPO_ROOT/modules/opencloud.sh"; then
    fail "el módulo no debería terminar en éxito si las contraseñas no coinciden"
    return 1
  fi

  ( source "$REPO_ROOT/lib/core.sh"; secret_file_exists opencloud ) \
    && { fail "no debería haber guardado ningún secreto"; return 1; }
  assert_file_not_contains "$STATE_FILE" "opencloud" "no debe marcarse hecho si se canceló" || return 1
}

# Una comilla simple no se puede representar dentro de un valor entre
# comillas simples en .env: el módulo debe rechazarla al ingresarla.
test_opencloud_password_with_single_quote_rejected() {
  harness_mark_canary_done

  echo "cloud.example.com" > "$DIALOG_INPUTBOX_QUEUE"
  {
    echo "Clave'Mala123"
    echo "Clave'Mala123"
  } > "$DIALOG_PASSWORDBOX_QUEUE"

  if bash "$REPO_ROOT/modules/opencloud.sh"; then
    fail "el módulo no debería aceptar una contraseña con comilla simple"
    return 1
  fi
  ( source "$REPO_ROOT/lib/core.sh"; secret_file_exists opencloud ) \
    && { fail "no debería haber guardado ningún secreto"; return 1; }
  return 0
}
