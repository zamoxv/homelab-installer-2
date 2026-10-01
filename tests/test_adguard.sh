#!/usr/bin/env bash
# Test end-to-end de modules/adguard.sh: corre el módulo REAL (no una
# función mockeada) con todo lo privilegiado/de red stubbeado (PATH-stubs de
# tests/stubs), y comprueba el hallazgo de seguridad validado en hardware
# real (ver el comentario de cabecera de modules/adguard.sh): el YAML
# "sembrado" a mano evita el asistente de instalación de AdGuard, que es
# donde se crea el usuario admin — sin _adguard_ensure_admin_user() el panel
# en :3053 quedaría SIN AUTENTICACIÓN para cualquiera en la LAN.
#
# Regex completa de un bcrypt de 'htpasswd -B' ($2y$<costo 2 dígitos>$<22
# salt + 31 hash base64>), ANCLADA a ambos lados: la misma que usa
# modules/adguard.sh.
BCRYPT_REGEX='^\$2y\$[0-9]{2}\$[A-Za-z0-9./]{53}$'

_adguard_yaml() {
  printf '%s/adguard/conf/AdGuardHome.yaml' "$APPDATA_ROOT"
}

# --- Instalación nueva: pide usuario y contraseña, crea el admin -----------

test_adguard_fresh_install_creates_admin_user() {
  harness_mark_canary_done

  # 1) confirm "¿Importar...?" -> cola de yesno vacía = "no" (default del
  #    stub de dialog cuando la cola está vacía), así que no hace falta
  #    sembrar nada ahí.
  # 2) input_box del usuario admin.
  echo "admin" > "$DIALOG_INPUTBOX_QUEUE"
  # 3) password_box x2 (coinciden).
  {
    echo "Sup3rSecret!"
    echo "Sup3rSecret!"
  } > "$DIALOG_PASSWORDBOX_QUEUE"

  bash "$REPO_ROOT/modules/adguard.sh" || return 1

  assert_file_contains "$STATE_FILE" "adguard" "mark_done adguard" || return 1

  local yaml="$(_adguard_yaml)"
  [[ -f "$yaml" ]] || { fail "no se creó $yaml"; return 1; }

  assert_file_contains "$yaml" "users:" "el YAML quedó con sección users:" || return 1
  assert_file_contains "$yaml" "- name: admin" "el usuario admin quedó en el YAML" || return 1

  local hash
  hash="$(awk '/password:/ { print $2; exit }' "$yaml")"
  [[ "$hash" =~ $BCRYPT_REGEX ]] || { fail "hash guardado no tiene la forma bcrypt completa: [$hash]"; return 1; }

  # http.address/dns.bind_hosts de la siembra original siguen intactos: el
  # agregado del usuario no tiene que pisar el resto del archivo.
  assert_file_contains "$yaml" "0.0.0.0:3053" "panel sigue en 3053" || return 1
  assert_file_contains "$yaml" "bind_hosts:" "dns.bind_hosts sigue presente" || return 1

  # La contraseña NUNCA viajó por argv de ningún proceso real (docker/sudo).
  assert_file_not_contains "$STUB_CALL_LOG" "Sup3rSecret!" "la contraseña nunca debe estar en argv de ningún proceso" || return 1

  # El archivo con el hash queda root-only (0600): endurecido al agregar el
  # usuario, porque $APPDATA_ROOT es 0755 (storage.sh/dokploy.sh) y sin esto
  # cualquier usuario local del host podría leer el hash del disco.
  local mode
  mode="$(sudo -n stat -c '%a' -- "$yaml")" || { fail "no se pudo leer el modo de $yaml"; return 1; }
  assert_eq "600" "$mode" "AdGuardHome.yaml debe quedar en modo 0600 tras crear el usuario" || return 1
}

# --- Config importada con usuarios: nunca pregunta, nunca los pisa ---------

test_adguard_imported_config_preserves_existing_users() {
  harness_mark_canary_done

  local yaml="$(_adguard_yaml)"
  mkdir -p "$(dirname "$yaml")"
  cat > "$yaml" <<'EOF'
http:
  address: 0.0.0.0:3053
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
users:
  - name: existing-admin
    password: $2y$10$existingHashPreservedExactlyAsIsAbcDefGhiJklMnoPqrStu
EOF

  # Cola de yesno vacía ("¿Importar?" -> no) y colas de inputbox/passwordbox
  # vacías A PROPÓSITO: si el módulo llegara a pedir usuario/contraseña
  # (bug), el stub de dialog devolvería "Cancelar" (cola vacía) y el test
  # fallaría por un motivo bien distinto (módulo aborta) a "se pisó el
  # usuario existente" — cualquiera de los dos deja claro que algo está mal.
  bash "$REPO_ROOT/modules/adguard.sh" || return 1

  assert_file_contains "$STATE_FILE" "adguard" "mark_done adguard" || return 1

  # El usuario importado sigue intacto, con el MISMO hash.
  assert_file_contains "$yaml" "existing-admin" "usuario importado preservado" || return 1
  assert_file_contains "$yaml" '$2y$10$existingHashPreservedExactlyAsIsAbcDefGhiJklMnoPqrStu' "hash importado preservado tal cual" || return 1

  # Nunca se mostró un inputbox/passwordbox (no se preguntó nada).
  if grep -qF $'\t--inputbox' "$STUB_CALL_LOG" || grep -qF $'\t--passwordbox' "$STUB_CALL_LOG"; then
    fail "el módulo pidió usuario/contraseña aunque el YAML ya tenía uno importado"
    return 1
  fi

  # Nunca se corrió 'htpasswd' (no se generó un hash nuevo).
  if grep -qF 'htpasswd' "$STUB_CALL_LOG"; then
    fail "se generó un hash nuevo aunque ya había un usuario importado"
    return 1
  fi
}

