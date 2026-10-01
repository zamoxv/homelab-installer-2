#!/usr/bin/env bash
# Test end-to-end de modules/vaultwarden.sh: corre el módulo REAL (no una
# función mockeada) con todo lo privilegiado/de red stubbeado (PATH-stubs de
# tests/stubs), y comprueba:
#   1. El módulo termina en éxito y marca 'vaultwarden' hecho.
#   2. El ADMIN_TOKEN queda guardado como hash Argon2id PHC en
#      /etc/hli2/vaultwarden.env (real, en el scratch), root-only.
#   3. Ese hash llega al campo "env" del compose.create/update de Dokploy
#      (STUB_HTTP_BODIES_LOG) — el canal de secretos funciona de punta a
#      punta.
#   4. La CONTRASEÑA tipeada por el usuario nunca aparece como argumento de
#      ningún proceso real invocado (STUB_CALL_LOG: docker/curl/jq/sudo/
#      argon2) — solo viaja por stdin hacia 'argon2' (ver tests/stubs/
#      argon2) y por la cola file-based de tests/stubs/dialog
#      (DIALOG_PASSWORDBOX_QUEUE), nunca por argv.
#   5. El compose renderizado y enviado a Dokploy usa "${ADMIN_TOKEN}"
#      (sustitución de Dokploy), nunca el valor real, embebido.
#
# HALLAZGO (validado en hardware real, Ubuntu 24.04.5) que motivó reescribir
# este módulo y estos tests: la versión anterior generaba el ADMIN_TOKEN
# corriendo 'docker run --rm -it vaultwarden/server /vaultwarden hash' (esa
# CLI exige una tty real) heredando la terminal del módulo. En el servidor
# real el prompt de contraseña nunca apareció y las teclas tipeadas se
# mostraban en eco en la terminal local sin llegar al contenedor: el módulo
# quedaba colgado. Se abandonó el contenedor interactivo: la contraseña
# ahora se pide con password_box (dialog --passwordbox, TUI propia del HLI,
# mismo patrón que _adguard_ensure_admin_user en modules/adguard.sh) y el
# hash se genera con la CLI 'argon2' de Ubuntu, contraseña SOLO por stdin.
# Ver el comentario de cabecera de _vaultwarden_ensure_admin_token en
# modules/vaultwarden.sh para el detalle completo (causa probable del
# cuelgue, parámetros del preset "Bitwarden", y por qué la sal usa 16 bytes
# y no los 32 del ejemplo de la wiki de Vaultwarden).
#
# Regex completa de un PHC Argon2id (la misma que usa modules/vaultwarden.sh,
# anclada a AMBOS lados): se repite acá para poder afirmar "el hash
# guardado tiene la forma COMPLETA correcta", no solo "contiene $argon2id$".
PHC_REGEX='^\$argon2id\$v=[0-9]+\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$'

# Contraseña de prueba usada en varios tests de abajo: 12 caracteres, pasa el
# mínimo de 8. Nunca debe aparecer en STUB_CALL_LOG (solo en la cola de
# dialog y por stdin hacia argon2, ninguno de los dos pasa por argv de un
# proceso logueado).
TEST_PASSWORD="SuperSecret1"

test_vaultwarden_deploy_ok() {
  harness_mark_canary_done

  echo "vault.example.com" > "$DIALOG_INPUTBOX_QUEUE"
  {
    echo "$TEST_PASSWORD"
    echo "$TEST_PASSWORD"
  } > "$DIALOG_PASSWORDBOX_QUEUE"

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
  # (docker/curl/jq/sudo/argon2) — solo debe existir en el log de BODIES (que
  # lee contenido de archivo, no argv) y en el propio secret_file.
  assert_file_not_contains "$STUB_CALL_LOG" "$hash" "el hash nunca debe estar en argv de ningún proceso" || return 1

  # La CONTRASEÑA tipeada tampoco debe aparecer nunca en argv: solo viajó por
  # stdin hacia 'argon2' (ver tests/stubs/argon2, que la descarta con 'cat
  # >/dev/null') y por la cola file-based de 'dialog' (DIALOG_PASSWORDBOX_QUEUE,
  # no es un proceso logueado en STUB_CALL_LOG).
  assert_file_not_contains "$STUB_CALL_LOG" "$TEST_PASSWORD" "la contraseña nunca en argv de ningún proceso" || return 1

  # El token de la API de Dokploy tampoco debe aparecer nunca en ningún argv.
  assert_file_not_contains "$STUB_CALL_LOG" "test-token-abc123" "el token de la API nunca en argv" || return 1

  # Ya NO se corre 'docker run ... /vaultwarden hash' en absoluto (el
  # contenedor interactivo se abandonó, ver el hallazgo de cabecera).
  # Chequeo preciso con grep -P anclado por tabs (NUNCA un substring plano
  # como "vaultwarden/server": ESE texto SÍ aparece legítimamente en el log,
  # embebido dentro del compose YAML que se le pasa a 'jq' para armar el
  # body de compose.create/update — mismo patrón que ya usaba
  # test_vaultwarden_redeploy_reuses_token más abajo).
  if grep -qP '^docker\trun\t--rm\t-it\tvaultwarden/server\t/vaultwarden\thash' "$STUB_CALL_LOG" 2>/dev/null; then
    fail "no debe invocarse 'docker run --rm -it vaultwarden/server /vaultwarden hash' en absoluto"
    return 1
  fi

  # Se configuró un dominio en Traefik vía la API (domain.create).
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "vault.example.com" "dominio enviado a domain.create" || return 1

  # SIGNUPS_ALLOWED=false: registro público deshabilitado por decisión de
  # v2.3 (ver ROADMAP.md).
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "SIGNUPS_ALLOWED=false" "signups deshabilitados en el compose" || return 1
}

