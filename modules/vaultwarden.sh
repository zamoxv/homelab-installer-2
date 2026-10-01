#!/usr/bin/env bash
# HLI-MODULE: vaultwarden
# HLI-DESC: Vaultwarden (contenedor, vía API de Dokploy)
# HLI-ORDER: 63
# HLI-DEFAULT: yes
# HLI-TUI: yes
# HLI-REQUIERE: dokploy-api
#
# Prepara APPDATA/vaultwarden/data, pide el dominio (Vaultwarden todavía NO
# se expone a Internet en esta fase: solo LAN vía Traefik, ver
# dokploy_domain_ensure en lib/dokploy_api.sh — Cloudflare Tunnel es v2.4),
# genera el ADMIN_TOKEN como hash Argon2id PHC pidiendo la contraseña con la
# propia TUI del HLI (password_box, ver _vaultwarden_ensure_admin_token) y la
# CLI 'argon2' de los repositorios de Ubuntu, y despliega el compose
# (lib/compose.sh) vía la API de Dokploy (lib/dokploy_api.sh), corriendo
# antes la validación canaria obligatoria (lib/canary.sh) si todavía no se
# hizo.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

_vaultwarden_prepare_dirs() {
  # root:root (no PUID/PGID): la imagen oficial vaultwarden/server corre
  # como root dentro del contenedor y no soporta mapeo de usuario por
  # variables de entorno (a diferencia de linuxserver/qbittorrent) — mismo
  # criterio que modules/adguard.sh.
  sudo mkdir -p "$APPDATA_ROOT/vaultwarden/data"
  sudo chown -R root:root "$APPDATA_ROOT/vaultwarden"
}

# Pide el dominio (sin esquema) por el que se accederá a Vaultwarden. Se
# guarda el último valor como default del input_box en re-ejecuciones (vía
# el propio ADMIN_TOKEN secret file no aplica acá; se relee del estado de
# Dokploy no es práctico, así que simplemente se vuelve a preguntar cada vez
# — dominio no es secreto, y puede cambiar).
_vaultwarden_ask_domain() {
  local domain
  domain=$(input_box "Vaultwarden" "Dominio para Vaultwarden (ej: vault.tu-dominio.com).\n\nNO se expone a Internet todavía (eso es la fase v2.4, Cloudflare Tunnel): por ahora se accede solo desde la LAN a través de Traefik, apuntando este dominio a la IP del servidor (por ejemplo con una reescritura DNS en AdGuard Home).") || return 1
  [[ -n "$domain" ]] || { msg "Dominio vacío: se cancela el despliegue de Vaultwarden."; return 1; }
  hli2_valid_hostname "$domain" || { msg "'$domain' no tiene forma de nombre de dominio válido (ej: vault.tu-dominio.com). Se cancela: vuelva a correr el módulo con un dominio válido."; return 1; }
  printf '%s' "$domain"
}

# Instala la CLI 'argon2' (paquete 'argon2' de los repositorios de Ubuntu) si
# todavía no está disponible. Ubuntu Server no la trae instalada por defecto
# (mismo motivo que 'htpasswd' en modules/adguard.sh, corrido ahí dentro de
# un contenedor descartable en vez de instalarse en el host — acá se instala
# en el host porque 'argon2' SÍ está empaquetada para Ubuntu).
_vaultwarden_require_argon2() {
  command -v argon2 >/dev/null 2>&1 && return 0
  hli_apt install argon2 >/dev/null 2>&1 || true
  command -v argon2 >/dev/null 2>&1 && return 0
  msg "No se pudo instalar el paquete 'argon2' (necesario para generar el ADMIN_TOKEN de Vaultwarden). Se cancela el despliegue. Instálelo a mano con el gestor de paquetes de Ubuntu (paquete 'argon2') y vuelva a correr este módulo."
  return 1
}

