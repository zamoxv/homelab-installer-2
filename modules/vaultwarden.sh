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
# genera el ADMIN_TOKEN como hash Argon2id PHC con la propia CLI de
# Vaultwarden y despliega el compose (lib/compose.sh) vía la API de Dokploy
# (lib/dokploy_api.sh), corriendo antes la validación canaria obligatoria
# (lib/canary.sh) si todavía no se hizo.
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

# Genera (o reutiliza, si ya hay uno guardado y el usuario no pide rotarlo)
# el ADMIN_TOKEN como hash Argon2id PHC, con la propia CLI de Vaultwarden
# ('vaultwarden hash', ver github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page,
# verificado 2026-09-29): ESA CLI exige una terminal real (usa
# rpassword::prompt_password dos veces; con stdin sin tty directamente
# entra en pánico) — por eso se corre heredando la terminal del módulo
# (TUI=yes) con 'docker run --rm -it', nunca con la contraseña por stdin/
# argv. La salida se espeja a un archivo temporal con 'tee' (el usuario
# sigue viendo los prompts en pantalla) para poder extraer la línea
# "ADMIN_TOKEN=<hash>" sin perder la interactividad.
#
# Guarda el hash en /etc/hli2/vaultwarden.env (root-only 0600,
# lib/secrets.sh). Nunca se loguea ni se imprime el valor.
#
# 'docker run -it' asigna una pty al proceso del contenedor: con ONLCR
# (el modo normal de una pty) cada '\n' que escribe 'vaultwarden hash' sale
# convertido en '\r\n'. 'tee'/'grep' solo parten líneas por '\n', así que el
# '\r' queda pegado AL FINAL de la línea capturada — un hallazgo de una
# revisión de seguridad posterior a la primera versión de v2.3: la
# validación anterior (regex solo anclada al PRINCIPIO, '^\$argon2id\$') no
# lo detectaba, así que un ADMIN_TOKEN con un '\r' de sobra podía guardarse
# y desplegarse tal cual, dejando el login de /admin roto en Dokploy (el
# hash real que compara Vaultwarden nunca coincide con uno que tiene un
# byte extra). Se limpia con 'tr -d "\r"' ANTES de cualquier otra cosa, y se
# valida con una regex ANCLADA A AMBOS LADOS (^...$) contra la forma
# completa de un PHC Argon2id, no solo el prefijo.
_vaultwarden_ensure_admin_token() {
  if secret_file_exists vaultwarden; then
    confirm "Ya hay un ADMIN_TOKEN guardado para Vaultwarden.\n\n¿Generar uno nuevo? (rota el token: tendrá que volver a entrar al panel /admin con el nuevo)." \
      || return 0
  fi

  msg "A continuación se le pedirá dos veces una contraseña para el panel de administración de Vaultwarden (/admin).\n\nEsto corre 'docker run --rm -it vaultwarden/server /vaultwarden hash' en esta misma terminal: la contraseña NUNCA se guarda en texto plano, se convierte en un hash Argon2id antes de guardarse."

  local tmpfile rc line hash
  # mktemp YA crea el archivo con modo 0600 (solo el usuario que corre el
  # módulo puede leerlo) ANTES de que 'tee' escriba nada — 'tee' abre y
  # escribe sobre el archivo existente, nunca lo re-crea con otro modo.
  tmpfile="$(mktemp)"
  if hli_docker run --rm -it vaultwarden/server /vaultwarden hash --preset owasp | tee "$tmpfile"; then
    rc=0
  else
    rc=$?
  fi
  line="$(tr -d '\r' < "$tmpfile" 2>/dev/null | grep '^ADMIN_TOKEN=' | tail -n1)" || line=""
  rm -f "$tmpfile"

  if [[ "$rc" -ne 0 || -z "$line" ]]; then
    msg "No se pudo generar el ADMIN_TOKEN (¿las dos contraseñas no coincidieron?). Se cancela el despliegue de Vaultwarden. Vuelva a correr este módulo para reintentar."
    return 1
  fi

  hash="${line#ADMIN_TOKEN=}"
  # 'vaultwarden hash' imprime el valor entre comillas simples
  # (ADMIN_TOKEN='$argon2id$...', ver src/main.rs y PR
  # dani-garcia/vaultwarden#3289): quitar exactamente una capa, si está.
  if [[ "$hash" == \'*\' ]]; then
    hash="${hash#\'}"
    hash="${hash%\'}"
  fi
  if [[ ! "$hash" =~ ^\$argon2id\$v=[0-9]+\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$ ]]; then
    msg "El valor generado no tiene la forma completa de un hash Argon2id PHC (\$argon2id\$v=..\$m=..,t=..,p=..\$salt\$hash). Se cancela por seguridad: nunca se guarda un ADMIN_TOKEN que no se pueda confirmar como hash válido."
    return 1
  fi

  secret_file_write vaultwarden "ADMIN_TOKEN=${hash}"
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
  if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "vaultwarden" "$compose_file" "$env_line")"; then
    msg "Falló el despliegue de Vaultwarden vía la API de Dokploy. Revise las credenciales y el panel."
    rm -f "$compose_file"
    return 1
  fi
  rm -f "$compose_file"

  # Puerto 80 del propio contenedor (Traefik enruta hacia adentro de la red
  # "dokploy-network"); certificateType "none" a propósito: sin un dominio
  # públicamente resoluble todavía (eso es v2.4), pedir Let's Encrypt
  # fallaría el desafío HTTP-01. Ver INCERTIDUMBRE en lib/dokploy_api.sh.
  dokploy_domain_ensure "$composeId" "vaultwarden" "$domain" 80 false none \
    || msg "Vaultwarden se desplegó, pero no se pudo configurar el dominio '$domain' en Traefik vía la API de Dokploy. Puede configurarlo a mano desde el panel (pestaña Dominios del compose 'vaultwarden')."

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
