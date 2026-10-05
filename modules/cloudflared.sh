#!/usr/bin/env bash
# HLI-MODULE: cloudflared
# HLI-DESC: Cloudflare Tunnel (acceso público sin abrir puertos, vía API de Dokploy)
# HLI-ORDER: 66
# HLI-DEFAULT: no
# HLI-TUI: yes
# HLI-REQUIERE: dokploy-api
#
# Conector 'cloudflared' de un túnel ADMINISTRADO REMOTAMENTE: el usuario crea
# el túnel en el panel de Cloudflare (Zero Trust -> Networks -> Tunnels) y
# este módulo le pide el token, lo guarda root-only en
# /etc/hli2/cloudflared.env (lib/secrets.sh) y despliega el compose de
# compose/cloudflared/ vía la API de Dokploy, con el token por el canal "env"
# entre comillas simples (dotenv_single_quoted). Las rutas públicas se crean
# a mano en el panel de Cloudflare: al final se muestran, en orden.
#
# HLI-DEFAULT: no, a propósito: necesita una cuenta y un túnel creados por el
# usuario antes, así que no debe dispararse dentro de "instalar todo".
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

# Forma del token de un túnel administrado remotamente: Base64 (estándar) de
# un JSON {"a":<cuenta>,"t":<id del túnel>,"s":<secreto>}, así que empieza con
# "eyJ" ('{"'). Se valida un charset seguro (nada que pueda romper el
# dotenv ni el compose: sin comillas, espacios, '$' ni saltos de línea) y,
# además, que decodifique a un JSON con esas tres claves. Nunca se imprime.
_cloudflared_valid_token() {
  local t="$1" b64 pad
  [[ "$t" =~ ^eyJ[A-Za-z0-9+/_-]{40,2000}={0,2}$ ]] || return 1
  b64="${t//_//}"; b64="${b64//-/+}"; b64="${b64%%=*}"
  case $(( ${#b64} % 4 )) in
    2) pad="==" ;;
    3) pad="=" ;;
    0) pad="" ;;
    *) return 1 ;;
  esac
  printf '%s%s' "$b64" "$pad" | base64 -d 2>/dev/null | jq -e 'has("a") and has("t") and has("s")' >/dev/null 2>&1
}

# Pide el token (o reutiliza el guardado) y lo deja guardado. Deja el valor
# en el archivo root-only; el llamador lo relee con secret_get.
_cloudflared_ensure_token() {
  if secret_file_exists cloudflared && secret_get cloudflared TUNNEL_TOKEN >/dev/null 2>&1; then
    confirm "Ya hay un token de túnel guardado para Cloudflare.\n\n¿Reemplazarlo por uno nuevo? (Elija 'No' para reutilizar el guardado.)" \
      || return 0
  fi

  msg "Antes de continuar, cree el túnel en Cloudflare:\n\n1. Panel de Cloudflare -> Zero Trust -> Networks -> Tunnels -> 'Create a tunnel' (tipo Cloudflared).\n2. En 'Install and run connectors' elija Docker: el comando muestra '--token' seguido de una cadena larga que empieza con 'eyJ'. Ese es el token.\n3. No ejecute ese comando: el HLI 2 despliega el conector por usted. Solo copie el token (también sirve pegar el comando completo).\n\nEl dominio debe tener su DNS en Cloudflare."

  local token
  token=$(password_box "Cloudflare Tunnel — token" "Pegue el token del túnel (cadena que empieza con 'eyJ'). No se muestra en pantalla ni se registra en logs.") \
    || { msg "Se cancela el despliegue de Cloudflare Tunnel: no se ingresó ningún token."; return 1; }

  # Si pegó el comando completo ('cloudflared service install eyJ...' o
  # 'docker run ... tunnel --no-autoupdate run --token eyJ...'), el token es
  # el último campo.
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"
  token="${token##*[[:space:]]}"

  if ! _cloudflared_valid_token "$token"; then
    token=""
    msg "El valor ingresado no tiene la forma de un token de túnel de Cloudflare (cadena Base64 que empieza con 'eyJ' y decodifica a un JSON con las claves a, t y s). Se cancela el despliegue: copie de nuevo el token desde el panel de Cloudflare y vuelva a correr este módulo."
    return 1
  fi

  if ! secret_file_write cloudflared "TUNNEL_TOKEN=${token}"; then
    token=""
    msg "No se pudo guardar el token en /etc/hli2/cloudflared.env. Se cancela el despliegue de Cloudflare Tunnel."
    return 1
  fi
  token=""
  log "Token de Cloudflare Tunnel guardado en /etc/hli2/cloudflared.env (no se loguea el valor)."
  return 0
}

