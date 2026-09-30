#!/usr/bin/env bash
# Puerto 53 del host. Adaptado (no copiado literal) de
# homelab-installer/lib/common.sh:269-275 (free_dns_port): HLI v1 es
# referencia de solo lectura, nunca se sourcea ni se importa desde ahí.
set -euo pipefail

# Namespaced con el prefijo 'HLI2_' en TODAS las rutas de sistema (no solo
# el estado): permite que un test apunte esto a rutas de un scratch dir en
# vez de tocar /etc/resolv.conf o systemd-resolved de la máquina real, sin
# arriesgar que una variable ambiental genérica ("DNS_PORT_DROPIN" podría
# existir por casualidad en el entorno de quien corre bootstrap.sh)
# secuestre en silencio estas rutas en producción — mismo criterio que
# LOG_DIR/STATE_DIR en lib/core.sh y DOKPLOY_ENV_FILE en
# lib/dokploy_api.sh. En producción, sin overrides HLI2_*, resuelven a las
# rutas reales de siempre.
DNS_PORT_DROPIN="${HLI2_DNS_PORT_DROPIN:-/etc/systemd/resolved.conf.d/99-hli2.conf}"
DNS_PORT_RESOLVED_CONFD_DIR="${HLI2_DNS_PORT_RESOLVED_CONFD_DIR:-/etc/systemd/resolved.conf.d}"
DNS_PORT_RESOLV_CONF="${HLI2_DNS_PORT_RESOLV_CONF:-/etc/resolv.conf}"
DNS_PORT_STUB_RESOLV_CONF="${HLI2_DNS_PORT_STUB_RESOLV_CONF:-/run/systemd/resolve/resolv.conf}"
DNS_PORT_STATE_DIR="${HLI2_DNS_PORT_STATE_DIR:-$STATE_DIR}"
DNS_PORT_PREV_KIND_FILE="$DNS_PORT_STATE_DIR/dns-port-prev-kind"
DNS_PORT_PREV_TARGET_FILE="$DNS_PORT_STATE_DIR/dns-port-prev-target"
DNS_PORT_PREV_CONTENT_FILE="$DNS_PORT_STATE_DIR/dns-port-prev-resolv.conf"

# ¿El host resuelve nombres ahora mismo? Best-effort: se usa tanto para
# verificar DESPUÉS de tocar el DNS del host (si esto falla, hay que
# revertir YA, antes de dejar el módulo seguir) como, en teoría, para un
# chequeo previo. 'getent hosts' no depende de que exista 'dig'/'host'.
_dns_resolves() {
  getent hosts dokploy.com >/dev/null 2>&1
}