# --- Contraseñas que no coinciden: aborta, no escribe nada, no marca hecho -

test_adguard_mismatched_passwords_aborts() {
  harness_mark_canary_done

  echo "admin" > "$DIALOG_INPUTBOX_QUEUE"
  {
    echo "PrimeraClave123"
    echo "OtraClaveDistinta456"
  } > "$DIALOG_PASSWORDBOX_QUEUE"

  if bash "$REPO_ROOT/modules/adguard.sh"; then
    fail "el módulo debía abortar con contraseñas que no coinciden"
    return 1
  fi

  assert_file_not_contains "$STATE_FILE" "adguard" "no debe marcarse 'adguard' como hecho" || return 1

  local yaml="$(_adguard_yaml)"
  # La siembra mínima (http/dns, sin usuarios) puede haber quedado escrita
  # -- lo que NUNCA debe pasar es que haya una sección 'users:' con el hash.
  assert_file_not_contains "$yaml" "users:" "no debe haberse escrito ningún usuario" || return 1

  assert_file_not_contains "$STUB_CALL_LOG" "PrimeraClave123" "ninguna contraseña debe llegar a argv" || return 1
  assert_file_not_contains "$STUB_CALL_LOG" "OtraClaveDistinta456" "ninguna contraseña debe llegar a argv" || return 1

  # Nunca se llegó a correr 'htpasswd': el mismatch se detecta ANTES de
  # generar ningún hash.
  if grep -qF 'htpasswd' "$STUB_CALL_LOG"; then
    fail "se corrió htpasswd aunque las contraseñas no coincidían"
    return 1
  fi
}

# --- Contraseña demasiado corta: mismo criterio que el mismatch ------------

test_adguard_short_password_aborts() {
  harness_mark_canary_done

  echo "admin" > "$DIALOG_INPUTBOX_QUEUE"
  echo "corta1" > "$DIALOG_PASSWORDBOX_QUEUE"

  if bash "$REPO_ROOT/modules/adguard.sh"; then
    fail "el módulo debía abortar con una contraseña de menos de 8 caracteres"
    return 1
  fi

  assert_file_not_contains "$STATE_FILE" "adguard" "no debe marcarse 'adguard' como hecho" || return 1

  if grep -qF 'htpasswd' "$STUB_CALL_LOG"; then
    fail "se corrió htpasswd aunque la contraseña era demasiado corta"
    return 1
  fi
}

# Importación desde un backup del v1: el YAML trae el hash de la contraseña
# del panel y debe quedar root-only (0600), igual que en una instalación nueva.
test_adguard_import_v1_yaml_is_0600() {
  local ext="$STUB_SAFE_ROOT/ext-v1"
  mkdir -p "$ext/adguard"
  printf 'http:\n  address: 192.168.1.10:80\nusers:\n  - name: viejo\n    password: $2y$10$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0\ndns:\n  bind_hosts:\n    - 192.168.1.10\n' > "$ext/adguard/AdGuardHome.yaml"
  chmod 0644 "$ext/adguard/AdGuardHome.yaml"

  ( set -euo pipefail; source "$REPO_ROOT/lib/core.sh"; importer_adguard "$ext" ) || { fail "importer_adguard falló"; return 1; }

  local yaml="$APPDATA_ROOT/adguard/conf/AdGuardHome.yaml" mode
  mode="$(stat -c '%a' "$yaml")"
  assert_eq "600" "$mode" "permisos del YAML importado" || return 1
  assert_file_contains "$yaml" "name: viejo" "usuario importado intacto" || return 1
}

# Un usuario cuyas claves vienen en otro orden (password antes que name)
# debe contar como existente: si no, se reemplazaría la lista importada.
test_adguard_has_users_any_key_order() {
  local y="$STUB_SAFE_ROOT/orden.yaml"
  printf 'users:\n  - password: $2y$10$x\n    name: admin\ndns:\n  port: 53\n' > "$y"
  ( source "$REPO_ROOT/lib/core.sh"; adguard_yaml_has_users "$y" ) \
    || { fail "no detectó un usuario con las claves en otro orden"; return 1; }
}
