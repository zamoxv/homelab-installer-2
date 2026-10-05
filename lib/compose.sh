#!/usr/bin/env bash
# Renderiza los compose de compose/<servicio>/docker-compose.yml (plantillas
# con marcadores __EN_MAYUSCULAS__) a partir del registro de servicios
# (services/*.conf) y del estado real del host (usuario, grupo de media,
# raíces de media). Cada compose_render_<servicio> imprime el YAML final por
# stdout; el módulo llamador decide dónde escribirlo.
set -euo pipefail

# Líneas "<indent>- <root>:<root>" (una por raíz de media montada), montaje
# en rutas IDÉNTICAS dentro y fuera del contenedor (decisión del roadmap).
_compose_media_volume_lines() {
  local indent="$1" root out=""
  while read -r root; do
    [[ -n "$root" ]] || continue
    out+="${indent}- ${root}:${root}"$'\n'
  done < <(media_roots)
  printf '%s' "${out%$'\n'}"
}

# Sustituye __CLAVE__ por valor en el contenido de $1 (stdin), vía bash
# ${var/pat/repl} (reemplazo literal, no regex: seguro para rutas con '/'
# sin escapar nada). Uso: _compose_subst __CLAVE__ "$valor" <<<"$contenido"
_compose_subst() {
  local marker="$1" value="$2" content
  content="$(cat)"
  # '%s\n': un '$(cat)' de la SIGUIENTE etapa de la tubería (si la hay) le
  # vuelve a comer este salto de línea, así que solo sobrevive el de la
  # ÚLTIMA etapa — el resultado final del render siempre termina con un
  # único '\n', en vez de sin ninguno (un YAML sin salto final es válido
  # para casi todo, pero no es lo que produciría cualquier editor/plantilla
  # normal, y algunos parsers se quejan).
  printf '%s\n' "${content//$marker/$value}"
}

# --- Jellyfin ----------------------------------------------------------------

compose_render_jellyfin() {
  local template="$SCRIPT_DIR/compose/jellyfin/docker-compose.yml"
  [[ -f "$template" ]] || { echo "ERROR: falta $template" >&2; return 1; }

  local uid gid render_gid port appdata devices_block="" groupadd_block=""
  uid="$(id -u "$SERVER_USER")" || { echo "ERROR: no existe el usuario '$SERVER_USER'." >&2; return 1; }
  # '|| true': bajo pipefail, si 'getent' falla (grupo inexistente) pero
  # 'cut' igual sale con éxito (stdin vacío no es un error para 'cut'), la
  # tubería completa reporta el código de 'getent' -> sin este '|| true' el
  # 'set -e' del archivo aborta ACÁ MISMO, antes de que el chequeo
  # "$gid" vacío de la línea siguiente pueda dar el mensaje amigable.
  gid="$(getent group "$MEDIA_GROUP" | cut -d: -f3)" || true
  [[ -n "$gid" ]] || { echo "ERROR: no existe el grupo '$MEDIA_GROUP'." >&2; return 1; }
  port="$(service_get jellyfin PORT)"
  appdata="$APPDATA_ROOT"

  render_gid="$(getent group render 2>/dev/null | cut -d: -f3)" || render_gid=""
  if [[ -e /dev/dri && -n "$render_gid" ]]; then
    devices_block=$'    devices:\n      - /dev/dri:/dev/dri'
    groupadd_block=$'    group_add:\n      - "'"$render_gid"'"'
  fi

  local media_lines
  media_lines="$(_compose_media_volume_lines "      ")"

  cat "$template" \
    | _compose_subst "__UID__" "$uid" \
    | _compose_subst "__GID__" "$gid" \
    | _compose_subst "__PORT__" "$port" \
    | _compose_subst "__APPDATA__" "$appdata" \
    | _compose_subst "__DEVICES_BLOCK__" "$devices_block" \
    | _compose_subst "__GROUPADD_BLOCK__" "$groupadd_block" \
    | _compose_subst "__MEDIA_VOLUMES__" "$media_lines"
}

