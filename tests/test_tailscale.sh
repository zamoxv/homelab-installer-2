#!/usr/bin/env bash
# Test de modules/tailscale.sh con apt/curl/tailscale/ss stubbeados. El
# 'tailscale' falso (tests/stubs/fake/tailscale) NO está en el PATH base: los
# tests lo ponen en un directorio propio (o lo "instala" el stub de sudo al
# ver 'apt-get install tailscale').

_ts_env() {
  export TMPDIR="$HLI2_TEST_SCRATCH/tmp"; mkdir -p "$TMPDIR"   # para que 'sudo install' vea el temporal como ruta segura
  export HLI2_TAILSCALE_KEYRING="$HLI2_TEST_SCRATCH/keyrings/tailscale-archive-keyring.gpg"
  export HLI2_TAILSCALE_LIST="$HLI2_TEST_SCRATCH/apt/tailscale.list"
  # Ubuntu 24.04 simulado: el módulo falla cerrado si no puede leer la versión.
  printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' > "$STUB_SAFE_ROOT/os-release-noble"
  export HLI2_OS_RELEASE_FILE="$STUB_SAFE_ROOT/os-release-noble"
  export STUB_TS_STATE="$HLI2_TEST_SCRATCH/ts-state"
  export TS_BIN="$HLI2_TEST_SCRATCH/bin"
}

_ts_texts() { grep -F $'dialog\t' "$STUB_CALL_LOG" || true; }

test_tailscale_installs_via_repo_and_logs_in_foreground() {
  _ts_env
  export STUB_APT_INSTALL_BIN_DIR="$TS_BIN"
  PATH="$TS_BIN:$PATH"
  echo "no" > "$DIALOG_YESNO_QUEUE"    # sin paso de AdGuard

  local out
  out="$(bash "$REPO_ROOT/modules/tailscale.sh" 2>&1)" || { echo "$out"; return 1; }

  # Clave y lista instaladas con el contenido oficial.
  assert_file_contains "$HLI2_TAILSCALE_KEYRING" "FAKE-KEYRING-BYTES" "clave instalada" || return 1
  assert_file_contains "$HLI2_TAILSCALE_LIST" "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main" "lista de fuentes" || return 1

  # Descargas con curl a archivo (nunca 'curl | sh') y orden update -> install.
  assert_file_contains "$STUB_CALL_LOG" "https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg" || return 1
  assert_file_contains "$STUB_CALL_LOG" "https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list" || return 1
  local upd inst
  upd="$(grep -nP '^sudo\tenv\t.*\tupdate' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  inst="$(grep -nP '^sudo\tenv\t.*\tinstall\ttailscale' "$STUB_CALL_LOG" | head -1 | cut -d: -f1)"
  [[ -n "$upd" && -n "$inst" && "$upd" -lt "$inst" ]] || { fail "apt update/install fuera de orden o ausentes ($upd/$inst)"; return 1; }

  # 'tailscale up' corrió, y su salida (URL de login) NO quedó capturada por
  # $(...): llegó al stdout del módulo (primer plano).
  assert_file_contains "$STUB_CALL_LOG" $'tailscale\tup' || return 1
  assert_contains "$out" "https://login.tailscale.com/a/STUBLOGIN" "URL de login visible en la terminal" || return 1
  if rg -n '\$\([^)]*tailscale up' "$REPO_ROOT/modules/tailscale.sh" >/dev/null; then
    fail "tailscale up no debe correr dentro de \$(...)"; return 1
  fi

  assert_contains "$(_ts_texts)" "100.64.0.1" "IP de Tailscale en el resumen" || return 1
  assert_contains "$(_ts_texts)" "homelab.tail1234.ts.net" "nombre MagicDNS" || return 1
  assert_contains "$(_ts_texts)" ":3000" || return 1
  assert_file_contains "$STATE_FILE" "tailscale" || return 1
}

test_tailscale_skips_install_when_present() {
  _ts_env
  mkdir -p "$TS_BIN"; cp "$REPO_ROOT/tests/stubs/fake/tailscale" "$TS_BIN/tailscale"
  PATH="$TS_BIN:$PATH"
  echo "no" > "$DIALOG_YESNO_QUEUE"

  bash "$REPO_ROOT/modules/tailscale.sh" >/dev/null 2>&1 || return 1
  if grep -qP '^curl\t.*pkgs\.tailscale\.com' "$STUB_CALL_LOG"; then fail "descargó el repo aunque ya estaba instalado"; return 1; fi
  if grep -qP '^sudo\tenv\t.*\tinstall\ttailscale' "$STUB_CALL_LOG"; then fail "reinstaló el paquete"; return 1; fi
  assert_file_contains "$STUB_CALL_LOG" $'tailscale\tup' "debe hacer login" || return 1
}

