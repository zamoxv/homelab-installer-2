#!/usr/bin/env bash
# Tests del flujo "pedir el token de la API de Dokploy al final del módulo
# dokploy" (en vez de que lo pida a mitad de camino el primer servicio que
# lo necesite) y de que los módulos Dokploy-dependientes se OMITAN (no
# fallen) en install_full/install_custom cuando la API todavía no está
# configurada. Toda la lógica de configurar+verificar vive en
# dokploy_api_configure_verified (lib/dokploy_api.sh) — ver también
# tests/test_dokploy_api_tool.sh, que prueba la misma función desde la
# herramienta de Herramientas.

# --- Hallazgo de revisión (CRÍTICO): fail-closed si 'sudo -n' no funciona ---
#
# Antes de este fix, un 'sudo -n' que fallara (sesión cacheada vencida) hacía
# que priv_file_exists() devolviera 1 por el MISMO camino que "el archivo
# genuinamente no existe" (ver lib/secrets.sh): dokploy_api_configure_verified
# trataba eso como "no hay nada que respaldar", dejaba que dokploy_api_setup
# pisara credenciales FUNCIONANDO sin backup, y si la verificación posterior
# fallaba, el 'else' sin backup borraba el archivo entero — pérdida
# irrecuperable de credenciales que SÍ funcionaban. El fix exige 'sudo -n
# true' ANTES de tocar nada.
test_dokploy_configure_verified_fails_closed_when_sudo_n_unavailable() {
  # Token malo + "no" a reintentar: si el código NO abortara temprano,
  # terminaría en la rama "se canceló, sin backup -> se borra el archivo"
  # (porque priv_file_exists habría fallado "como si no existiera").
  printf '192.168.1.20\n3000\n' > "$DIALOG_INPUTBOX_QUEUE"
  echo "tokenMaloDeSobra" > "$DIALOG_PASSWORDBOX_QUEUE"
  echo "no" > "$DIALOG_YESNO_QUEUE"

  local rc=0
  STUB_SUDO_FAIL_N=1 STUB_CURL_REJECT_TOKEN="tokenMaloDeSobra" \
    bash -c '
      set -euo pipefail
      source "'"$REPO_ROOT"'/lib/core.sh"
      dokploy_api_configure_verified
    ' || rc=$?
  [[ "$rc" -ne 0 ]] || { fail "debería fallar (fail-closed) si sudo -n no funciona"; return 1; }

  # Las credenciales ORIGINALES (sembradas por el harness) deben seguir
  # intactas: nunca se debió haber llegado a pedir/escribir nada nuevo.
  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    dokploy_api_configured || { echo "las credenciales originales deberían seguir configuradas"; exit 1; }
    url="$(_dokploy_env_get DOKPLOY_TOKEN)"
    [[ "$url" == "test-token-abc123" ]] || { echo "el token original se perdió/cambió: [$url]"; exit 1; }
  ) || { fail "las credenciales originales no sobrevivieron"; return 1; }

  # Tampoco se debió haber consumido ninguna cola de dialog (nunca se llegó
  # a preguntar nada): las tres colas deben seguir con su contenido íntegro.
  assert_file_contains "$DIALOG_PASSWORDBOX_QUEUE" "tokenMaloDeSobra" \
    "no debió haberse pedido el token: la cola no se tocó" || return 1
}

# --- Red de seguridad del trap EXIT (restaurar ante una interrupción) ------

test_dokploy_configure_verified_registers_exit_trap() {
  grep -q 'trap _dokploy_cfgv_restore_on_abort EXIT' "$REPO_ROOT/lib/dokploy_api.sh" \
    || { fail "dokploy_api_configure_verified no registra el trap EXIT de seguridad"; return 1; }
}

# Prueba el handler del trap EXIT en aislamiento (sin depender de mandar una
# señal real, que sería frágil/no determinístico en un runner de tests):
# simula el estado exacto a mitad de dokploy_api_configure_verified (backup
# ya hecho, archivo real ya sobrescrito con datos a medio terminar) y
# confirma que _dokploy_cfgv_restore_on_abort deja todo como antes.
test_dokploy_cfgv_restore_on_abort_restores_previous_credentials() {
  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"

    backup="${DOKPLOY_ENV_FILE}.anterior"
    sudo install -m 0600 -o root -g root /dev/null "$backup"
    sudo cp "$DOKPLOY_ENV_FILE" "$backup"
    { echo "DOKPLOY_URL=http://a-medio-escribir:9999"; echo "DOKPLOY_TOKEN=incompleto"; } \
      | sudo tee "$DOKPLOY_ENV_FILE" >/dev/null

    _DOKPLOY_CFGV_BACKUP="$backup"
    _dokploy_cfgv_restore_on_abort

    priv_file_exists "$backup" && { echo "el backup debería haberse borrado tras restaurar"; exit 1; }
    url="$(_dokploy_env_get DOKPLOY_URL)"
    [[ "$url" == "http://test-dokploy:3000" ]] || { echo "no se restauró la URL anterior: [$url]"; exit 1; }
    token="$(_dokploy_env_get DOKPLOY_TOKEN)"
    [[ "$token" == "test-token-abc123" ]] || { echo "no se restauró el token anterior: [$token]"; exit 1; }
  ) || return 1
}