# Zona horaria del host, en formato IANA (ej. "America/Argentina/Cordoba").
# 'timedatectl' es lo habitual en Ubuntu; /etc/timezone es el respaldo. Si
# ninguno da algo con forma válida, UTC (nunca un valor vacío o corrupto en
# el compose). La usan qBittorrent y Home Assistant.
_compose_tz() {
  local tz
  tz="$(timedatectl show -p Timezone --value 2>/dev/null)" || tz=""
  if [[ -z "$tz" ]]; then
    tz="$(cat /etc/timezone 2>/dev/null)" || tz=""
  fi
  [[ "$tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || tz="UTC"
  printf '%s' "$tz"
}

# --- qBittorrent ---------------------------------------------------------------

compose_render_qbittorrent() {
  local template="$SCRIPT_DIR/compose/qbittorrent/docker-compose.yml"
  [[ -f "$template" ]] || { echo "ERROR: falta $template" >&2; return 1; }

  local uid gid port tz appdata
  uid="$(id -u "$SERVER_USER")" || { echo "ERROR: no existe el usuario '$SERVER_USER'." >&2; return 1; }
  # Ver el comentario equivalente en compose_render_jellyfin: sin '|| true',
  # un MEDIA_GROUP inexistente aborta acá por 'pipefail' (código de 'getent'
  # propagado aunque 'cut' salga bien) antes del chequeo de la línea siguiente.
  gid="$(getent group "$MEDIA_GROUP" | cut -d: -f3)" || true
  [[ -n "$gid" ]] || { echo "ERROR: no existe el grupo '$MEDIA_GROUP'." >&2; return 1; }
  port="$(service_get qbittorrent PORT)"
  appdata="$APPDATA_ROOT"
  tz="$(_compose_tz)"

  local media_lines
  media_lines="$(_compose_media_volume_lines "      ")"

  cat "$template" \
    | _compose_subst "__UID__" "$uid" \
    | _compose_subst "__GID__" "$gid" \
    | _compose_subst "__PORT__" "$port" \
    | _compose_subst "__TZ__" "$tz" \
    | _compose_subst "__APPDATA__" "$appdata" \
    | _compose_subst "__MEDIA_VOLUMES__" "$media_lines"
}

# --- AdGuard Home ----------------------------------------------------------

compose_render_adguard() {
  local template="$SCRIPT_DIR/compose/adguard/docker-compose.yml"
  [[ -f "$template" ]] || { echo "ERROR: falta $template" >&2; return 1; }
  cat "$template" | _compose_subst "__APPDATA__" "$APPDATA_ROOT"
}

# --- Vaultwarden -------------------------------------------------------------

# $1 = dominio (sin esquema, ej. "vault.midominio.com"). El ADMIN_TOKEN
# NUNCA pasa por acá: el template ya trae "${ADMIN_TOKEN}" literal (lo
# sustituye Dokploy vía su campo "env", ver dokploy_compose_create_or_update
# y modules/vaultwarden.sh).
compose_render_vaultwarden() {
  local template="$SCRIPT_DIR/compose/vaultwarden/docker-compose.yml" domain="$1"
  [[ -f "$template" ]] || { echo "ERROR: falta $template" >&2; return 1; }
  [[ -n "$domain" ]] || { echo "ERROR: compose_render_vaultwarden necesita un dominio." >&2; return 1; }
  cat "$template" \
    | _compose_subst "__APPDATA__" "$APPDATA_ROOT" \
    | _compose_subst "__DOMAIN__" "$domain"
}

# --- Home Assistant ----------------------------------------------------------

compose_render_homeassistant() {
  local template="$SCRIPT_DIR/compose/homeassistant/docker-compose.yml"
  [[ -f "$template" ]] || { echo "ERROR: falta $template" >&2; return 1; }

  local tz dbus_block=""
  tz="$(_compose_tz)"
  # /run/dbus: SOLO si existe en el host (ver comentario del template sobre
  # por qué no se usa "privileged" ni se monta siempre).
  if [[ -e /run/dbus ]]; then
    dbus_block="      - /run/dbus:/run/dbus:ro"
  fi

  cat "$template" \
    | _compose_subst "__APPDATA__" "$APPDATA_ROOT" \
    | _compose_subst "__TZ__" "$tz" \
    | _compose_subst "__DBUS_BLOCK__" "$dbus_block"
}

# --- OpenCloud -----------------------------------------------------------------

# $1 = dominio público futuro (sin esquema). El INITIAL_ADMIN_PASSWORD
# NUNCA pasa por acá: el template ya trae "${INITIAL_ADMIN_PASSWORD}"
# literal (lo sustituye Dokploy vía su campo "env", ver
# dokploy_compose_create_or_update y modules/opencloud.sh).
compose_render_opencloud() {
  local template="$SCRIPT_DIR/compose/opencloud/docker-compose.yml" domain="$1"
  [[ -f "$template" ]] || { echo "ERROR: falta $template" >&2; return 1; }
  [[ -n "$domain" ]] || { echo "ERROR: compose_render_opencloud necesita un dominio." >&2; return 1; }

  local uid gid
  uid="$(id -u "$SERVER_USER")" || { echo "ERROR: no existe el usuario '$SERVER_USER'." >&2; return 1; }
  gid="$(id -g "$SERVER_USER")" || { echo "ERROR: no se pudo resolver el grupo primario de '$SERVER_USER'." >&2; return 1; }

  cat "$template" \
    | _compose_subst "__APPDATA__" "$APPDATA_ROOT" \
    | _compose_subst "__UID__" "$uid" \
    | _compose_subst "__GID__" "$gid" \
    | _compose_subst "__DOMAIN__" "$domain"
}

# --- Cloudflare Tunnel ---------------------------------------------------------

# Sin sustituciones: el template no lleva dominio ni rutas (viven en el panel
# de Cloudflare) y el TUNNEL_TOKEN NUNCA pasa por acá: el template ya trae
# "${TUNNEL_TOKEN}" literal (lo sustituye Dokploy vía su campo "env", ver
# dokploy_compose_create_or_update y modules/cloudflared.sh).
compose_render_cloudflared() {
  local template="$SCRIPT_DIR/compose/cloudflared/docker-compose.yml"
  [[ -f "$template" ]] || { echo "ERROR: falta $template" >&2; return 1; }
  cat "$template" | _compose_subst "__NONE__" ""
}
