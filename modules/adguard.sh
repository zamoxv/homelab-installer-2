#!/usr/bin/env bash
# HLI-MODULE: adguard
# HLI-DESC: AdGuard Home (contenedor, red del host, vía API de Dokploy)
# HLI-ORDER: 62
# HLI-DEFAULT: yes
# HLI-TUI: yes
# HLI-REQUIERE: dokploy-api
#
# network_mode: host (ver compose/adguard/docker-compose.yml): AdGuard
# necesita el puerto 53 del host para DNS. Este módulo siembra o normaliza
# AdGuardHome.yaml para que el panel quede en 3053 (el 3000 es de Dokploy)
# DESDE EL PRIMER ARRANQUE: sin esto, el asistente de instalación de AdGuard
# escucha por defecto en el 3000 y chocaría con el panel de Dokploy
# (roadmap, decisión #2). El cambio de DNS del host (lib/dns.sh:
# free_dns_port) se aplica recién INMEDIATAMENTE ANTES del deploy (no al
# principio del módulo, antes de siquiera confirmar credenciales/canario):
# si algo más adelante falla (deploy, o el contenedor nunca queda activo),
# se revierte con restore_dns_port() — nunca se deja el puerto 53 liberado
# con AdGuard caído o sin desplegar, que dejaría al host sin DNS de verdad.
#
# HALLAZGO DE SEGURIDAD (validado en hardware real): el AdGuardHome.yaml
# "sembrado" a mano (solo http.address/dns.bind_hosts, ver
# _adguard_seed_if_missing) SÍ evita el asistente de instalación por
# completo — y ese asistente es, precisamente, donde AdGuard crea el usuario
# admin. Sin un usuario creado de antemano, el panel en :3053 arranca SIN
# AUTENTICACIÓN: cualquiera en la LAN puede entrar y cambiar el DNS de toda
# la casa. Por eso _adguard_ensure_admin_user() crea el usuario admin A
# MANO, directamente en el YAML (lib/importer.sh:
# adguard_yaml_has_users/adguard_yaml_append_user), ANTES del primer
# arranque del contenedor — nunca depende del asistente. El hash se genera
# con 'htpasswd -B' (bcrypt), el método que la propia documentación de
# AdGuard Home indica para gestionar contraseñas:
# https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration
# ("htpasswd -B -C 10 -n -b <USERNAME> <PASSWORD>"). Acá se usa -i en vez de
# -b: -b pone la contraseña en el ARGV del proceso htpasswd (visible por
# ps(1)/`/proc/<pid>/cmdline` para cualquier usuario local — el mismo
# problema de fondo que motivó pasar el token de la API de Dokploy por
# stdin en vez de argv, ver ROADMAP v2.2); -i lee la contraseña por STDIN
# (manual de Apache: https://httpd.apache.org/docs/current/programs/htpasswd.html).
# Se corre dentro de un contenedor descartable (httpd:2-alpine, trae el
# 'htpasswd' de Apache httpd) porque Ubuntu Server no lo trae instalado por
# defecto.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

_adguard_prepare_dirs() {
  sudo mkdir -p "$APPDATA_ROOT/adguard/conf" "$APPDATA_ROOT/adguard/work"
  sudo chown -R root:root "$APPDATA_ROOT/adguard"
  # Carpetas root-only: AdGuard reescribe AdGuardHome.yaml con 0644 al
  # guardar cambios (AdGuardHome#764) y el archivo contiene el hash de la
  # contraseña del panel. Con la carpeta en 0700 nadie más llega al archivo.
  # Por eso toda verificación sobre estas rutas usa 'sudo test'.
  sudo chmod 0700 "$APPDATA_ROOT/adguard/conf" "$APPDATA_ROOT/adguard/work"
}

_adguard_yaml_path() {
  printf '%s/adguard/conf/AdGuardHome.yaml' "$APPDATA_ROOT"
}