test_tailscale_already_logged_in_only_shows_status() {
  _ts_env
  mkdir -p "$TS_BIN"; cp "$REPO_ROOT/tests/stubs/fake/tailscale" "$TS_BIN/tailscale"
  PATH="$TS_BIN:$PATH"
  echo in > "$STUB_TS_STATE"

  bash "$REPO_ROOT/modules/tailscale.sh" >/dev/null 2>&1 || return 1
  if grep -qP '^tailscale\tup' "$STUB_CALL_LOG"; then fail "no debe correr 'tailscale up' con sesión iniciada"; return 1; fi
  if grep -qP '^curl\t' "$STUB_CALL_LOG"; then fail "no debe descargar nada"; return 1; fi
  assert_contains "$(_ts_texts)" "100.64.0.1" || return 1
  assert_file_contains "$STATE_FILE" "tailscale" || return 1
}

test_tailscale_rejects_unexpected_sources_list() {
  _ts_env
  export STUB_TAILSCALE_LIST_BAD=1
  PATH="$TS_BIN:$PATH"
  if bash "$REPO_ROOT/modules/tailscale.sh" >/dev/null 2>&1; then fail "aceptó una lista de fuentes ajena"; return 1; fi
  [[ ! -e "$HLI2_TAILSCALE_LIST" ]] || { fail "instaló la lista inesperada"; return 1; }
  assert_contains "$(_ts_texts)" "no tiene el formato esperado" || return 1
}

test_tailscale_download_failure_shows_message() {
  _ts_env
  export STUB_TAILSCALE_CURL_FAIL=1
  PATH="$TS_BIN:$PATH"
  if bash "$REPO_ROOT/modules/tailscale.sh" >/dev/null 2>&1; then fail "debió fallar"; return 1; fi
  assert_contains "$(_ts_texts)" "No se pudo descargar la clave" || return 1
}

test_tailscale_up_failure_shows_message() {
  _ts_env
  mkdir -p "$TS_BIN"; cp "$REPO_ROOT/tests/stubs/fake/tailscale" "$TS_BIN/tailscale"
  PATH="$TS_BIN:$PATH"
  export STUB_TS_UP_FAIL=1
  if bash "$REPO_ROOT/modules/tailscale.sh" >/dev/null 2>&1; then fail "debió fallar"; return 1; fi
  assert_contains "$(_ts_texts)" "falló o se canceló" || return 1
  assert_file_not_contains "$STATE_FILE" "tailscale" || return 1
}

test_tailscale_adguard_step_checks_listener() {
  _ts_env
  mkdir -p "$TS_BIN"; cp "$REPO_ROOT/tests/stubs/fake/tailscale" "$TS_BIN/tailscale"
  PATH="$TS_BIN:$PATH"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  export STUB_SS_OUTPUT='UNCONN 0 0 0.0.0.0:53 0.0.0.0:*'
  bash "$REPO_ROOT/modules/tailscale.sh" >/dev/null 2>&1 || return 1
  assert_contains "$(_ts_texts)" "login.tailscale.com/admin/dns" || return 1
  assert_contains "$(_ts_texts)" "Escriba 100.64.0.1" || return 1
}

test_tailscale_adguard_step_warns_when_not_listening() {
  _ts_env
  mkdir -p "$TS_BIN"; cp "$REPO_ROOT/tests/stubs/fake/tailscale" "$TS_BIN/tailscale"
  PATH="$TS_BIN:$PATH"
  echo "yes" > "$DIALOG_YESNO_QUEUE"
  export STUB_SS_OUTPUT=''
  bash "$REPO_ROOT/modules/tailscale.sh" >/dev/null 2>&1 || return 1
  assert_contains "$(_ts_texts)" "no parece estar escuchando DNS" || return 1
}

# El servidor es el DNS de la casa: Tailscale no debe cambiar su resolución.
test_tailscale_up_does_not_accept_dns() {
  grep -qE 'tailscale up --accept-dns=false' "$REPO_ROOT/modules/tailscale.sh" \
    || { fail "'tailscale up' debe usar --accept-dns=false en el servidor"; return 1; }
}

# Sin VERSION_CODENAME legible, no se agrega ningún repositorio (falla cerrado).
test_tailscale_unknown_codename_aborts() {
  local osr="$STUB_SAFE_ROOT/os-release-sin-codename"
  printf 'ID=ubuntu\n' > "$osr"
  if HLI2_OS_RELEASE_FILE="$osr" bash "$REPO_ROOT/modules/tailscale.sh" >/dev/null 2>&1; then
    fail "debería cancelar si no se puede leer la versión de Ubuntu"; return 1
  fi
  if grep -qE 'curl.*pkgs\.tailscale\.com' "$STUB_CALL_LOG" 2>/dev/null; then
    fail "no debe descargar nada del repositorio"; return 1
  fi
}
