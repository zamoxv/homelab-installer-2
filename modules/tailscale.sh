#!/usr/bin/env bash
# HLI-MODULE: tailscale
# HLI-DESC: Tailscale (VPN privada nativa, acceso remoto a Dokploy/Jellyfin/Samba)
# HLI-ORDER: 67
# HLI-DEFAULT: no
# HLI-TUI: yes
#
# Instala Tailscale en el host (no en contenedor) desde su repositorio apt
# oficial para Ubuntu 24.04 (noble), exactamente como lo documenta Tailscale
# (kb 1187, "Install Tailscale on Ubuntu 24.04"): clave firmada en
# /usr/share/keyrings/tailscale-archive-keyring.gpg + lista de fuentes en
# /etc/apt/sources.list.d/tailscale.list. NUNCA se canaliza un script remoto a
# sh. Luego corre 'sudo tailscale up' en primer plano (imprime la URL de inicio
# de sesión en la terminal) y muestra la IP y el nombre MagicDNS.
#
# HLI-DEFAULT: no: requiere una cuenta de Tailscale y un navegador para
# iniciar sesión, así que no debe dispararse dentro de "instalar todo".
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

# Overrides solo para tests (mismo criterio que HLI2_SECRETS_DIR).
TAILSCALE_KEYRING="${HLI2_TAILSCALE_KEYRING:-/usr/share/keyrings/tailscale-archive-keyring.gpg}"
TAILSCALE_LIST="${HLI2_TAILSCALE_LIST:-/etc/apt/sources.list.d/tailscale.list}"
TAILSCALE_REPO_BASE="https://pkgs.tailscale.com/stable/ubuntu"
TAILSCALE_CODENAME="noble"

_tailscale_installed() {
  command -v tailscale >/dev/null 2>&1
}

# ¿Hay sesión iniciada? 'tailscale status' sale 0 solo con el nodo conectado
# a la tailnet (con sesión cerrada o sin iniciar imprime "Logged out." y sale
# distinto de 0).
_tailscale_logged_in() {
  sudo tailscale status >/dev/null 2>&1
}

_tailscale_ip() {
  sudo tailscale ip -4 2>/dev/null | head -n1
}

# Nombre MagicDNS del nodo (sin el punto final).
_tailscale_dnsname() {
  local n
  n="$(sudo tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null)" || n=""
  printf '%s' "${n%.}"
}

# Descarga $1 (URL) a un archivo temporal propio (mktemp: 0600, del usuario) y
# lo instala con 'sudo install' en $2 (modo 0644). Nada de 'sudo tee' sobre
# archivos del usuario (fs.protected_regular) ni de 'curl | sh'. Si $3 es una
# función, valida con ella el archivo descargado antes de instalarlo.
_tailscale_fetch_install() {
  local url="$1" dest="$2" validator="${3:-}" tmp
  tmp="$(mktemp)"
  if ! curl -fsSL -o "$tmp" "$url" || [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -n "$validator" ]] && ! "$validator" "$tmp"; then
    rm -f "$tmp"
    return 2
  fi
  sudo install -m 0644 "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# La lista oficial es un comentario más una línea 'deb [signed-by=<keyring>]
# https://pkgs.tailscale.com/stable/ubuntu noble main'. Se acepta solo eso:
# si Tailscale cambiara el formato o algo interceptara la descarga, no se
# instala una fuente apt desconocida.
_tailscale_list_ok() {
  local f="$1" line n=0
  # '|| [[ -n "$line" ]]': no perder una última línea sin salto de línea final.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    n=$(( n + 1 ))
    [[ "$line" == "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] ${TAILSCALE_REPO_BASE} ${TAILSCALE_CODENAME} main" ]] || return 1
  done < "$f"
  [[ "$n" -eq 1 ]]
}