# Genera (o reutiliza, si ya hay uno guardado y el usuario no pide rotarlo)
# el ADMIN_TOKEN como hash Argon2id PHC. Guarda el hash en
# /etc/hli2/vaultwarden.env (root-only 0600, lib/secrets.sh). Nunca se
# loguea ni se imprime el valor.
#
# HALLAZGO (validado en hardware real, Ubuntu 24.04.5, 2026-09-30): la
# versión anterior de este módulo corría 'docker run --rm -it
# vaultwarden/server /vaultwarden hash --preset owasp' heredando la terminal
# del módulo (esa CLI exige una tty real: con stdin sin tty entra en pánico).
# En el servidor real el prompt de contraseña NUNCA apareció y las teclas
# tipeadas quedaban en eco en la terminal local SIN llegar al contenedor: el
# módulo se colgaba esperando una respuesta que el contenedor nunca recibía.
# Causa más probable: 'hli_docker' es 'sudo -n docker ...' (lib/core.sh), y
# el 'use_pty' por defecto de sudo intercala SU PROPIA pty entre la terminal
# real y el proceso hijo; combinado con '-it' (que además le pide a Docker
# asignarle otra pty al contenedor) y con la salida yendo a 'tee', la cadena
# de ptys/pipes no garantiza que el teclado llegue transparente hasta
# 'vaultwarden hash' dentro del contenedor. No es razonable pedirle a cada
# usuario que depure esto a mano en su propio hardware.
#
# CORRECCIÓN: se abandona el contenedor interactivo. La contraseña se pide
# con la propia TUI del HLI (password_box, dialog --passwordbox, SIN pty de
# por medio — mismo patrón que _adguard_ensure_admin_user en
# modules/adguard.sh: mínimo 8 caracteres, debe repetirse igual, se limpia
# la variable en TODA salida, Cancelar aborta sin guardar nada y sin marcar
# el módulo como hecho) y el hash se genera con la CLI 'argon2' de Ubuntu
# (_vaultwarden_require_argon2 la instala si falta), con la contraseña SOLO
# por stdin — NUNCA por argv: visible por ps(1)/'/proc/<pid>/cmdline' para
# cualquier usuario local del host, el mismo problema de fondo que ya
# motivó pasar el token de la API de Dokploy por stdin en vez de argv (ver
# ROADMAP v2.2).
#
# Parámetros: preset "Bitwarden" (m=65540 KiB, t=3, p=4 — el que
# 'vaultwarden hash' usa POR DEFECTO sin '--preset owasp'; ver wiki oficial
# github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page, sección
# "Using argon2 CLI tool": "echo -n 'MySecretPassword' | argon2
# "$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4", verificado
# 2026-10-01 corriendo el paquete 'argon2' de Ubuntu 24.04
# (0~20190702+dfsg-4build1) dentro de un contenedor 'ubuntu:24.04'
# descartable montando este repo solo-lectura).
#
# La sal (positional arg de 'argon2', NUNCA la contraseña) sale de
# 'head -c 16 /dev/urandom | base64': no es secreta (el propio formato PHC
# la expone en texto; puede aparecer en el argv de 'argon2' sin problema de
# seguridad), pero SÍ importa su LARGO. Con 16 bytes de entrada, 'base64'
# produce SIEMPRE una cadena de exactamente 24 caracteres ASCII (incluido el
# padding '==' que ese largo de entrada exige), y 24 es múltiplo de 3 — así
# que cuando 'argon2' vuelve a codificar esos 24 bytes (los toma como bytes
# crudos de la sal, nunca los decodifica) para el campo "sal" del PHC que
# imprime, el resultado NUNCA lleva padding ('='), que es justo lo que exige
# la regex ANCLADA A AMBOS LADOS de más abajo (sin '=' en la clase de
# caracteres). Con 32 bytes (como en el ejemplo de la wiki, vía 'openssl
# rand -base64 32') esa garantía NO se cumple (32 bytes -> cadena de 44
# caracteres, no múltiplo de 3): el padding resultante haría fallar la
# validación en algunas corridas. Verificado a mano dentro del contenedor de
# prueba: con 16 bytes, la sal re-codificada nunca lleva '='.
#
# El binario 'argon2' de Ubuntu 24.04 no exige tty, lee la contraseña de
# stdin sin problema y devuelve el PHC completo con un '\n' final (se
# descarta solo: la sustitución de comandos recorta los saltos de línea
# finales). Ya no hace falta limpiar ningún '\r' (no hay pty de por medio)
# ni quitar comillas simples (formato propio de 'vaultwarden hash', no de la
# CLI 'argon2' — esta imprime el PHC sin comillas).
_vaultwarden_ensure_admin_token() {
  if secret_file_exists vaultwarden; then
    confirm "Ya hay un ADMIN_TOKEN guardado para Vaultwarden.\n\n¿Generar uno nuevo? (rota el token: tendrá que volver a entrar al panel /admin con el nuevo)." \
      || return 0
  fi

  _vaultwarden_require_argon2 || return 1

  local pass1 pass2
  pass1=$(password_box "Vaultwarden — contraseña admin" "Contraseña para el panel de administración de Vaultwarden (/admin), mínimo 8 caracteres.\n\nNUNCA se guarda en texto plano: se convierte en un hash Argon2id antes de guardarse.") \
    || { msg "Se cancela el despliegue de Vaultwarden."; return 1; }
  if [[ "${#pass1}" -lt 8 ]]; then
    pass1=""
    msg "La contraseña debe tener al menos 8 caracteres. Se cancela el despliegue de Vaultwarden: vuelva a correr este módulo."
    return 1
  fi

  pass2=$(password_box "Vaultwarden — contraseña admin" "Repita la contraseña:") \
    || { pass1=""; msg "Se cancela el despliegue de Vaultwarden."; return 1; }

  if [[ "$pass1" != "$pass2" ]]; then
    pass1=""; pass2=""
    msg "Las contraseñas no coinciden. Se cancela el despliegue de Vaultwarden: vuelva a correr este módulo para reintentar."
    return 1
  fi
  pass2=""

  local salt hash rc
  if ! salt="$(head -c 16 /dev/urandom | base64)" || [[ -z "$salt" ]]; then
    pass1=""; pass2=""
    msg "No se pudo generar la sal aleatoria para el hash. Se cancela el despliegue de Vaultwarden."
    return 1
  fi
  if hash="$(printf '%s' "$pass1" | argon2 "$salt" -id -t 3 -k 65540 -p 4 -l 32 -e)"; then
    rc=0
  else
    rc=$?
  fi
  pass1=""

  if [[ "$rc" -ne 0 || -z "$hash" ]]; then
    hash=""
    msg "No se pudo generar el hash de la contraseña (¿no se pudo correr 'argon2'?). Se cancela el despliegue de Vaultwarden. Vuelva a correr este módulo para reintentar."
    return 1
  fi
  if [[ ! "$hash" =~ ^\$argon2id\$v=[0-9]+\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$ ]]; then
    hash=""
    msg "El valor generado no tiene la forma completa de un hash Argon2id PHC (\$argon2id\$v=..\$m=..,t=..,p=..\$salt\$hash). Se cancela por seguridad: nunca se guarda un ADMIN_TOKEN que no se pueda confirmar como hash válido."
    return 1
  fi

  secret_file_write vaultwarden "ADMIN_TOKEN=${hash}"
  hash=""
  log "ADMIN_TOKEN de Vaultwarden generado y guardado en /etc/hli2/vaultwarden.env (no se loguea el valor)."
  return 0
}