# Libera el puerto 53 que systemd-resolved ocupa por defecto
# (DNSStubListener), imprescindible para que AdGuard (en network_mode: host)
# pueda escuchar DNS en 53. Idempotente: si ya se aplicó antes (existe el
# drop-in), no repite nada ni vuelve a grabar "el estado de antes" (grabarlo
# dos veces podría terminar registrando el propio cambio de HLI 2 como si
# fuera el estado original, rompiendo restore_dns_port()).
#
# FALLA CERRADO si no existe /run/systemd/resolve/resolv.conf: sin ese
# archivo no hay a dónde repuntar /etc/resolv.conf con los upstreams reales,
# y desactivar el stub de todos modos dejaría el host SIN resolución DNS —
# peor que no instalar AdGuard ahora. Nunca se asume que "no está" es
# seguro de ignorar.
#
# Tras aplicar el cambio, VERIFICA que el host todavía resuelve nombres; si
# no, revierte con restore_dns_port() antes de devolver error (nunca deja el
# host sin DNS aunque el llamador ignore el código de salida).
free_dns_port() {
  systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0

  [[ -f "$DNS_PORT_DROPIN" ]] && return 0   # ya aplicado antes, idempotente

  if [[ ! -e "$DNS_PORT_STUB_RESOLV_CONF" ]]; then
    echo "ERROR: no existe $DNS_PORT_STUB_RESOLV_CONF (systemd-resolved no expone los upstreams reales en este host). No se libera el puerto 53: dejar el host sin DNS es peor que no instalar AdGuard ahora. Revise 'systemctl status systemd-resolved' manualmente." >&2
    return 1
  fi

  sudo mkdir -p "$DNS_PORT_STATE_DIR"

  # Registrar el estado ANTERIOR de resolv.conf (symlink y su destino, o
  # "era un archivo real") ANTES de tocar nada, para poder revertir.
  if [[ -L "$DNS_PORT_RESOLV_CONF" ]]; then
    echo "symlink" > "$DNS_PORT_PREV_KIND_FILE"
    readlink "$DNS_PORT_RESOLV_CONF" > "$DNS_PORT_PREV_TARGET_FILE" 2>/dev/null || : > "$DNS_PORT_PREV_TARGET_FILE"
  else
    echo "file" > "$DNS_PORT_PREV_KIND_FILE"
    : > "$DNS_PORT_PREV_TARGET_FILE"
    # Era un archivo real: respaldar su CONTENIDO para poder restaurarlo tal
    # cual. Si no se puede respaldar, no se toca nada (falla cerrado).
    if ! sudo cp -a "$DNS_PORT_RESOLV_CONF" "$DNS_PORT_PREV_CONTENT_FILE"; then
      echo "ERROR: no se pudo respaldar $DNS_PORT_RESOLV_CONF. No se libera el puerto 53." >&2
      rm -f "$DNS_PORT_PREV_KIND_FILE" "$DNS_PORT_PREV_TARGET_FILE"
      return 1
    fi
  fi

  sudo mkdir -p "$DNS_PORT_RESOLVED_CONFD_DIR"
  printf '[Resolve]\nDNSStubListener=no\n' | sudo tee "$DNS_PORT_DROPIN" >/dev/null
  sudo ln -sf "$DNS_PORT_STUB_RESOLV_CONF" "$DNS_PORT_RESOLV_CONF"
  sudo systemctl restart systemd-resolved

  # Verificación: si el host se quedó sin poder resolver nombres, revertir
  # YA (no dejar que el llamador siga con AdGuard en un host sin DNS).
  sleep 1
  if ! _dns_resolves; then
    echo "ERROR: tras liberar el puerto 53, el host no puede resolver nombres. Revirtiendo el cambio." >&2
    restore_dns_port
    return 1
  fi

  return 0
}

# Revierte free_dns_port(): quita el drop-in que desactiva el stub de
# systemd-resolved, repunta /etc/resolv.conf al estado que tenía ANTES
# (registrado por free_dns_port), y reinicia systemd-resolved. Idempotente
# (no hace nada si no hay drop-in aplicado). Se llama en CUALQUIER fallo
# posterior a free_dns_port() durante el despliegue de AdGuard (deploy
# fallido, o el contenedor nunca queda activo): nunca dejar el host con el
# puerto 53 liberado pero AdGuard caído/sin desplegar.
restore_dns_port() {
  [[ -f "$DNS_PORT_DROPIN" ]] || return 0

  sudo rm -f "$DNS_PORT_DROPIN"

  if [[ -f "$DNS_PORT_PREV_KIND_FILE" ]]; then
    local kind target
    kind="$(cat "$DNS_PORT_PREV_KIND_FILE" 2>/dev/null)" || kind=""
    if [[ "$kind" == "symlink" ]]; then
      target="$(cat "$DNS_PORT_PREV_TARGET_FILE" 2>/dev/null)" || target=""
      # Sin destino registrado: volver al symlink por defecto de Ubuntu
      # (stub de systemd-resolved, reactivado al quitar el drop-in).
      [[ -n "$target" ]] || target="../run/systemd/resolve/stub-resolv.conf"
      sudo ln -sf "$target" "$DNS_PORT_RESOLV_CONF"
    fi
    # kind == "file": se restaura el contenido respaldado por free_dns_port
    # (sudo rm primero: /etc/resolv.conf es hoy un symlink y 'cp' escribiría
    # a través de él sobre el archivo de systemd-resolved).
    if [[ "$kind" == "file" && -f "$DNS_PORT_PREV_CONTENT_FILE" ]]; then
      sudo rm -f "$DNS_PORT_RESOLV_CONF"
      sudo cp -a "$DNS_PORT_PREV_CONTENT_FILE" "$DNS_PORT_RESOLV_CONF"
    fi
    sudo rm -f "$DNS_PORT_PREV_KIND_FILE" "$DNS_PORT_PREV_TARGET_FILE" "$DNS_PORT_PREV_CONTENT_FILE"
  fi

  sudo systemctl restart systemd-resolved 2>/dev/null || true
}