# --- SUGERENCIA de revisión: Prompt=never nunca más un no-op silencioso ----
#
# Antes de este fix, 'sed -i "s/^Prompt=.*/Prompt=never/"' sobre un archivo
# SIN ninguna línea 'Prompt=' sin comentar (comentada, ej. '#Prompt=normal',
# o ausente directamente) no tenía nada que matchear: no-op silencioso. El
# 'log' de éxito corría igual (sin haber cambiado nada), y el aviso se
# volvía a ofrecer en cada corrida porque el archivo real nunca quedaba con
# 'Prompt=never'.
test_dp_offer_hold_release_upgrade_appends_when_no_prompt_line() {
  local f="$HLI2_TEST_SCRATCH/release-upgrades"
  printf '# Config de ejemplo\nOtraClave=valor\n#Prompt=normal\n' > "$f"
  echo "yes" > "$DIALOG_YESNO_QUEUE"

  # Carga las funciones del módulo sin ejecutar _dokploy_main (mismo patrón
  # que _load_dokploy_functions en tests/test_dokploy_os.sh): $0 apunta a
  # una ruta inexistente dentro de modules/, así el guard
  # BASH_SOURCE[0]==$0 no se cumple, pero 'dirname "$0"' sigue resolviendo
  # lib/core.sh bien (misma carpeta modules/).
  HLI2_RELEASE_UPGRADES_FILE="$f" bash -c 'source "$1"; shift; "$@"' \
    "$REPO_ROOT/modules/__test_nunca_existe__.sh" \
    "$REPO_ROOT/modules/dokploy.sh" _dp_offer_hold_release_upgrade

  assert_file_contains "$f" "Prompt=never" "debería haber agregado la línea" || return 1
  assert_file_contains "$f" "OtraClave=valor" "no debería perder el resto del contenido" || return 1
}

# --- SUGERENCIA de revisión: bootstrap.sh restaura el eco del teclado ------
#
# hli_busy() (lib/core.sh) apaga el eco en /dev/tty; si Ctrl+C mata al
# módulo Y a bootstrap.sh juntos (misma señal, mismo grupo de procesos en
# primer plano), el 'hli_busy_end' de run_module (que corre DESPUÉS de
# 'bash "$path"' en el proceso de bootstrap.sh) puede no llegar a
# ejecutarse nunca. El único lugar garantizado es el trap EXIT de nivel de
# script en bootstrap.sh. No se puede probar mandando una señal real de
# forma determinística en este runner; se verifica que el trap la incluya.
test_bootstrap_exit_trap_restores_terminal_echo() {
  grep -q "stty echo" "$REPO_ROOT/bootstrap.sh" \
    || { fail "bootstrap.sh no restaura el eco de la terminal en su trap EXIT"; return 1; }
  grep -qE "trap '.*stty echo.*' EXIT" "$REPO_ROOT/bootstrap.sh" \
    || { fail "la restauración de eco no está en el trap EXIT de nivel de script"; return 1; }
}

# --- install_full / install_custom: omitir módulos Dokploy-dependientes ---
#
# Se arma un directorio de módulos de PRUEBA (nunca el modules/ real: correr
# install_full/install_custom contra el repo real ejecutaría base/power/wol/
# storage/datadisk/samba de verdad, que no tienen cobertura de stubs para
# esto) y se apunta SCRIPT_DIR ahí DESPUÉS de sourcear lib/core.sh +
# ui/menu.sh: list_modules/module_meta/run_module resuelven
# "$SCRIPT_DIR/modules/..." en el momento de llamarse (no al sourcear), así
# que redirigir SCRIPT_DIR después sigue funcionando para descubrir/correr
# SOLO estos módulos falsos, sin tocar nada del sistema real.
_write_fake_module() {
  local dir="$1" id="$2" order="$3" default="$4" tui="$5" requiere="$6" body="$7"
  local f="$dir/modules/$id.sh"
  {
    echo '#!/usr/bin/env bash'
    echo "# HLI-MODULE: $id"
    echo "# HLI-DESC: Módulo de prueba $id"
    echo "# HLI-ORDER: $order"
    echo "# HLI-DEFAULT: $default"
    echo "# HLI-TUI: $tui"
    [[ -n "$requiere" ]] && echo "# HLI-REQUIERE: $requiere"
    echo 'set -euo pipefail'
    echo "$body"
  } > "$f"
}