_cloudflared_main() {
  _cloudflared_ensure_token || return 1

  local token
  token="$(secret_get cloudflared TUNNEL_TOKEN)" || { msg "No se pudo leer el token guardado de Cloudflare Tunnel. Se cancela el despliegue."; return 1; }

  dokploy_preflight || return 1

  local project_json environment_id compose_file composeId env_line
  project_json="$(dokploy_project_find_or_create)" || { msg "No se pudo crear/encontrar el proyecto 'homelab' en Dokploy."; return 1; }
  environment_id="$(dokploy_environment_default_id "$project_json")" || { msg "No se pudo resolver el ambiente por defecto del proyecto 'homelab' en Dokploy."; return 1; }

  compose_file="$(mktemp)"
  if ! compose_render_cloudflared > "$compose_file"; then
    msg "No se pudo renderizar el compose de Cloudflare Tunnel."
    rm -f "$compose_file"
    return 1
  fi

  env_line="$(dotenv_single_quoted TUNNEL_TOKEN "$token")" || {
    token=""; rm -f "$compose_file"
    msg "El token guardado tiene un formato inesperado. Vuelva a correr el módulo y reemplácelo."
    return 1
  }
  token=""

  if ! composeId="$(dokploy_compose_deploy_full "$environment_id" "cloudflared" "$compose_file" "$env_line")"; then
    env_line=""; rm -f "$compose_file"
    msg "Falló el despliegue de Cloudflare Tunnel vía la API de Dokploy. Revise las credenciales y el panel."
    return 1
  fi
  env_line=""
  rm -f "$compose_file"

  local status_note
  if service_wait_active cloudflared 120; then
    status_note="El conector está corriendo. En el panel de Cloudflare el túnel debe pasar a 'Healthy' en un minuto."
  else
    status_note="El conector no terminó de arrancar dentro de los 120 segundos de espera. Revise el panel de Dokploy y los logs del contenedor 'cloudflared'."
  fi

  local ip
  ip="$(get_ip 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="<IP del servidor>"

  msg "Cloudflare Tunnel desplegado (composeId=$composeId).\n\n$status_note\n\nAhora cree los nombres públicos en el panel de Cloudflare: Zero Trust -> Networks -> Tunnels -> su túnel -> Edit -> Published application routes -> Add. Cree las rutas en ESTE orden (la primera que coincide gana; la de /admin tiene que quedar antes que la general de vault):\n\n1. vault.<dominio>  ruta ^/admin  ->  tipo HTTP_STATUS, URL 404\n2. vault.<dominio>  ->  tipo HTTP, URL dokploy-traefik:80\n3. cloud.<dominio>  ->  tipo HTTP, URL dokploy-traefik:80\n4. casa.<dominio>  ->  tipo HTTP, URL ${ip}:8123"

  msg "Notas:\n\n- Lo que no esté en esa lista no existe desde Internet (Cloudflare responde 404).\n- Cada nombre también debe existir como dominio en Dokploy (lo crean los módulos vaultwarden y opencloud); Home Assistant va directo a la IP de la LAN.\n- Ningún puerto del router se abre: el conector solo hace conexiones salientes.\n- Antes de publicar Home Assistant active 2FA y revise la sección de proxy y bloqueo de IP del ROADMAP (v2.4a)."

  mark_done cloudflared
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _cloudflared_main
fi