_tailscale_install() {
  local osr="${HLI2_OS_RELEASE_FILE:-/etc/os-release}" cn=""
  if [[ -r "$osr" ]]; then
    cn="$(sed -n 's/^VERSION_CODENAME=//p' "$osr" | head -n1 | tr -d '"')" || cn=""
  fi
  # Falla cerrado: sin poder leer la versión, no se agrega ningún repositorio.
  if [[ "$cn" != "$TAILSCALE_CODENAME" ]]; then
    msg "Este módulo solo está validado para Ubuntu 24.04 ('$TAILSCALE_CODENAME'); este equipo es '${cn:-desconocido}'. Se cancela la instalación de Tailscale para no agregar un repositorio equivocado."
    return 1
  fi

  command -v curl >/dev/null 2>&1 || hli_apt install curl >/dev/null 2>&1 || true
  command -v curl >/dev/null 2>&1 || { msg "Falta 'curl' y no se pudo instalar. Se cancela la instalación de Tailscale."; return 1; }

  hli_busy "Agregando el repositorio oficial de Tailscale e instalando el paquete..."
  sudo install -d -m 0755 "$(dirname "$TAILSCALE_KEYRING")" "$(dirname "$TAILSCALE_LIST")"

  _tailscale_fetch_install "${TAILSCALE_REPO_BASE}/${TAILSCALE_CODENAME}.noarmor.gpg" "$TAILSCALE_KEYRING" \
    || { msg "No se pudo descargar la clave del repositorio de Tailscale. Revise la conexión a Internet y vuelva a correr el módulo."; return 1; }

  local rc=0
  _tailscale_fetch_install "${TAILSCALE_REPO_BASE}/${TAILSCALE_CODENAME}.tailscale-keyring.list" "$TAILSCALE_LIST" _tailscale_list_ok || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    msg "La lista de fuentes descargada de Tailscale no tiene el formato esperado. Se cancela por seguridad: no se agregó ningún repositorio."
    return 1
  elif [[ "$rc" -ne 0 ]]; then
    msg "No se pudo descargar la lista de fuentes de Tailscale. Revise la conexión a Internet y vuelva a correr el módulo."
    return 1
  fi

  hli_apt update >/dev/null 2>&1 || { msg "Falló 'apt-get update' tras agregar el repositorio de Tailscale. Revise /var/log/apt y vuelva a correr el módulo."; return 1; }
  hli_apt install tailscale >/dev/null 2>&1 || { msg "Falló la instalación del paquete 'tailscale'. Revise /var/log/apt y vuelva a correr el módulo."; return 1; }
  _tailscale_installed || { msg "El paquete 'tailscale' se instaló pero el comando no está disponible. Revise la instalación."; return 1; }
  sudo systemctl enable --now tailscaled >/dev/null 2>&1 || true
  log "Tailscale instalado desde el repositorio oficial (${TAILSCALE_CODENAME})."
}

_tailscale_show_status() {
  local ip name
  ip="$(_tailscale_ip)" || ip=""
  name="$(_tailscale_dnsname)"
  local lan
  lan="$(get_ip 2>/dev/null || true)"
  msg "Tailscale activo en este servidor.\n\nIP de Tailscale: ${ip:-N/D}\nNombre MagicDNS: ${name:-N/D}\n\nPara entrar desde fuera de casa: instale la app de Tailscale en el teléfono o PC (tailscale.com/download), inicie sesión con la MISMA cuenta y active la VPN. Ejemplos de uso:\n\n- Panel de Dokploy: http://${ip:-<IP Tailscale>}:3000\n- Jellyfin: http://${ip:-<IP Tailscale>}:8096\n- Samba: smb://${ip:-<IP Tailscale>}\n\nLa IP de Tailscale (100.x.y.z) no cambia aunque cambie de red. En casa siguen valiendo las direcciones de la LAN${lan:+ ($lan)}."
}

