#!/usr/bin/env bash
# HLI-MODULE: dokploy
# HLI-DESC: Docker + Dokploy (plataforma de contenedores)
# HLI-ORDER: 50
# HLI-DEFAULT: yes
# HLI-TUI: yes
#
# Instala Docker + Dokploy corriendo el instalador oficial
# (https://dokploy.com/install.sh). Dokploy pasa a administrar los
# servicios (compose, dominios, TLS, deploys); este módulo solo prepara el
# terreno: pre-chequeos, dirección/pool de red, y ejecutar el instalador
# oficial UNA sola vez de forma segura.
#
# ATENCIÓN — el script oficial es DESTRUCTIVO en una re-ejecución: hace
# 'docker swarm leave --force' y 'docker network rm -f dokploy-network' sin
# preguntar. Si Dokploy ya está instalado, este módulo NUNCA vuelve a correr
# el instalador: ofrece 'actualizar' (docker pull + service update, ruta no
# destructiva) o no hacer nada. Ver _dokploy_state()/_swarm_safety()/_dokploy_main().
# Toda consulta a Docker pasa por hli_docker() (lib/core.sh, sudo -n docker):
# un 'docker' sin privilegios devuelve vacío por "permission denied" cuando
# el usuario no está en el grupo docker (el caso normal acá), y eso NO
# significa "no hay nada corriendo" — tratarlo así fue justamente el bug que
# dejaba pasar la instalación destructiva sobre un swarm ajeno sin detectarlo.
set -euo pipefail
source "$(dirname "$0")/../lib/core.sh"

# ===========================================================================
# Funciones puras: no hacen red, no tocan disco, no llaman a sudo ni a
# dialog. Se pueden testear sourceando este archivo SIN ejecutar el módulo
# (ver el guard al final, "${BASH_SOURCE[0]}" == "$0"): un test runner que
# fije $0 a otra ruta dentro de modules/ (para que "dirname "$0"" siga
# resolviendo lib/core.sh) puede sourcear este archivo y llamarlas
# directamente, sin tocar el sistema real.
# ===========================================================================

# IPv4 válida: cuatro octetos 0-255.
_dp_is_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  for o in ${ip//./ }; do
    [[ "$o" -le 255 ]] || return 1
  done
  return 0
}