_setup_fake_modules_dir() {
  local dir="$HLI2_TEST_SCRATCH/fakerepo"
  mkdir -p "$dir/modules"
  _write_fake_module "$dir" fakeok 10 yes yes "" \
    'echo ok-corrio > "'"$HLI2_TEST_SCRATCH"'/fakeok.ran"; exit 0'
  _write_fake_module "$dir" fakeneeds 11 yes yes dokploy-api \
    'echo necesita-corrio > "'"$HLI2_TEST_SCRATCH"'/fakeneeds.ran"; exit 0'
  _write_fake_module "$dir" fakeneeds2 12 no yes dokploy-api \
    'echo necesita2-corrio > "'"$HLI2_TEST_SCRATCH"'/fakeneeds2.ran"; exit 0'
  printf '%s' "$dir"
}

test_install_full_skips_dokploy_dependent_modules_when_api_not_configured() {
  sudo rm -f "$DOKPLOY_ENV_FILE"

  local fakerepo
  fakerepo="$(_setup_fake_modules_dir)"
  echo "yes" > "$DIALOG_YESNO_QUEUE"

  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    source "$REPO_ROOT/ui/menu.sh"
    SCRIPT_DIR="$fakerepo"
    install_full
  ) || { fail "install_full no debería fallar por un módulo omitido"; return 1; }

  [[ -f "$HLI2_TEST_SCRATCH/fakeok.ran" ]] \
    || { fail "fakeok (sin HLI-REQUIERE) debería haber corrido"; return 1; }
  [[ ! -f "$HLI2_TEST_SCRATCH/fakeneeds.ran" ]] \
    || { fail "fakeneeds (REQUIERE dokploy-api, API no configurada) NO debería haber corrido"; return 1; }
}

test_install_custom_skips_dokploy_dependent_modules_when_api_not_configured() {
  sudo rm -f "$DOKPLOY_ENV_FILE"

  local fakerepo
  fakerepo="$(_setup_fake_modules_dir)"
  # El checklist "selecciona" los tres falsos (fakeok, fakeneeds,
  # fakeneeds2), con y sin comillas, como un dialog --checklist real.
  printf '"fakeok" "fakeneeds" "fakeneeds2"\n' > "$DIALOG_MENU_QUEUE"

  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    source "$REPO_ROOT/ui/menu.sh"
    SCRIPT_DIR="$fakerepo"
    install_custom
  ) || { fail "install_custom no debería fallar por un módulo omitido"; return 1; }

  [[ -f "$HLI2_TEST_SCRATCH/fakeok.ran" ]] \
    || { fail "fakeok debería haber corrido"; return 1; }
  [[ ! -f "$HLI2_TEST_SCRATCH/fakeneeds.ran" ]] \
    || { fail "fakeneeds (REQUIERE dokploy-api) NO debería haber corrido aunque se seleccionó"; return 1; }
  [[ ! -f "$HLI2_TEST_SCRATCH/fakeneeds2.ran" ]] \
    || { fail "fakeneeds2 (DEFAULT no, pero seleccionado + REQUIERE dokploy-api) NO debería haber corrido"; return 1; }
}

# Con la API SÍ configurada, los módulos Dokploy-dependientes corren
# normalmente (nada se omite por el solo hecho de tener HLI-REQUIERE).
test_install_full_runs_dokploy_dependent_modules_when_api_configured() {
  local fakerepo
  fakerepo="$(_setup_fake_modules_dir)"
  echo "yes" > "$DIALOG_YESNO_QUEUE"

  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    source "$REPO_ROOT/ui/menu.sh"
    SCRIPT_DIR="$fakerepo"
    install_full
  ) || { fail "install_full no debería fallar"; return 1; }

  [[ -f "$HLI2_TEST_SCRATCH/fakeok.ran" ]] || { fail "fakeok debería haber corrido"; return 1; }
  [[ -f "$HLI2_TEST_SCRATCH/fakeneeds.ran" ]] \
    || { fail "fakeneeds debería haber corrido: la API SÍ está configurada"; return 1; }
}