# Contraseña de menos de 8 caracteres: el módulo debe abortar SIN guardar
# nada y SIN marcar el módulo como hecho (mismo criterio que
# _adguard_ensure_admin_user: nunca se persiste un secreto a medio
# configurar).
test_vaultwarden_password_too_short_aborts() {
  harness_mark_canary_done

  echo "vault.example.com" > "$DIALOG_INPUTBOX_QUEUE"
  echo "short1" > "$DIALOG_PASSWORDBOX_QUEUE"   # 6 caracteres, < 8

  if bash "$REPO_ROOT/modules/vaultwarden.sh"; then
    fail "el módulo debió abortar con una contraseña de menos de 8 caracteres"
    return 1
  fi

  assert_file_not_contains "$STATE_FILE" "vaultwarden" "no debe marcarse hecho" || return 1

  ( source "$REPO_ROOT/lib/core.sh"; secret_file_exists vaultwarden ) \
    && { fail "no debió guardarse ningún ADMIN_TOKEN"; return 1; }

  return 0
}

# Las dos contraseñas no coinciden: abortar SIN guardar nada y SIN marcar el
# módulo como hecho.
test_vaultwarden_password_mismatch_aborts() {
  harness_mark_canary_done

  echo "vault.example.com" > "$DIALOG_INPUTBOX_QUEUE"
  {
    echo "$TEST_PASSWORD"
    echo "OtraContraseña2"
  } > "$DIALOG_PASSWORDBOX_QUEUE"

  if bash "$REPO_ROOT/modules/vaultwarden.sh"; then
    fail "el módulo debió abortar con contraseñas que no coinciden"
    return 1
  fi

  assert_file_not_contains "$STATE_FILE" "vaultwarden" "no debe marcarse hecho" || return 1

  ( source "$REPO_ROOT/lib/core.sh"; secret_file_exists vaultwarden ) \
    && { fail "no debió guardarse ningún ADMIN_TOKEN"; return 1; }

  assert_file_not_contains "$STUB_CALL_LOG" "$TEST_PASSWORD" "la contraseña nunca en argv, ni siquiera al abortar" || return 1

  return 0
}

# Redeploy: si ya hay un ADMIN_TOKEN guardado, el módulo NO debe volver a
# pedirlo (ni tocar 'argon2'/docker para regenerarlo) — reutiliza el
# existente.
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

  # No debe haber invocado 'argon2' en absoluto (ni 'docker run ...
  # vaultwarden/server', que ya no existe como camino posible). Chequeo
  # preciso con grep -P anclado por tabs, no un substring plano: "vaultwarden/
  # server" SÍ aparece legítimamente en el log, embebido dentro del compose
  # YAML que se le pasa a 'jq' para el body de compose.create/update.
  if grep -qP '^argon2\t' "$STUB_CALL_LOG" 2>/dev/null; then
    fail "se re-generó el ADMIN_TOKEN aunque ya había uno y el usuario dijo que no"
    return 1
  fi
  if grep -qP '^docker\trun\t--rm\t-it\tvaultwarden/server\t/vaultwarden\thash' "$STUB_CALL_LOG" 2>/dev/null; then
    fail "tampoco debe tocar docker para el hash"
    return 1
  fi

  assert_file_contains "$STUB_HTTP_BODIES_LOG" 'existente$yaguardado' "reutilizó el hash existente" || return 1
}

# Validado en la X230: Dokploy agrega las etiquetas de Traefik de un dominio
# "durante la fase de despliegue" (docs: core/docker-compose/domains). El
# módulo creaba el dominio DESPUÉS de desplegar, así que Traefik nunca
# conocía la ruta (404). domain.create debe ir antes de compose.deploy.
test_vaultwarden_domain_created_before_deploy() {
  harness_mark_canary_done
  echo "vault.casa.lan" > "$DIALOG_INPUTBOX_QUEUE"
  { echo "ClaveSegura123"; echo "ClaveSegura123"; } > "$DIALOG_PASSWORDBOX_QUEUE"
  bash "$REPO_ROOT/modules/vaultwarden.sh" || { fail "el módulo falló"; return 1; }

  local domain_line deploy_line
  domain_line="$(grep -n '^>>> POST .*domain\.create' "$STUB_HTTP_BODIES_LOG" | head -1 | cut -d: -f1)"
  deploy_line="$(grep -n '^>>> POST .*compose\.deploy' "$STUB_HTTP_BODIES_LOG" | tail -1 | cut -d: -f1)"
  [[ -n "$domain_line" && -n "$deploy_line" ]] || { fail "faltan llamadas: domain=[$domain_line] deploy=[$deploy_line]"; return 1; }
  (( domain_line < deploy_line )) || { fail "domain.create (línea $domain_line) va después de compose.deploy (línea $deploy_line)"; return 1; }
}