_adguard_offer_import() {
  confirm "¿Importar la configuración de AdGuard Home desde un backup del HLI v1 (backup-<fecha>.tar.gz)?" || return 0

  if ! importer_container_safe adguard; then
    msg "El contenedor 'adguard' parece estar activo o su estado no se pudo determinar. Por seguridad, la importación solo corre con el contenedor detenido o ausente."
    return 1
  fi

  local tar_path
  tar_path=$(input_box "Importar AdGuard Home" "Ruta al backup-<fecha>.tar.gz del HLI v1:") || return 0
  [[ -n "$tar_path" ]] || return 0

  if sudo test -f "$APPDATA_ROOT/adguard/conf/AdGuardHome.yaml"; then
    confirm "Ya hay un AdGuardHome.yaml en $APPDATA_ROOT/adguard/conf.\n\n¿Sobrescribirlo con el del backup?" || return 0
  fi

  # IMPORT_WORK_DIR (global, no 'local work'): así el trap EXIT del bloque
  # de ejecución real (al final del archivo) puede limpiar el directorio
  # temporal aunque algo falle entre medio bajo 'set -e' — un 'trap ...
  # RETURN' NO sirve acá porque no es local a esta función (ver el mismo
  # comentario en modules/dokploy.sh sobre por qué no se usa).
  IMPORT_WORK_DIR="$(importer_extract "$tar_path")" || { msg "No se pudo extraer el backup. Revise la ruta y que sea un tar.gz válido del HLI v1."; return 1; }
  importer_adguard "$IMPORT_WORK_DIR"
  importer_cleanup "$IMPORT_WORK_DIR"
  IMPORT_WORK_DIR=""
  msg "Configuración de AdGuard Home importada y normalizada (panel en 0.0.0.0:3053, DNS en todas las interfaces)."
  return 0
}

# Si no hay AdGuardHome.yaml (no se importó nada), siembra uno mínimo antes
# del primer arranque, para no depender del asistente en el puerto 3000.
_adguard_seed_if_missing() {
  local yaml port
  yaml="$(_adguard_yaml_path)"
  sudo test -f "$yaml" && return 0

  port="$(service_get adguard PORT)" || port="3053"
  cat <<EOF | sudo tee "$yaml" >/dev/null
http:
  address: 0.0.0.0:${port}
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
EOF
  sudo chown root:root "$yaml"
  log "Sembrado AdGuardHome.yaml inicial (panel en 0.0.0.0:${port})"
}