# --- modules/dokploy.sh end-to-end: pedir el token al final del módulo ----
#
# "Dokploy ya instalado" se simula SIN tocar /etc/dokploy (ruta real, no
# overrideable a propósito — ver _dokploy_state en modules/dokploy.sh):
# alcanza con que hli_docker_presence vea el 'docker' de tests/stubs en el
# PATH ('sudo -n sh -c "command -v docker"' corre de verdad y lo encuentra
# ahí) y que 'docker service inspect dokploy' responda bien (el stub
# contesta éxito por defecto para cualquier 'inspect' no reconocido
# explícitamente) — con eso _dokploy_state() ya da "installed", sin
# necesitar simular la ruta de instalación limpia (no se puede: la huella
# de Docker en lib/core.sh es intencionalmente no overrideable, y esta
# máquina de desarrollo además tiene Docker real — ver ROADMAP.md).
test_dokploy_module_installed_not_configured_nada_then_valid_token() {
  sudo rm -f "$DOKPLOY_ENV_FILE"

  # Menú "Dokploy ya está instalado": elegir "nada".
  echo "nada" > "$DIALOG_MENU_QUEUE"
  # dokploy_api_configure_verified: IP, puerto, token válido.
  printf '192.168.1.20\n3000\n' > "$DIALOG_INPUTBOX_QUEUE"
  echo "tokenValidoNuevo789" > "$DIALOG_PASSWORDBOX_QUEUE"

  bash "$REPO_ROOT/modules/dokploy.sh" \
    || { fail "el módulo no debería fallar: Dokploy ya instalado + token válido"; return 1; }

  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    dokploy_api_configured || { echo "la API debería haber quedado configurada"; exit 1; }
    url="$(_dokploy_env_get DOKPLOY_URL)"
    [[ "$url" == "http://192.168.1.20:3000" ]] || { echo "URL inesperada: [$url]"; exit 1; }
    token="$(_dokploy_env_get DOKPLOY_TOKEN)"
    [[ "$token" == "tokenValidoNuevo789" ]] || { echo "token inesperado: [$token]"; exit 1; }
  ) || { fail "no quedaron guardadas las credenciales nuevas"; return 1; }

  grep -qF "project.all" "$STUB_CALL_LOG" \
    || { fail "debería haberse llamado a project.all para verificar"; return 1; }
}

# Token rechazado por Dokploy (STUB_CURL_REJECT_TOKEN) -> se ofrece
# reintentar -> el usuario cancela (DIALOG_YESNO_QUEUE=no) -> no deben
# quedar credenciales (ni las nuevas -rechazadas-, ni ninguna: no había
# ninguna previa). Diseño/documentación del código de salida: el módulo
# 'dokploy' en sí mismo NO falla (exit 0) aunque la configuración de la API
# termine cancelada — la instalación/actualización de Dokploy ya terminó
# bien antes de llegar a este paso, y dokploy_api_configure_verified ya le
# explicó al usuario con su propio msg() qué pasó; forzar un exit 1 acá
# solo duplicaría un segundo mensaje genérico de "el módulo falló" sin
# agregar información. Lo único que SÍ hace falta verificar es que no haya
# quedado ninguna credencial a medio escribir (ver el assert de abajo).
test_dokploy_module_installed_not_configured_rejected_token_then_cancel() {
  sudo rm -f "$DOKPLOY_ENV_FILE"

  echo "nada" > "$DIALOG_MENU_QUEUE"
  printf '192.168.1.20\n3000\n' > "$DIALOG_INPUTBOX_QUEUE"
  echo "tokenRechazadoXYZ" > "$DIALOG_PASSWORDBOX_QUEUE"
  echo "no" > "$DIALOG_YESNO_QUEUE"

  local rc=0
  STUB_CURL_REJECT_TOKEN="tokenRechazadoXYZ" bash "$REPO_ROOT/modules/dokploy.sh" || rc=$?
  assert_eq "0" "$rc" "el módulo 'dokploy' no debe fallar aunque se cancele la configuración de la API (ver comentario del test)" || return 1

  # Confirma que el flujo REALMENTE se ejerció (se pidió el token y se
  # intentó verificar contra project.all) y no que el módulo simplemente
  # nunca llegó a preguntar nada: sin esto, un dokploy.sh que todavía no
  # pidiera el token al terminar (el bug original que este cambio corrige)
  # pasaría este test igual, por las razones equivocadas.
  grep -qF "project.all" "$STUB_CALL_LOG" \
    || { fail "debería haberse intentado verificar con project.all antes de cancelar"; return 1; }

  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    if dokploy_api_configured; then
      echo "no debería haber quedado ninguna credencial configurada"
      exit 1
    fi
  ) || { fail "quedó una credencial que no debía (token rechazado, sin previa, cancelado)"; return 1; }

  priv_file_exists_result=0
  ( set -euo pipefail; source "$REPO_ROOT/lib/core.sh"; priv_file_exists "$DOKPLOY_ENV_FILE" ) \
    && { fail "no debería quedar ningún archivo de credenciales"; return 1; }
  return 0
}
