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
# INCERTIDUMBRE (marcar para validar en el servidor real): un
# AdGuardHome.yaml "sembrado" a mano con solo http.address/dns.bind_hosts es
# un archivo mínimo, no uno generado por el propio asistente de AdGuard —
# distintas versiones de la imagen pueden seguir mostrando el asistente de
# instalación (para crear el usuario admin) aunque sea ya en el puerto
# correcto. Eso es esperado y no es un bug: solo hay que completarlo una vez
# desde http://<ip>:3053, nunca desde el 3000.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

_adguard_prepare_dirs() {
  sudo mkdir -p "$APPDATA_ROOT/adguard/conf" "$APPDATA_ROOT/adguard/work"
  sudo chown -R root:root "$APPDATA_ROOT/adguard"
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

  if [[ -f "$APPDATA_ROOT/adguard/conf/AdGuardHome.yaml" ]]; then
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
  local yaml="$APPDATA_ROOT/adguard/conf/AdGuardHome.yaml" port
  [[ -f "$yaml" ]] && return 0

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

_adguard_main() {
  _adguard_prepare_dirs
  _adguard_offer_import || true
  _adguard_seed_if_missing

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
  msg "AdGuard Home desplegado (composeId=$composeId).\n\nAdGuard Home está corriendo.\n\nPanel: ${url:-N/D}\n\nSi es la primera vez (sin importar backup), complete el asistente de instalación ahora en ${url:-http://<ip>:$port} y cree la cuenta de administrador."

  mark_done adguard
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap '[[ -n "${IMPORT_WORK_DIR:-}" ]] && importer_cleanup "$IMPORT_WORK_DIR"' EXIT
  _adguard_main
fi