# Crea el usuario admin A MANO si el YAML todavía no tiene ninguno (ver el
# comentario de cabecera del archivo). Si ya hay un usuario (importado de un
# backup del v1, o de una corrida anterior de este mismo módulo), NO
# pregunta nada y deja el archivo intacto — idempotente, nunca pisa
# credenciales existentes.
#
# Formato de salida de 'htpasswd -n -i -B' (apache2-utils, imagen
# httpd:2-alpine): "<user>:<hash>\n" por stdout. '-B' usa el prefijo $2y$ de
# crypt_blowfish. AdGuard Home (Go) compara con
# golang.org/x/crypto/bcrypt.CompareHashAndPassword, cuyo parseo del hash
# (bcrypt.go: decodeVersion) solo rechaza una MAJOR version mayor a '2' —
# cualquier minor version ('a'/'b'/'x'/'y') es aceptada tal cual, así que el
# hash de 'htpasswd -B' funciona sin ninguna conversión.
#
# 'docker run -i' (sin '-t', a diferencia de modules/vaultwarden.sh que SÍ
# necesita '-it' porque 'vaultwarden hash' exige una tty real): sin pty, no
# hay traducción ONLCR, así que no hace falta limpiar ningún '\r' de la
# salida (a diferencia del ADMIN_TOKEN de Vaultwarden).
_adguard_ensure_admin_user() {
  local yaml="$1"

  if adguard_yaml_has_users "$yaml"; then
    log "AdGuardHome.yaml ya tiene usuarios (importado o ya configurado antes); no se pide nada."
    return 0
  fi

  local user
  user=$(input_box "AdGuard Home — usuario admin" "El panel de AdGuard Home (http://<ip>:3053) va a quedar accesible desde toda la LAN SIN pasar por el asistente de instalación: hace falta crear el usuario administrador ahora, antes de arrancar el contenedor.\n\nNombre de usuario:" "admin") \
    || { msg "Se cancela el despliegue de AdGuard: hace falta un usuario administrador antes de arrancar el contenedor."; return 1; }
  [[ -n "$user" ]] || { msg "Usuario vacío. Se cancela el despliegue de AdGuard."; return 1; }
  [[ "$user" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] \
    || { msg "'$user' no es un nombre de usuario válido (letras, números, '_', '.', '-'; 1 a 32 caracteres). Se cancela: vuelva a correr este módulo con un nombre válido."; return 1; }

  local pass1 pass2
  pass1=$(password_box "AdGuard Home — contraseña admin" "Contraseña para '$user' (mínimo 8 caracteres):") \
    || { msg "Se cancela el despliegue de AdGuard."; return 1; }
  if [[ "${#pass1}" -lt 8 ]]; then
    pass1=""
    msg "La contraseña debe tener al menos 8 caracteres. Se cancela el despliegue de AdGuard: vuelva a correr este módulo."
    return 1
  fi

  pass2=$(password_box "AdGuard Home — contraseña admin" "Repita la contraseña:") \
    || { pass1=""; msg "Se cancela el despliegue de AdGuard."; return 1; }

  if [[ "$pass1" != "$pass2" ]]; then
    pass1=""; pass2=""
    msg "Las contraseñas no coinciden. Se cancela el despliegue de AdGuard: vuelva a correr este módulo para reintentar."
    return 1
  fi
  pass2=""

  local line rc hash
  if line="$(printf '%s' "$pass1" | hli_docker run --rm -i httpd:2-alpine htpasswd -n -i -B -C 10 "$user")"; then
    rc=0
  else
    rc=$?
  fi
  pass1=""

  if [[ "$rc" -ne 0 || -z "$line" ]]; then
    msg "No se pudo generar el hash de la contraseña (¿no se pudo correr el contenedor httpd:2-alpine?). Se cancela el despliegue de AdGuard. Vuelva a correr este módulo para reintentar."
    return 1
  fi

  hash="${line#*:}"
  # Regex ANCLADA A AMBOS LADOS contra la forma completa de un bcrypt de
  # htpasswd -B ($2y$<costo de 2 dígitos>$<22 salt + 31 hash, base64 de
  # crypt_blowfish>): mismo criterio que la validación del ADMIN_TOKEN de
  # Vaultwarden (modules/vaultwarden.sh) — nunca se guarda un hash que no se
  # pueda confirmar como válido.
  if [[ ! "$hash" =~ ^\$2y\$[0-9]{2}\$[A-Za-z0-9./]{53}$ ]]; then
    hash=""
    msg "El valor generado no tiene la forma completa de un hash bcrypt de htpasswd -B. Se cancela por seguridad: nunca se guarda un usuario con un hash que no se pueda confirmar como válido."
    return 1
  fi

  if ! adguard_yaml_append_user "$yaml" "$user" "$hash"; then
    hash=""
    msg "No se pudo escribir el usuario administrador en AdGuardHome.yaml. Se cancela el despliegue de AdGuard."
    return 1
  fi
  hash=""

  log "Usuario admin '$user' creado en AdGuardHome.yaml (nunca se loguea la contraseña ni el hash)."
  return 0
}

_adguard_main() {
  _adguard_prepare_dirs
  _adguard_offer_import || true
  _adguard_seed_if_missing
  _adguard_ensure_admin_user "$(_adguard_yaml_path)" || return 1

  dokploy_preflight || return 1

  local project_json environment_id compose_file composeId url port
  project_json="$(dokploy_project_find_or_create)" || { msg "No se pudo crear/encontrar el proyecto 'homelab' en Dokploy."; return 1; }
  environment_id="$(dokploy_environment_default_id "$project_json")" || { msg "No se pudo resolver el ambiente por defecto del proyecto 'homelab' en Dokploy."; return 1; }

  # Recién ACÁ, inmediatamente antes de tocar el compose real: ver el
  # comentario de arriba sobre por qué no se hace al principio del módulo.
  if ! free_dns_port; then
    msg "No se pudo liberar el puerto 53 de forma segura (ver detalle en el log). Se cancela el despliegue de AdGuard: no se toca el DNS del host sin poder garantizar que sigue funcionando."
    return 1
  fi

  compose_file="$(mktemp)"
  compose_render_adguard > "$compose_file"

  if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "adguard" "$compose_file")"; then
    msg "Falló el despliegue de AdGuard Home vía la API de Dokploy. Se revierte el cambio de DNS del host (puerto 53 vuelve a systemd-resolved) para no dejarlo sin DNS con AdGuard sin desplegar."
    restore_dns_port
    rm -f "$compose_file"
    return 1
  fi
  rm -f "$compose_file"

  if ! service_wait_active adguard 120; then
    msg "AdGuard Home no llegó a 'activo' dentro de los 120 segundos de espera. Se revierte el cambio de DNS del host (puerto 53 vuelve a systemd-resolved) para no dejar el host sin DNS con AdGuard caído.\n\nRevise el panel de Dokploy y, cuando el contenedor esté realmente arriba, vuelva a correr este módulo (es idempotente) para liberar el puerto 53 de nuevo."
    restore_dns_port
    return 1
  fi

  port="$(service_get adguard PORT)" || port="3053"
  url="$(service_url adguard)" || true
  msg "AdGuard Home desplegado (composeId=$composeId).\n\nAdGuard Home está corriendo.\n\nPanel: ${url:-http://<ip>:$port}\n\nInicie sesión con el usuario administrador que se acaba de crear (o, si importó un backup del HLI v1, con el usuario que ya tenía: no se le pidió nada porque el YAML importado ya traía uno)."

  mark_done adguard
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap '[[ -n "${IMPORT_WORK_DIR:-}" ]] && importer_cleanup "$IMPORT_WORK_DIR"' EXIT
  _adguard_main
fi