_vaultwarden_main() {
  _vaultwarden_prepare_dirs

  local domain
  domain="$(_vaultwarden_ask_domain)" || return 1

  _vaultwarden_ensure_admin_token || return 1

  local admin_token
  admin_token="$(secret_get vaultwarden ADMIN_TOKEN)" || { msg "No se pudo leer el ADMIN_TOKEN guardado."; return 1; }

  dokploy_preflight || return 1

  local project_json environment_id compose_file composeId url
  project_json="$(dokploy_project_find_or_create)" || { msg "No se pudo crear/encontrar el proyecto 'homelab' en Dokploy."; return 1; }
  environment_id="$(dokploy_environment_default_id "$project_json")" || { msg "No se pudo resolver el ambiente por defecto del proyecto 'homelab' en Dokploy."; return 1; }

  compose_file="$(mktemp)"
  if ! compose_render_vaultwarden "$domain" > "$compose_file"; then
    msg "No se pudo renderizar el compose de Vaultwarden."
    rm -f "$compose_file"
    return 1
  fi

  local env_line
  env_line="$(dotenv_single_quoted ADMIN_TOKEN "$admin_token")" || { msg "El ADMIN_TOKEN guardado tiene un formato inesperado. Vuelva a generarlo."; return 1; }
  # Orden: crear/actualizar el compose -> registrar el dominio -> desplegar.
  # Dokploy agrega las etiquetas de Traefik del dominio DURANTE el despliegue
  # (docs: core/docker-compose/domains); un dominio creado después del
  # despliegue no se aplica hasta el siguiente (validado en la X230: 404).
  hli_busy "Desplegando vaultwarden en Dokploy..."
  local domain_ok=1
  if ! composeId="$(dokploy_compose_create_or_update "$environment_id" "vaultwarden" "$compose_file" "$env_line")"; then
    msg "Falló la creación del servicio Vaultwarden vía la API de Dokploy. Revise las credenciales y el panel."
    rm -f "$compose_file"
    return 1
  fi
  dokploy_domain_ensure "$composeId" "vaultwarden" "$domain" 80 false none >/dev/null || domain_ok=0
  if ! dokploy_compose_deploy "$composeId" >/dev/null; then
    msg "Falló el despliegue de Vaultwarden vía la API de Dokploy. Revise las credenciales y el panel."
    rm -f "$compose_file"
    return 1
  fi
  rm -f "$compose_file"

  # Puerto 80 del propio contenedor (Traefik enruta hacia adentro de la red
  # "dokploy-network"); certificateType "none" a propósito: sin un dominio
  # públicamente resoluble todavía (eso es v2.4), pedir Let's Encrypt
  # fallaría el desafío HTTP-01. Ver INCERTIDUMBRE en lib/dokploy_api.sh.
  [[ "$domain_ok" -eq 1 ]] || msg "Vaultwarden se desplegó, pero no se pudo configurar el dominio '$domain' en Traefik vía la API de Dokploy. Configúrelo desde el panel (pestaña Dominios del compose 'vaultwarden') y vuelva a desplegar."

  local status_note
  if service_wait_active vaultwarden 120; then
    status_note="Vaultwarden está corriendo."
  else
    status_note="Vaultwarden no terminó de arrancar dentro de los 120 segundos de espera. Puede seguir iniciando: revise el panel de Dokploy."
  fi

  msg "Vaultwarden desplegado (composeId=$composeId).\n\n$status_note\n\nDominio: http://$domain (solo LAN por ahora; apunte ese nombre a la IP del servidor). El registro público está deshabilitado (SIGNUPS_ALLOWED=false): cree el primer usuario desde $domain/admin con la contraseña que acaba de definir, usando 'Invite User'.\n\nHTTPS real y acceso público llegan en la fase v2.4 (Cloudflare Tunnel)."

  mark_done vaultwarden
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _vaultwarden_main
fi
