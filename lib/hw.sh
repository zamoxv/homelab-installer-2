#!/usr/bin/env bash
# Detección de hardware y red (best-effort, solo lectura). Usado por el
# dashboard, status y healthcheck.
set -euo pipefail

os_pretty() {
  ( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$(uname -sr)}" )
}

hw_model() {
  local vendor product
  vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"
  product="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  echo "$vendor $product" | xargs
}

hw_cpu() {
  lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n1
}

hw_ram() {
  free -h 2>/dev/null | awk '/Mem:/ {print $2}'
}

hw_disk() {
  local disk size rota typ
  # Puramente informativo: si root_disk() no puede determinar nada (best
  # effort), seguir con "N/D" en vez de abortar el dashboard.
  disk="$(root_disk)" || true
  [[ -z "$disk" ]] && { echo "N/D"; return; }
  size="$(lsblk -dno SIZE "$disk" 2>/dev/null | head -n1)"
  rota="$(lsblk -dno ROTA "$disk" 2>/dev/null | head -n1)"
  [[ "$rota" == "0" ]] && typ="SSD" || typ="HDD"
  echo "$disk ${size:-?} ($typ)"
}

# Barra ASCII del uso de la partición raíz.
space_bar() {
  local pct filled i bar=""
  pct="$(df / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
  pct="${pct:-0}"
  filled=$(( pct * 20 / 100 ))
  for ((i = 0; i < 20; i++)); do
    [[ $i -lt $filled ]] && bar+="#" || bar+="."
  done
  echo "[$bar] ${pct}%"
}

get_ip() {
  hostname -I | awk '{print $1}'
}

detect_iface() {
  if [[ -n "${NETWORK_IFACE:-}" ]]; then
    echo "$NETWORK_IFACE"
    return
  fi
  # Best-effort: bajo 'pipefail', si 'grep' no encuentra ninguna interfaz
  # (nada empieza con en/eth) devuelve código != 0 y arrastraría a toda la
  # tubería; acá no encontrar nada es un resultado válido (vacío), no un
  # error, así que no debe abortar al llamador.
  ip -o link show | awk -F': ' '{print $2}' | grep -E '^(en|eth)' | head -n1 || true
}