# IPv4 -> entero de 32 bits.
_dp_ip_to_int() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip"
  # Valores por defecto si faltara algún octeto, y '10#' para forzar base
  # decimal (mismo motivo que en _dp_version_le: un octeto "08" se leería
  # como octal inválido y rompería la aritmética).
  echo $(( (10#${a:-0} << 24) + (10#${b:-0} << 16) + (10#${c:-0} << 8) + 10#${d:-0} ))
}

# Rango [red, broadcast] (enteros) de un CIDR "ip/prefijo". Una línea:
# "<red> <broadcast>".
_dp_cidr_range() {
  local cidr="$1" ip prefix ip_int mask network broadcast
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  ip_int="$(_dp_ip_to_int "$ip")"
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  network=$(( ip_int & mask ))
  broadcast=$(( network | ((~mask) & 0xFFFFFFFF) ))
  echo "$network $broadcast"
}

# ¿Se superponen dos CIDR IPv4 $1 y $2?
_dp_cidr_overlap() {
  local a_net a_bc b_net b_bc
  read -r a_net a_bc <<<"$(_dp_cidr_range "$1")"
  read -r b_net b_bc <<<"$(_dp_cidr_range "$2")"
  [[ "$a_net" -le "$b_bc" && "$b_net" -le "$a_bc" ]]
}

# ¿$1 <= $2? (versiones "X" o "X.Y", comparación numérica por partes, no por
# string: "9" < "10"). Versión no numérica -> false (mejor advertir de más
# que asumir soportado).
_dp_version_le() {
  local v1="$1" v2="$2" v1_major v1_minor v2_major v2_minor
  [[ "$v1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [[ "$v2" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  v1_major="${v1%%.*}"
  v2_major="${v2%%.*}"
  v1_minor="${v1#*.}"; [[ "$v1_minor" == "$v1" ]] && v1_minor=0
  v2_minor="${v2#*.}"; [[ "$v2_minor" == "$v2" ]] && v2_minor=0
  # 10# fuerza base decimal: sin esto, minor="08"/"09" rompería la
  # aritmética de bash (los intenta leer como octal e "8"/"9" no son
  # dígitos octales válidos).
  v1_minor=$((10#$v1_minor))
  v2_minor=$((10#$v2_minor))
  if [[ "$v1_major" -lt "$v2_major" ]]; then return 0; fi
  if [[ "$v1_major" -gt "$v2_major" ]]; then return 1; fi
  [[ "$v1_minor" -le "$v2_minor" ]]
}

# ¿El SO ($1=ID, $2=VERSION_ID de /etc/os-release) es una versión
# oficialmente soportada por Dokploy? Ubuntu <= 24.04 o Debian <= 12.
_dp_os_supported() {
  local id="$1" version="$2"
  case "$id" in
    ubuntu) _dp_version_le "$version" "24.04" ;;
    debian) _dp_version_le "$version" "12" ;;
    *) return 1 ;;
  esac
}

# ¿Aparece el puerto $2 EXACTO en la columna de dirección local de una
# salida de 'ss -Htlnp' ya capturada en $1? Nunca un grep suelto sobre toda
# la línea (eso matcheaba ':8080' al buscar ':80', o texto casual del campo
# de proceso): se toma la 4ta columna (dirección local, después de
# State/Recv-Q/Send-Q) y se compara el puerto EXACTO (lo que sigue al
# último ':', válido tanto para IPv4 "0.0.0.0:80"/"*:80" como para IPv6
# entre corchetes "[::]:80").
_dp_ss_port_busy() {
  local output="$1" port="$2" line addr col_port
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    addr="$(awk '{print $4}' <<<"$line")"
    [[ -n "$addr" ]] || continue
    col_port="${addr##*:}"
    [[ "$col_port" == "$port" ]] && return 0
  done <<<"$output"
  return 1
}

# Wrapper real (no puro): corre 'ss' de verdad y delega el parseo a
# _dp_ss_port_busy. Sin sudo: el estado LISTEN es visible para cualquier
# usuario; sin '-p' solo faltaría el nombre del proceso de sockets ajenos,
# que acá no se usa.
_dp_port_busy() {
  local port="$1"
  _dp_ss_port_busy "$(ss -Htlnp 2>/dev/null)" "$port"
}

# De una salida de 'ip -o -4 addr show' ($1), el CIDR (ej. "192.168.1.50/24")
# cuya IP coincide EXACTO con $2. Vacío si no hay coincidencia.
_dp_parse_ip_addr_cidr() {
  local output="$1" ip="$2"
  awk -v ip="$ip" '$4 ~ ("^" ip "/") {print $4; exit}' <<<"$output"
}

# Primer candidato /16 (172.20.0.0/16 .. 172.31.0.0/16) que NO se superpone
# con ninguna ruta de $1 (una por línea; "default" y líneas que no empiezan
# con un CIDR se ignoran). Vacío (y exit 1) si ninguno sirve.
_dp_choose_addr_pool() {
  local routes="$1" cand route_cidr free n
  for n in $(seq 20 31); do
    cand="172.${n}.0.0/16"
    free=1
    while IFS= read -r route_cidr; do
      [[ -n "$route_cidr" ]] || continue
      [[ "$route_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || continue
      if _dp_cidr_overlap "$cand" "$route_cidr"; then
        free=0
        break
      fi
    done <<<"$routes"
    if [[ "$free" -eq 1 ]]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

# De un pool /16 (ej. "172.21.0.0/16"), la dirección "bip" del puente
# (primer /24 del pool, host .1): "172.21.0.1/24".
_dp_bip_from_pool() {
  local pool="$1" base
  base="${pool%/*}"
  echo "${base%.*}.1/24"
}

# Validación mínima de un script descargado antes de ejecutarlo: no vacío y
# empieza con un shebang. No reemplaza revisar el contenido, pero evita
# correr una respuesta de error HTML/vacía como si fuera el instalador.
#
# Nota: NO se verifica un checksum/firma contra un valor publicado, porque
# Dokploy no publica ninguno para install.sh (no hay un .sha256/.asc oficial
# al que comparar); "validar contra sí mismo" no agregaría seguridad real,
# solo una falsa sensación de haberlo hecho. Se descarga por HTTPS
# (integridad/autenticidad del transporte) y se aplica este chequeo mínimo
# de forma, nada más.
_dp_validate_script() {
  local f="$1"
  [[ -s "$f" ]] || return 1
  [[ "$(head -c2 "$f" 2>/dev/null)" == '#!' ]]
}

# ===========================================================================
# Funciones reales: sí tocan el sistema (docker, sudo, red, dialog). No se
# ejecutan durante los tests (el guard del final nunca llama a estas si el
# archivo fue sourceado en vez de ejecutado).
# ===========================================================================

DOKPLOY_INSTALL_URL="https://dokploy.com/install.sh"

# Estado de la instalación de Dokploy, TRES valores por stdout:
#   installed      /etc/dokploy existe, o hay un servicio de swarm "dokploy".
#   not-installed  Docker está genuinamente ausente (máquina limpia: el
#                  propio instalador de Dokploy se encarga de instalarlo), o
#                  Docker SÍ está presente y se pudo consultar, pero no hay
#                  ni /etc/dokploy ni servicio "dokploy".
#   unknown        No se pudo determinar Docker con certeza: presencia
#                  "unknown" (ver hli_docker_presence: sudo -n no anda, o
#                  hay rastros de Docker pero no se resuelve el binario), o
#                  el binario SÍ está pero 'hli_docker info' falla (demonio
#                  caído). NUNCA se trata como "not-installed": hacerlo
#                  dejaría avanzar a instalar a ciegas, sin poder confirmar
#                  que no hay nada corriendo (el bug real que motivó todo
#                  esto: un 'docker' sin privilegios, o resuelto con el PATH
#                  equivocado, puede parecer "ausente" cuando root sí lo ve).
#
# TODA consulta a Docker acá pasa por hli_docker/hli_docker_presence
# (lib/core.sh, sudo -n), nunca por 'docker'/'command -v docker' pelados.
_dokploy_state() {
  # /etc/dokploy manda por sobre lo que diga Docker: si existe, Dokploy está
  # instalado aunque el demonio esté caído ahora mismo (eso lo maneja la
  # rama "installed" de _dokploy_main, que revalida antes de ofrecer update).
  if [[ -d /etc/dokploy ]]; then
    echo "installed"
    return
  fi

  local presence
  presence="$(hli_docker_presence)"
  case "$presence" in
    absent)
      echo "not-installed"
      return
      ;;
    unknown)
      echo "unknown"
      return
      ;;
  esac
  # presence == "present" de acá en adelante.

  if ! hli_docker info >/dev/null 2>&1; then
    echo "unknown"
    return
  fi

  if hli_docker service inspect dokploy >/dev/null 2>&1; then
    echo "installed"
  else
    echo "not-installed"
  fi
}

# Seguridad del swarm existente de cara a dejar correr el instalador
# oficial (que hace 'docker swarm leave --force' SIN preguntar). Cuatro
# valores por stdout:
#   no-swarm  LocalNodeState == inactive: no hay nada que el instalador
#             pueda destruir.
#   dokploy   Hay swarm activo (o pending/locked/lo que sea), pero es EL
#             swarm de Dokploy (existe el servicio "dokploy"): reinstalar
#             encima es lo esperado.
#   foreign   Hay swarm en cualquier estado que NO sea inactive (active,
#             pending, error, locked...) y NO es el de Dokploy: el
#             instalador lo destruiría.
#   unknown   No se pudo leer el estado del swarm en absoluto (el --format
#             falló, o vino vacío). TRATAR IGUAL QUE "foreign": jamás asumir
#             que un estado no verificable es seguro.
#
# _dokploy_main solo llama a esta función cuando hli_docker_presence()
# devolvió "present" (nunca con "absent": sin Docker no hay swarm que
# proteger; ni con "unknown": eso ya se interceptó antes, en _dokploy_state).
# Aun así, esta función NO asume que 'hli_docker info' vaya a funcionar (por
# eso el propio --format se revisa por separado): Docker puede estar
# presente pero con el demonio caído en este preciso momento.
_swarm_safety() {
  local state
  if ! state="$(hli_docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)"; then
    echo "unknown"
    return
  fi
  [[ -n "$state" ]] || { echo "unknown"; return; }

  if [[ "$state" == "inactive" ]]; then
    echo "no-swarm"
    return
  fi

  if hli_docker service inspect dokploy >/dev/null 2>&1; then
    echo "dokploy"
  else
    echo "foreign"
  fi
}

# Ruta de actualización NO destructiva: descarga el instalador oficial y lo
# corre con el subcomando 'update' (docker pull + docker service update),
# que nunca toca el swarm ni la red existente.
_dokploy_update() {
  local version tmp rc

  version=$(input_box "Actualizar Dokploy" "Versión a instalar (latest, canary, o un tag fijo, ej. v0.29.10):" "latest") || return 1
  [[ -n "$version" ]] || version="latest"

  tmp="$(mktemp)"

  if ! curl -fsSL --connect-timeout 15 -o "$tmp" "$DOKPLOY_INSTALL_URL"; then
    msg "No se pudo descargar el instalador de Dokploy desde $DOKPLOY_INSTALL_URL.\n\nVerifique la conexión a internet e intente de nuevo."
    rm -f "$tmp"
    return 1
  fi
  if ! _dp_validate_script "$tmp"; then
    msg "El script descargado no parece válido (vacío o sin shebang).\n\nSe aborta por seguridad, no se ejecuta nada."
    rm -f "$tmp"
    return 1
  fi

  if ! confirm "Se actualizará Dokploy a la versión: $version\n\nEsto ejecuta 'docker pull' + 'docker service update' (ruta NO destructiva: no toca el swarm ni las demás aplicaciones). ¿Continuar?"; then
    rm -f "$tmp"
    return 1
  fi

  log "Actualizando Dokploy a versión $version"
  rc=0
  sudo env DOKPLOY_VERSION="$version" bash "$tmp" update 2>&1 | sudo tee -a "$LOG_DIR/dokploy.log" || rc=$?
  rm -f "$tmp"

  if [[ $rc -ne 0 ]]; then
    msg "La actualización de Dokploy terminó con errores (código $rc).\n\nRevise el log:\n$LOG_DIR/dokploy.log"
    return 1
  fi
  msg "Dokploy actualizado a la versión: $version"
  return 0
}

# Escribe /etc/docker/daemon.json con un 'bip' y un pool de direcciones por
# defecto distintos a 172.17.0.0/16, para el caso en que la LAN elegida se
# superponga con el puente por defecto de Docker. Solo se llama si el
# archivo NO existe todavía (nunca pisa una config existente).
_dp_write_daemon_json() {
  local bip_addr="$1" pool_cidr="$2"
  sudo mkdir -p /etc/docker
  cat <<EOF | sudo tee /etc/docker/daemon.json >/dev/null
{
  "bip": "$bip_addr",
  "default-address-pools": [
    { "base": "$pool_cidr", "size": 24 }
  ]
}
EOF
  # Si Docker ya está corriendo (host con docker instalado pero sin swarm
  # propio de Dokploy: el único caso en que se llega hasta acá con Docker ya
  # presente), el daemon.json nuevo no aplica hasta reiniciar el servicio.
  if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    sudo systemctl restart docker
  fi
}

# Instalación limpia (primera vez). Pre-chequeos, ADVERTISE_ADDR, pool de
# direcciones, descarga verificada, resumen + confirmación, y recién
# entonces se ejecuta el instalador oficial.
_dokploy_main() {
  local dp_state
  dp_state="$(_dokploy_state)"

  if [[ "$dp_state" == "unknown" ]]; then
    msg "No se pudo determinar el estado de Docker/Dokploy en este servidor (el demonio de Docker no responde, o no hay permisos para consultarlo).\n\nInicie o repare Docker ('sudo systemctl status docker') y reintente.\n\nHLI 2 no continúa: instalar a ciegas podría destruir un servicio existente."
    return 1
  fi

  if [[ "$dp_state" == "installed" ]]; then
    # /etc/dokploy puede existir con Docker caído (ver _dokploy_state):
    # revalidar acá antes de ofrecer 'actualizar', que de todos modos
    # necesita Docker funcionando. hli_docker_presence (no 'command -v
    # docker' pelado): root puede ver el binario aunque el usuario del
    # bootstrap no lo tenga en su PATH.
    if [[ "$(hli_docker_presence)" != "present" ]] || ! hli_docker info >/dev/null 2>&1; then
      msg "Dokploy parece instalado (existe /etc/dokploy), pero no se pudo consultar Docker (demonio caído, sin permisos, o no se pudo resolver el binario). HLI 2 no continúa.\n\nInicie o repare Docker antes de actualizar Dokploy."
      return 1
    fi

    local choice
    choice=$(dialog --clear --title "Dokploy" \
      --menu "Dokploy ya está instalado en este servidor.\n\n¿Qué desea hacer?" \
      14 76 3 \
      actualizar "Actualizar Dokploy (docker pull + service update, no destructivo)" \
      nada "No hacer nada" \
      3>&1 1>&2 2>&3) || { mark_done dokploy; return 0; }
    case "$choice" in
      actualizar) _dokploy_update || true ;;
      nada) msg "No se hizo ningún cambio." ;;
    esac
    mark_done dokploy
    return 0
  fi

  # A partir de acá, dp_state == "not-installed". Eso significa que
  # hli_docker_presence ya dio "absent" o "present" (nunca "unknown": eso ya
  # se interceptó arriba, en _dokploy_state). Si es "present" (Docker
  # instalado, solo faltaba Dokploy), hay que confirmar que no hay un swarm
  # ajeno antes de dejar correr el instalador oficial. Si es "absent"
  # (máquina realmente limpia), no hay swarm posible: se salta el chequeo
  # (llamar a _swarm_safety con Docker ausente daría "unknown" y abortaría
  # una instalación limpia legítima). Se vuelve a consultar la presencia acá
  # (en vez de propagarla desde _dokploy_state) para no acoplar las dos
  # funciones a un valor de retorno extra; el costo es una llamada más a
  # sudo, aceptable frente a instalar a ciegas.
  #
  # FALLA CERRADO: solo "absent" permite saltar el chequeo de swarm. Si esta
  # segunda consulta devuelve "unknown" (p. ej. el caché de sudo venció
  # entre ambas llamadas), se aborta: nunca se trata como máquina limpia.
  local presence
  presence="$(hli_docker_presence)" || presence="unknown"
  if [[ "$presence" == "unknown" || -z "$presence" ]]; then
    msg "No se pudo determinar si Docker está presente en este servidor (sin permisos de sudo o estado inconsistente). HLI 2 no continúa.\n\nVerifique 'sudo docker info' y reintente."
    return 1
  fi
  if [[ "$presence" != "absent" ]]; then
    local swarm_safety
    swarm_safety="$(_swarm_safety)"
    if [[ "$swarm_safety" != "no-swarm" && "$swarm_safety" != "dokploy" ]]; then
      msg "Este nodo ya forma parte de un Docker Swarm que no se pudo confirmar como propio de Dokploy (estado: ${swarm_safety}).\n\nEl instalador oficial de Dokploy hace 'docker swarm leave --force' antes de instalar, lo que DESTRUIRÍA ese swarm si es ajeno.\n\nHLI 2 no continúa. Revise manualmente ('docker service ls', 'docker node ls', 'docker info') antes de instalar Dokploy en este nodo."
      return 1
    fi
  fi

  # --- Pre-chequeos, ANTES de descargar nada ---

  local os_id="" os_version=""
  if [[ -f /etc/os-release ]]; then
    # Best-effort: un os-release corrupto/no sourceable no debe tumbar el
    # módulo, solo dejar os_id/os_version vacíos (se tratan como "no
    # soportado" más abajo, que es el lado seguro).
    os_id="$(. /etc/os-release && echo "${ID:-}")" || true
    os_version="$(. /etc/os-release && echo "${VERSION_ID:-}")" || true
  fi
  if ! _dp_os_supported "${os_id:-}" "${os_version:-0}"; then
    confirm "Este sistema (${os_id:-desconocido} ${os_version:-N/D}) no es una versión oficialmente soportada por Dokploy.\n\nSoporte oficial: Ubuntu <= 24.04 o Debian <= 12.\n\n¿Instalar de todos modos, bajo su propio riesgo?" \
      || { msg "Instalación de Dokploy cancelada."; return 0; }
  fi

  # 80/443/3000 quedan literales A PROPÓSITO (no vienen del registro): no son
  # una elección de HLI 2, son requisitos FIJOS y no configurables del propio
  # instalador oficial de Dokploy (Traefik ocupa 80/443, el panel el 3000
  # publicado con --publish, hardcodeado en su script), así que no hay nada
  # que "leer de otro lado" antes de que Dokploy exista. El puerto que SÍ
  # sale del registro es el de post-instalación, más abajo (dokploy_port).
  local p busy_ports=()
  for p in 80 443 3000; do
    _dp_port_busy "$p" && busy_ports+=("$p")
  done
  if [[ ${#busy_ports[@]} -gt 0 ]]; then
    msg "Dokploy necesita los puertos 80, 443 y 3000 libres.\n\nOcupados ahora mismo: ${busy_ports[*]}\n\nLibere esos puertos (o detenga lo que los está usando) e intente de nuevo."
    return 1
  fi

  local ram_mb
  ram_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)" || true
  ram_mb="${ram_mb:-0}"
  if [[ "$ram_mb" -lt 2048 ]]; then
    confirm "RAM detectada: ${ram_mb} MB (recomendado: al menos 2048 MB).\n\n¿Continuar de todos modos?" \
      || { msg "Instalación de Dokploy cancelada."; return 0; }
  fi

  local free_gb
  free_gb="$(df --output=avail -BG /var/lib 2>/dev/null | tail -n1 | tr -dc '0-9')" || true
  if [[ -z "$free_gb" || "$free_gb" -lt 30 ]]; then
    confirm "Espacio libre en /var/lib: ${free_gb:-desconocido} GB (recomendado: al menos 30 GB).\n\n¿Continuar de todos modos?" \
      || { msg "Instalación de Dokploy cancelada."; return 0; }
  fi

  # --- ADVERTISE_ADDR ---

  local default_ip ADVERTISE_ADDR=""
  default_ip="$(get_ip || true)"
  while true; do
    ADVERTISE_ADDR=$(input_box "Dokploy — dirección IP" "IP de LAN que Dokploy va a anunciar (ADVERTISE_ADDR):" "${ADVERTISE_ADDR:-$default_ip}") \
      || { msg "Instalación de Dokploy cancelada."; return 0; }
    _dp_is_ipv4 "$ADVERTISE_ADDR" && break
    msg "«$ADVERTISE_ADDR» no es una IPv4 válida. Intente de nuevo (ej. 192.168.1.50)."
  done

  # --- Pool de direcciones: colisión con 10.0.0.0/8 (pool por defecto de
  #     Swarm) y con 172.17.0.0/16 (puente por defecto de Docker) ---

  local lan_cidr routes_raw="" routes_ok=1 routes=""
  lan_cidr="$(_dp_parse_ip_addr_cidr "$(ip -o -4 addr show 2>/dev/null)" "$ADVERTISE_ADDR")"
  # No fallar acá todavía: si 'ip route' no se pudo leer pero la LAN no se
  # superpone con nada, el pool nunca hace falta y no corresponde abortar la
  # instalación por eso. El fallo se aplica más abajo, SOLO si de verdad se
  # necesitan las rutas para elegir un pool sin colisión (fallar cerrado:
  # nunca tratar "no pude leer las rutas" como "no hay colisión").
  routes_raw="$(ip route show 2>/dev/null)" || routes_ok=0
  routes="$(awk '{print $1}' <<<"$routes_raw")"
  # _dp_choose_addr_pool recibe SIEMPRE routes + lan_cidr: 'ip route show'
  # normalmente ya incluye la ruta de la LAN (es una interfaz conectada), pero
  # no dar nada por sentado — si por lo que sea faltara esa línea, seguiría
  # comparándose explícitamente contra la LAN elegida, no solo contra rutas.
  local routes_plus_lan="$routes"
  [[ -n "$lan_cidr" ]] && routes_plus_lan="$routes_plus_lan"$'\n'"$lan_cidr"

  local DOCKER_SWARM_INIT_ARGS="" swarm_pool=""
  if [[ -n "$lan_cidr" ]] && _dp_cidr_overlap "$lan_cidr" "10.0.0.0/8"; then
    if [[ "$routes_ok" -eq 0 ]]; then
      msg "La LAN ($lan_cidr) se superpone con el pool de direcciones por defecto de Docker Swarm (10.0.0.0/8), pero no se pudo leer 'ip route' para elegir un pool alternativo sin colisión.\n\nSe aborta: no se puede garantizar un pool seguro sin ver las rutas existentes."
      return 1
    fi
    swarm_pool="$(_dp_choose_addr_pool "$routes_plus_lan")" || swarm_pool=""
    if [[ -z "$swarm_pool" ]]; then
      msg "La LAN ($lan_cidr) se superpone con el pool de direcciones por defecto de Docker Swarm (10.0.0.0/8), y no se encontró ningún rango 172.20-172.31/16 libre entre las rutas existentes.\n\nSe aborta. Revise 'ip route' manualmente y vuelva a intentar."
      return 1
    fi
    DOCKER_SWARM_INIT_ARGS="--default-addr-pool $swarm_pool --default-addr-pool-mask-length 24"
  fi

  local bip_note=""
  if [[ -n "$lan_cidr" ]] && _dp_cidr_overlap "$lan_cidr" "172.17.0.0/16"; then
    if [[ -f /etc/docker/daemon.json ]]; then
      bip_note="AVISO: la LAN ($lan_cidr) se superpone con el puente por defecto de Docker (172.17.0.0/16), pero /etc/docker/daemon.json YA EXISTE — no se modifica para no perder configuración previa. Revíselo manualmente si Docker no arranca bien."
    elif [[ "$routes_ok" -eq 0 ]]; then
      msg "La LAN ($lan_cidr) se superpone con el puente por defecto de Docker (172.17.0.0/16), pero no se pudo leer 'ip route' para elegir un rango alternativo sin colisión.\n\nSe aborta: no se puede garantizar un rango seguro sin ver las rutas existentes."
      return 1
    else
      local routes_for_bip="$routes_plus_lan"
      [[ -n "$swarm_pool" ]] && routes_for_bip="$routes_for_bip"$'\n'"$swarm_pool"
      local bip_pool
      bip_pool="$(_dp_choose_addr_pool "$routes_for_bip")" || bip_pool=""
      if [[ -z "$bip_pool" ]]; then
        msg "La LAN ($lan_cidr) se superpone con el puente por defecto de Docker (172.17.0.0/16) y no se encontró un rango libre para reconfigurarlo.\n\nSe aborta. Revise la red manualmente."
        return 1
      fi
      local bip_addr
      bip_addr="$(_dp_bip_from_pool "$bip_pool")"
      _dp_write_daemon_json "$bip_addr" "$bip_pool"
      bip_note="Se escribió /etc/docker/daemon.json: puente por defecto de Docker movido a $bip_addr (pool $bip_pool), porque la LAN se superpone con 172.17.0.0/16."
    fi
  fi

  # --- Versión ---

  local DOKPLOY_VERSION
  DOKPLOY_VERSION=$(input_box "Dokploy — versión" "Versión a instalar (latest, canary, o un tag fijo, ej. v0.29.10):" "latest") \
    || { msg "Instalación de Dokploy cancelada."; return 0; }
  [[ -n "$DOKPLOY_VERSION" ]] || DOKPLOY_VERSION="latest"

  # --- Descarga verificada ---
  #
  # Nota sobre limpieza de $tmp: NO se usa 'trap ... RETURN'. En bash ese
  # trap no es local a esta función: queda armado para CUALQUIER retorno de
  # función posterior dentro del mismo shell (incluidas _dp_validate_script,
  # service_url, etc. más abajo), así que borraría $tmp apenas retornara la
  # primera función auxiliar llamada después de armarlo — mucho antes de
  # llegar a 'bash "$tmp"'. Por eso se limpia a mano en cada punto de salida.

  local tmp
  tmp="$(mktemp)"

  if ! curl -fsSL --connect-timeout 15 -o "$tmp" "$DOKPLOY_INSTALL_URL"; then
    msg "No se pudo descargar el instalador de Dokploy desde $DOKPLOY_INSTALL_URL.\n\nVerifique la conexión a internet e intente de nuevo."
    rm -f "$tmp"
    return 1
  fi
  if ! _dp_validate_script "$tmp"; then
    msg "El script descargado no parece válido (vacío o sin shebang).\n\nSe aborta por seguridad, no se ejecuta nada."
    rm -f "$tmp"
    return 1
  fi

  # --- Resumen + confirmación final ---

  local summary
  summary="Se va a instalar Dokploy:\n\n"
  summary+="Versión            : $DOKPLOY_VERSION\n"
  summary+="ADVERTISE_ADDR     : $ADVERTISE_ADDR\n"
  summary+="LAN detectada      : ${lan_cidr:-N/D}\n"
  summary+="Pool de Swarm      : ${swarm_pool:-por defecto de Docker (10.0.0.0/8)}\n"
  [[ -n "$bip_note" ]] && summary+="Puente de Docker   : $bip_note\n"
  summary+="Puertos 80/443/3000: libres (verificado)\n\n"
  summary+="ATENCIÓN: el instalador oficial de Dokploy hace 'docker swarm leave --force' y recrea la red 'dokploy-network' de forma incondicional. HLI 2 ya validó que este nodo no tiene un swarm ajeno activo, pero esta operación no es reversible.\n\n¿Continuar?"

  if ! confirm "$summary"; then
    msg "Instalación de Dokploy cancelada."
    rm -f "$tmp"
    return 0
  fi

  log "Instalando Dokploy $DOKPLOY_VERSION (ADVERTISE_ADDR=$ADVERTISE_ADDR, DOCKER_SWARM_INIT_ARGS=${DOCKER_SWARM_INIT_ARGS:-<vacío>})"
  local rc=0
  sudo env DOKPLOY_VERSION="$DOKPLOY_VERSION" ADVERTISE_ADDR="$ADVERTISE_ADDR" DOCKER_SWARM_INIT_ARGS="$DOCKER_SWARM_INIT_ARGS" \
    bash "$tmp" 2>&1 | sudo tee -a "$LOG_DIR/dokploy.log" || rc=$?
  rm -f "$tmp"

  if [[ $rc -ne 0 ]]; then
    msg "La instalación de Dokploy terminó con errores (código $rc).\n\nRevise el log:\n$LOG_DIR/dokploy.log"
    return 1
  fi

  # --- Post-instalación ---

  sudo mkdir -p "$APPDATA_ROOT"
  sudo chown root:root "$APPDATA_ROOT" 2>/dev/null || true
  sudo chmod 0755 "$APPDATA_ROOT"

  # Puerto del panel: SIEMPRE desde el registro (services/dokploy.conf), no
  # un "3000" repetido a mano acá — si el registro cambiara, esto sigue
  # sirviendo sin tocar el módulo.
  local dokploy_port
  dokploy_port="$(service_get dokploy PORT)" || true
  dokploy_port="${dokploy_port:-3000}"

  local waited=0 ready=0
  while [[ "$waited" -lt 120 ]]; do
    if hli_docker service ls --filter name=dokploy --format '{{.Replicas}}' 2>/dev/null | grep -qx '1/1' \
       && curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${dokploy_port}" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done

  local status_note
  if [[ "$ready" -eq 1 ]]; then
    status_note="Dokploy está corriendo (docker service ls muestra 1/1 réplicas, el panel responde en el puerto ${dokploy_port})."
  else
    status_note="Dokploy no terminó de levantar dentro de los 120 segundos de espera. Puede seguir iniciando: revise 'docker service ls' y 'docker service logs dokploy' en unos minutos."
  fi

  local panel_url
  panel_url="$(service_url dokploy "$ADVERTISE_ADDR")" || true

  msg "Dokploy instalado.\n\n$status_note\n\nPanel: ${panel_url:-http://$ADVERTISE_ADDR:${dokploy_port}}\n\nIMPORTANTE: cree la cuenta de administrador AHORA entrando al panel. El primer visitante que entra se convierte en admin: cualquiera en la LAN que llegue primero se queda con esa cuenta.\n\nOJO: los puertos que Docker/Dokploy publican (80, 443, ${dokploy_port}, y los que publique cada servicio) NO pasan por ufw ni por ningún firewall del host: Docker los expone directo con sus propias reglas de iptables."

  mark_done dokploy
  return 0
}

# Solo ejecuta la instalación/actualización real cuando este archivo corre
# como script (bash modules/dokploy.sh, que es como lo invoca run_module).
# Si en cambio fue sourceado (tests: sourcearlo desde otro $0 que también
# viva en modules/, para que la línea 'source lib/core.sh' de más arriba
# siga resolviendo bien), BASH_SOURCE[0] (este archivo) difiere de $0 (el
# invocador) y _dokploy_main() NUNCA se llama: solo quedan disponibles las
# funciones puras y las reales (sin invocarlas) para testear.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _dokploy_main
fi
