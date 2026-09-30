#!/usr/bin/env bash
# HLI-MODULE: opencloud
# HLI-DESC: OpenCloud (contenedor, vía API de Dokploy)
# HLI-ORDER: 65
# HLI-DEFAULT: yes
# HLI-TUI: yes
#
# OpenCloud necesita una URL pública fija (OC_URL) para funcionar de verdad
# (cookies/CORS/login), pero la exposición pública real (Cloudflare Tunnel)
# es la fase v2.4. Este módulo igual pide el dominio FUTURO ahora, deja todo
# desplegado y avisa con claridad que el login solo funcionará una vez que
# ese dominio resuelva de verdad y tenga TLS (v2.4) — se puede re-desplegar
# más adelante sin perder datos (compose_render_opencloud es idempotente:
# vuelve a renderizar con el dominio que se le pase).
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

_opencloud_prepare_dirs() {
  local uid gid
  uid="$(id -u "$SERVER_USER")" || { msg "No existe el usuario '$SERVER_USER'."; return 1; }
  gid="$(id -g "$SERVER_USER")" || { msg "No se pudo resolver el grupo primario de '$SERVER_USER'."; return 1; }
  sudo mkdir -p "$APPDATA_ROOT/opencloud/config" "$APPDATA_ROOT/opencloud/data"
  # Uid/gid de SERVER_USER (no MEDIA_GROUP: los datos de OpenCloud no son
  # media) — almacenamiento POSIX plano para que los archivos queden
  # legibles/respaldables desde el host (pedido del roadmap), coherente con
  # el 'user: "__UID__:__GID__"' del compose (lib/compose.sh).
  sudo chown -R "${uid}:${gid}" "$APPDATA_ROOT/opencloud"
}

_opencloud_ask_domain() {
  local domain
  domain=$(input_box "OpenCloud" "Dominio PÚBLICO futuro para OpenCloud (ej: cloud.tu-dominio.com).\n\nOpenCloud necesita una URL fija para funcionar (cookies/login) pero todavía no se expone a Internet (eso es la fase v2.4, Cloudflare Tunnel). El login NO funcionará del todo hasta que ese dominio resuelva de verdad y tenga TLS. Por ahora queda desplegado y accesible solo por Traefik en la LAN; puede volver a correr este módulo más adelante con el mismo dominio.") || return 1
  [[ -n "$domain" ]] || { msg "Dominio vacío: se cancela el despliegue de OpenCloud."; return 1; }
  hli2_valid_hostname "$domain" || { msg "'$domain' no tiene forma de nombre de dominio válido (ej: cloud.tu-dominio.com). Se cancela: vuelva a correr el módulo con un dominio válido."; return 1; }
  printf '%s' "$domain"
}

# La contraseña inicial de administrador (IDM_ADMIN_PASSWORD) SOLO se aplica
# en el primer arranque ('opencloud init'): cambiarla después no tiene
# efecto sin reinicializar el volumen de config (documentado por el propio
# proyecto). Por eso, si ya hay una guardada, se reutiliza sin volver a
# preguntar — volver a pedirla y cambiar el secreto en un redeploy sería
# engañoso (el usuario pensaría que cambió la contraseña real).
_opencloud_ensure_admin_password() {
  if secret_file_exists opencloud; then
    return 0
  fi

  local pass pass2
  pass=$(password_box "OpenCloud" "Contraseña INICIAL del administrador de OpenCloud (mínimo 8 caracteres).\n\nSolo se aplica en el primer arranque; cambiarla más adelante requiere hacerlo desde OpenCloud, no desde acá.") || return 1
  [[ -n "$pass" ]] || { msg "Contraseña vacía: se cancela el despliegue de OpenCloud."; return 1; }
  if [[ "${#pass}" -lt 8 ]]; then
    msg "La contraseña debe tener al menos 8 caracteres. Se cancela: vuelva a correr el módulo para reintentar."
    return 1
  fi
  # Se envía entre comillas simples al .env del compose (ver
  # dotenv_single_quoted): una comilla simple no se puede representar ahí.
  if [[ "$pass" == *"'"* ]]; then
    msg "La contraseña no puede contener comillas simples ('). Se cancela: vuelva a correr el módulo para reintentar."
    return 1
  fi
  pass2=$(password_box "OpenCloud" "Confirme la contraseña:") || return 1
  if [[ "$pass" != "$pass2" ]]; then
    msg "Las contraseñas no coinciden. Se cancela: vuelva a correr el módulo para reintentar."
    return 1
  fi

  secret_file_write opencloud "INITIAL_ADMIN_PASSWORD=${pass}"
  log "INITIAL_ADMIN_PASSWORD de OpenCloud guardada en /etc/hli2/opencloud.env (no se loguea el valor)."
  return 0
}