# ¿AdGuard escucha DNS en todas las interfaces (0.0.0.0:53)? Con network_mode
# host lo hace, y por eso también responde en la IP de Tailscale.
_tailscale_adguard_listening() {
  ss -H -lnu 'sport = :53' 2>/dev/null | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\*):53([[:space:]]|$)'
}

_tailscale_adguard_step() {
  confirm "¿Usar AdGuard Home como DNS de la tailnet?\n\nAsí el teléfono y los equipos con Tailscale bloquean publicidad también fuera de casa. Se hace a mano en el panel de administración de Tailscale; este módulo solo lo verifica y lo explica." \
    || return 0

  local ip
  ip="$(_tailscale_ip)" || ip=""
  if [[ -z "$ip" ]]; then
    msg "No se pudo obtener la IP de Tailscale; no se puede explicar el paso con la IP real. Vuelva a correr el módulo."
    return 0
  fi

  if ! _tailscale_adguard_listening; then
    msg "AdGuard Home no parece estar escuchando DNS en 0.0.0.0:53. Instale el módulo 'adguard' (o revise que esté activo) y vuelva a correr este módulo antes de apuntar la tailnet a él."
    return 0
  fi

  msg "AdGuard escucha en 0.0.0.0:53, así que responde también en la IP de Tailscale ($ip).\n\nPasos en https://login.tailscale.com/admin/dns :\n\n1. Sección 'Nameservers' -> 'Add nameserver' -> 'Custom'.\n2. Escriba $ip y guarde.\n3. Active 'Override DNS servers' para que todos los dispositivos lo usen.\n\nAtención: si el servidor está apagado, los dispositivos con Tailscale pierden la resolución DNS (con la opción 'Override' activa)."
}

_tailscale_main() {
  if _tailscale_installed && _tailscale_logged_in; then
    _tailscale_show_status
    mark_done tailscale
    return 0
  fi

  if ! _tailscale_installed; then
    _tailscale_install || return 1
  fi

  msg "Ahora se iniciará sesión en Tailscale.\n\nAl aceptar, el comando 'tailscale up' mostrará en la terminal una dirección (https://login.tailscale.com/a/...). Ábrala en el navegador de cualquier dispositivo, inicie sesión (o cree la cuenta) y apruebe el equipo. El comando termina solo cuando se completa el inicio de sesión.\n\nSi el enlace da 'Error 404', no use Ctrl+clic: seleccione la URL a mano, o en otra terminal corra:\n\nsudo tailscale status\n\ny copie la URL que muestra."

  # Pantalla limpia: sin esto, la salida de 'tailscale up' se imprime sobre
  # los restos del cuadro de dialog y la URL queda tapada o cortada (Ctrl+clic
  # abría un enlace incompleto en el servidor real, Tailscale respondía 404).
  clear 2>/dev/null || printf '\033[2J\033[H'
  printf '\nIniciando sesión en Tailscale. Abra en el navegador la URL que aparece abajo:\n\n'

  # Primer plano, SIN $(...): la URL de login debe verse en la terminal y el
  # comando espera a que el usuario complete el inicio de sesión.
  # --accept-dns=false: el servidor no usa el DNS de Tailscale (MagicDNS) para
  # sí mismo. Es el DNS de la casa (AdGuard en el 53, con systemd-resolved ya
  # ajustado por el HLI) y Tailscale no debe tocar su resolución. MagicDNS
  # sigue funcionando en los demás dispositivos de la tailnet.
  if ! sudo tailscale up --accept-dns=false; then
    msg "'tailscale up' falló o se canceló antes de completar el inicio de sesión. Vuelva a correr este módulo para reintentar."
    return 1
  fi

  if ! _tailscale_logged_in; then
    msg "Tailscale no quedó con la sesión iniciada. Vuelva a correr este módulo para reintentar."
    return 1
  fi

  _tailscale_show_status
  _tailscale_adguard_step
  mark_done tailscale
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _tailscale_main
fi