_opencloud_main() {
  _opencloud_prepare_dirs || return 1

  local domain
  domain="$(_opencloud_ask_domain)" || return 1

  _opencloud_ensure_admin_password || return 1

  local admin_pass
  admin_pass="$(secret_get opencloud INITIAL_ADMIN_PASSWORD)" || { msg "No se pudo leer la contraseña de administrador guardada."; return 1; }

  dokploy_preflight || return 1

  local project_json environment_id compose_file composeId
  project_json="$(dokploy_project_find_or_create)" || { msg "No se pudo crear/encontrar el proyecto 'homelab' en Dokploy."; return 1; }
  environment_id="$(dokploy_environment_default_id "$project_json")" || { msg "No se pudo resolver el ambiente por defecto del proyecto 'homelab' en Dokploy."; return 1; }

  compose_file="$(mktemp)"
  if ! compose_render_opencloud "$domain" > "$compose_file"; then
    msg "No se pudo renderizar el compose de OpenCloud (revise usuario/grupo del servidor)."
    rm -f "$compose_file"
    return 1
  fi

  local env_line
  env_line="$(dotenv_single_quoted INITIAL_ADMIN_PASSWORD "$admin_pass")" || { msg "La contraseña guardada contiene caracteres que no se pueden enviar de forma segura (comilla simple o salto de línea). Vuelva a configurarla."; return 1; }
  if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "opencloud" "$compose_file" "$env_line")"; then
    msg "Falló el despliegue de OpenCloud vía la API de Dokploy. Revise las credenciales y el panel."
    rm -f "$compose_file"
    return 1
  fi
  rm -f "$compose_file"

  # Puerto 9200 del propio contenedor; certificateType "none" a propósito
  # (mismo motivo que Vaultwarden: sin dominio públicamente resoluble
  # todavía, Let's Encrypt fallaría el desafío HTTP-01).
  dokploy_domain_ensure "$composeId" "opencloud" "$domain" 9200 false none \
    || msg "OpenCloud se desplegó, pero no se pudo configurar el dominio '$domain' en Traefik vía la API de Dokploy. Puede configurarlo a mano desde el panel (pestaña Dominios del compose 'opencloud')."

  local status_note
  if service_wait_active opencloud 180; then
    status_note="OpenCloud está corriendo."
  else
    status_note="OpenCloud no terminó de arrancar dentro de los 180 segundos de espera (la primera vez corre 'opencloud init', puede tardar). Puede seguir iniciando: revise el panel de Dokploy."
  fi

  msg "OpenCloud desplegado (composeId=$composeId).\n\n$status_note\n\nDominio configurado: https://$domain\n\nIMPORTANTE: el login completo (cookies seguras, clientes de escritorio/móvil) solo funcionará una vez que ese dominio resuelva de verdad en Internet y tenga TLS válido — eso llega en la fase v2.4 (Cloudflare Tunnel). Por ahora es solo para dejar el servicio desplegado y probado en la LAN.\n\nValide en el servidor real: consumo de RAM del contenedor y los clientes de escritorio/móvil (pendiente, ver ROADMAP.md)."

  mark_done opencloud
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _opencloud_main
fi
