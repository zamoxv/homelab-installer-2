#!/usr/bin/env bash
# Importador de configuración desde un tar de backup del HLI v1
# (homelab-installer, backup-<timestamp>.tar.gz). Referencia de solo
# lectura: homelab-installer/modules/backup.sh:17-59 (layout del tar) y
# homelab-installer/lib/common.sh (import_authorized_keys,
# adguard_normalize_bind, free_dns_port) — adaptado acá, nunca sourceado ni
# copiado literal desde v1.
#
# Layout del tar de v1 (backup.sh:17-59):
#   jellyfin/lib/    = /var/lib/jellyfin nativo (datos: metadata, plugins, db)
#   jellyfin/etc/    = /etc/jellyfin nativo (config: system.xml, network.xml...)
#   qbittorrent/config/ = ~/.config/qBittorrent nativo (qBittorrent.conf)
#   qbittorrent/share/  = ~/.local/share/qBittorrent nativo (BT_backup/*.fastresume)
#   adguard/AdGuardHome.yaml
#   samba/smb.conf
#   hli/default.conf
#   ssh/authorized_keys
#   config.yml (manifiesto)
#
# Layouts de destino verificados (2026-09-29, ver compose/*/docker-compose.yml
# para las fuentes citadas):
#   Jellyfin (jellyfin/jellyfin):      /config = JELLYFIN_DATA_DIR (antes
#                                       /var/lib/jellyfin), /config/config =
#                                       JELLYFIN_CONFIG_DIR (antes /etc/jellyfin)
#   qBittorrent (linuxserver/qbittorrent): /config/qBittorrent = unifica lo que
#                                       en v1 estaba separado entre
#                                       ~/.config/qBittorrent y
#                                       ~/.local/share/qBittorrent
#   AdGuard (adguard/adguardhome):     /opt/adguardhome/conf/AdGuardHome.yaml
set -euo pipefail

# --- Extracción y validación -------------------------------------------------

# Analiza un listado de 'tar -tzv' (stdin) y, por cada miembro "inseguro",
# imprime una línea "  - motivo: ruta". Vacío = no se encontró nada inseguro.
#
# Se rechazan: rutas absolutas, rutas con un componente literal ".."
# (path traversal), hardlinks, y symlinks (CUALQUIERA, sin excepción). Sobre
# symlinks: backup.sh de v1 usa 'rsync -aHAX' para volcar /var/lib/jellyfin,
# ~/.config/qBittorrent y ~/.local/share/qBittorrent al tar (-H preserva
# hardlinks; rsync sin --copy-links también preserva symlinks si los
# hubiera), así que un tar de v1 PODRÍA en teoría traer alguno. Pero ninguno
# de esos tres árboles (metadata/config de Jellyfin y qBittorrent) los usa
# por diseño normal de esas aplicaciones — no hay una ruta legítima conocida
# que dependa de un symlink/hardlink sobreviviendo al import. Ante la duda,
# se rechaza el tar ENTERO en vez de intentar "permitir symlinks relativos
# que resuelven adentro" (una validación bastante más compleja y con más
# superficie para un error sutil): si algún día aparece un caso real con
# links legítimos, mejor que falle con un mensaje claro acá y se revise a
# mano, que aceptar en silencio una ruta de escape del extractor.
_importer_tar_reject_reasons() {
  local listing="$1" perms ownergroup size date time path reasons=""
  while read -r perms ownergroup size date time path; do
    [[ -n "$perms" ]] || continue
    case "$path" in
      *" -> "*) path="${path%% -> *}" ;;
      *" link to "*) path="${path%% link to *}" ;;
    esac
    case "${perms:0:1}" in
      l) reasons+="  - symlink no permitido: $path"$'\n' ;;
      h) reasons+="  - hardlink no permitido: $path"$'\n' ;;
    esac
    case "$path" in
      /*) reasons+="  - ruta absoluta: $path"$'\n' ;;
    esac
    if [[ "$path" == *..* ]]; then
      local comp comps bad=0
      IFS='/' read -ra comps <<<"$path"
      for comp in "${comps[@]}"; do
        [[ "$comp" == ".." ]] && bad=1
      done
      [[ "$bad" -eq 1 ]] && reasons+="  - ruta con componente '..': $path"$'\n'
    fi
  done <<<"$listing"
  printf '%s' "$reasons"
}

# Lista y valida el tar $1 SIN extraer nada, y deja el resultado en caché
# (variables globales, para que importer_extract no vuelva a recorrer el
# tar): IMPORT_TAR_PATH, IMPORT_TAR_LISTING, IMPORT_TAR_TOTAL_BYTES. Permite
# decidir qué importar (qué componentes trae, cuánto pesa) ANTES de la
# extracción, que es la parte lenta. Falla cerrado (return 1, con mensaje por
# hli_error) si el tar no es legible o trae miembros inseguros. Debe llamarse
# en el shell actual (no dentro de $(...)) para que la caché sobreviva.
importer_inspect() {
  local tar_path="$1" listing listing_err reject
  [[ -f "$tar_path" ]] || { hli_error "no existe el archivo: $tar_path"; return 1; }

  # Listar ANTES de tocar disco: valida forma/miembros sin extraer nada.
  # stdout (el listado) y stderr (avisos de 'tar', ej. "Eliminando la '/'
  # inicial de los nombres" cuando ve una ruta absoluta) se capturan por
  # SEPARADO a propósito: el listado en stdout sigue mostrando el nombre de
  # miembro ORIGINAL sin recortar (verificado), que es justo lo que hace
  # falta para poder rechazarlo; si se mezclaran con 'tar -tzvf ... 2>&1',
  # esas líneas de aviso se colarían en el parseo campo-por-campo y podrían
  # ensuciarlo. Una sola pasada: el listado y los avisos van a un archivo
  # temporal del usuario (no hay que releer el tar comprimido dos veces).
  local errf
  errf="$(mktemp)"
  hli_busy "Verificando el backup..."
  if ! listing="$(tar -tzvf "$tar_path" 2>"$errf")"; then
    listing_err="$(head -c 300 "$errf")" || listing_err=""
    rm -f "$errf"
    hli_error "no se pudo listar '$tar_path' (¿no es un tar.gz válido?). Detalle: $listing_err"
    return 1
  fi
  rm -f "$errf"

  reject="$(_importer_tar_reject_reasons "$listing")"
  if [[ -n "$reject" ]]; then
    hli_error "el tar contiene entradas no seguras; se aborta SIN extraer nada:"$'\n'"$reject"
    return 1
  fi

  IMPORT_TAR_PATH="$tar_path"
  IMPORT_TAR_LISTING="$listing"
  # Tamaño total descomprimido: columna 3 de cada línea de 'tar -tzv'
  # (mawk-compatible: sin \s/\S/\w).
  IMPORT_TAR_TOTAL_BYTES="$(awk '{sum+=$3} END{printf "%d", sum}' <<<"$listing")" || IMPORT_TAR_TOTAL_BYTES=0
  [[ "$IMPORT_TAR_TOTAL_BYTES" =~ ^[0-9]+$ ]] || IMPORT_TAR_TOTAL_BYTES=0
  return 0
}

# ¿Trae el backup (según el listado cacheado por importer_inspect) datos
# REALES importables del componente $1? No alcanza con la carpeta vacía:
# se exige un archivo marcador, para no detener nunca un contenedor por un
# componente sin nada que importar.
#   jellyfin    algún archivo bajo jellyfin/lib/ o jellyfin/etc/
#   qbittorrent algún archivo bajo qbittorrent/
#   adguard     adguard/AdGuardHome.yaml
#   ssh         ssh/authorized_keys
importer_inspect_has() {
  local comp="$1" perms ownergroup size date time path
  [[ -n "${IMPORT_TAR_LISTING:-}" ]] || return 1
  while read -r perms ownergroup size date time path; do
    [[ -n "$perms" && "${perms:0:1}" != "d" ]] || continue
    path="${path#./}"
    case "$comp:$path" in
      jellyfin:jellyfin/lib/*|jellyfin:jellyfin/etc/*) return 0 ;;
      qbittorrent:qbittorrent/*) return 0 ;;
      adguard:adguard/AdGuardHome.yaml) return 0 ;;
      ssh:ssh/authorized_keys) return 0 ;;
    esac
  done <<<"$IMPORT_TAR_LISTING"
  return 1
}

# Extrae el tar $1 a $2 mostrando progreso. Con terminal: 'dialog --gauge'
# alimentado con los bytes ya extraídos (du del destino) contra el total
# ($3, del listado). Es solo cosmético: la extracción corre en segundo plano
# y su código de salida (el que cuenta) se toma de 'wait'. Sin terminal
# (tests, segundo plano) extrae sin dibujar nada. Los avisos de tar van al
# archivo $4. Devuelve el código de 'tar'.
_importer_tar_extract() {
  local tar_path="$1" work="$2" total="$3" errf="$4" rc=0 mb gpid="" donef="$4.done"
  mb=$(( total / 1048576 ))
  if { : >/dev/tty; } 2>/dev/null && command -v dialog >/dev/null 2>&1; then
    stty -echo </dev/tty 2>/dev/null || true
    # El medidor corre EN SEGUNDO PLANO y 'tar' en PRIMER plano: un trabajo
    # en segundo plano de un script no interactivo arranca con SIGINT
    # ignorado, así que un 'tar' en segundo plano sobrevivía a Ctrl+C y
    # seguía llenando el disco. En primer plano, Ctrl+C lo mata y el
    # script termina (los trap EXIT limpian). El medidor termina solo: al
    # aparecer $donef o cuando el proceso padre ya no existe.
    (
      parent=$$
      while [[ ! -e "$donef" ]] && kill -0 "$parent" 2>/dev/null; do
        cur="$(du -sb "$work" 2>/dev/null | cut -f1)" || cur=0
        [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
        pct=0
        (( total > 0 )) && pct=$(( cur * 100 / total ))
        (( pct > 99 )) && pct=99
        printf 'XXX\n%d\nExtrayendo el backup (%d MB)...\nXXX\n' "$pct" "$mb"
        sleep 1
      done
      printf 'XXX\n100\nExtrayendo el backup (%d MB)...\nXXX\n' "$mb"
    ) | dialog --title "HLI 2" --gauge "Extrayendo el backup (${mb} MB)..." 8 70 0 >/dev/tty 2>/dev/null &
    gpid=$!
    tar -xzf "$tar_path" -C "$work" --no-same-owner --no-same-permissions 2>"$errf" || rc=$?
    : > "$donef"
    wait "$gpid" 2>/dev/null || true
    rm -f "$donef"
    hli_busy_end   # devuelve el eco del teclado
  else
    tar -xzf "$tar_path" -C "$work" --no-same-owner --no-same-permissions 2>"$errf" || rc=$?
  fi
  return "$rc"
}

# Extrae $1 (tar.gz de backup v1) a un directorio temporal nuevo y lo valida
# mínimamente (existe config.yml, y al menos una carpeta de componente
# conocida). Deja la ruta del directorio extraído en la GLOBAL IMPORT_WORK_DIR
# (no por stdout): así existe en el shell del llamador desde ANTES de empezar
# a extraer y el trap EXIT de import-v1 (importer_exit_cleanup) puede
# borrarlo aunque se interrumpa con Ctrl+C — llamarla dentro de $(...)
# perdería la variable. Llamar SIN command substitution. Falla
# cerrado: ante cualquier duda sobre el contenido del tar (formato, miembros
# inseguros, espacio insuficiente, algo que resuelve fuera del destino), no
# se deja nada utilizable en disco y se devuelve 1. Si el llamador ya corrió
# importer_inspect sobre este mismo tar, reutiliza su listado (no relee el
# tar); si no, lo inspecciona acá.
importer_extract() {
  local tar_path="$1" work
  IMPORT_WORK_DIR=""
  if [[ "${IMPORT_TAR_PATH:-}" != "$tar_path" ]]; then
    importer_inspect "$tar_path" || return 1
  fi

  # Espacio libre en el destino temporal vs. tamaño total (descomprimido).
  # Best-effort: si no se puede leer alguno de los dos números, no bloquea
  # (mejor intentar y que falle la extracción con un error claro, que negar
  # un import legítimo por no poder medir).
  local total_kb avail_kb tmp_base
  total_kb=$(( IMPORT_TAR_TOTAL_BYTES / 1024 + 1 ))
  [[ "$IMPORT_TAR_TOTAL_BYTES" -gt 0 ]] || total_kb=""
  tmp_base="${TMPDIR:-/tmp}"
  avail_kb="$(df --output=avail -k "$tmp_base" 2>/dev/null | tail -n1 | tr -dc '0-9')" || true
  if [[ -n "$total_kb" && -n "$avail_kb" && "$avail_kb" -lt "$total_kb" ]]; then
    hli_error "no hay espacio suficiente en $tmp_base para extraer el backup (necesita ~${total_kb}KB, disponibles ${avail_kb}KB)."
    return 1
  fi

  # Extraer. '--no-same-owner --no-same-permissions': el contenido queda
  # con el dueño/permisos del proceso actual (no los que traía el tar,
  # potencialmente ajenos/root de otra máquina); cada importer_* fija el
  # dueño final correcto al copiar desde acá hacia APPDATA. Stderr de tar NO
  # se descarta: si algo sale mal se ve en el mensaje de error.
  work="$(mktemp -d)"
  IMPORT_WORK_DIR="$work"
  # Archivo de avisos de tar: hermano del directorio ($work.err), así
  # importer_cleanup lo borra junto con él aunque se interrumpa.
  local tar_err="" errf="$work.err"
  : > "$errf"
  if ! _importer_tar_extract "$tar_path" "$work" "${IMPORT_TAR_TOTAL_BYTES:-0}" "$errf"; then
    tar_err="$(head -c 300 "$errf")" || tar_err=""
    rm -f "$errf"
    hli_error "no se pudo extraer '$tar_path'. Detalle: $tar_err"
    rm -rf "$work"; IMPORT_WORK_DIR=""
    return 1
  fi
  tar_err="$(head -c 500 "$errf")" || tar_err=""
  rm -f "$errf"
  [[ -z "$tar_err" ]] || log "importer_extract: aviso de tar al extraer '$tar_path': $tar_err" 2>/dev/null || true

  # Defensa en profundidad: aunque el listado ya se validó, confirmar con
  # realpath que NINGÚN archivo extraído terminó resolviendo fuera de $work
  # (cubre además el caso de un hardlink/symlink que el tar hubiera creado
  # por otra vía no capturada por el parseo del listado).
  local f rp work_rp
  work_rp="$(realpath "$work")"
  while IFS= read -r -d '' f; do
    rp="$(realpath -m "$f" 2>/dev/null)" || continue
    case "$rp" in
      "$work_rp"|"$work_rp"/*) : ;;
      *)
        hli_error "un archivo extraído resuelve fuera del directorio temporal ($f -> $rp). Se aborta."
        rm -rf "$work"; IMPORT_WORK_DIR=""
        return 1
        ;;
    esac
  done < <(find "$work" -mindepth 1 -print0)

  if [[ ! -f "$work/config.yml" ]]; then
    hli_error "el tar no tiene 'config.yml' en la raíz: no parece un backup válido del HLI v1."
    rm -rf "$work"; IMPORT_WORK_DIR=""
    return 1
  fi

  local known=0 d
  for d in jellyfin qbittorrent adguard samba hli ssh; do
    [[ -d "$work/$d" ]] && known=1
  done
  if [[ "$known" -eq 0 ]]; then
    hli_error "el tar no contiene ninguna carpeta de componente conocida (jellyfin/qbittorrent/adguard/samba/hli/ssh)."
    rm -rf "$work"; IMPORT_WORK_DIR=""
    return 1
  fi

  return 0
}

importer_cleanup() {
  local work="$1"
  if [[ -n "$work" ]]; then rm -rf "$work"; rm -f "$work.err" "$work.err.done"; fi
  return 0
}

# Contenedores que ESTE proceso detuvo para importar y todavía no volvieron a
# levantarse (por redespliegue o despliegue del módulo). 'restart:
# unless-stopped' no reinicia un contenedor detenido a mano, así que si el
# proceso falla o se interrumpe antes del despliegue, importer_exit_cleanup
# los vuelve a arrancar (la config ya copiada es aceptable; dejar el
# servicio caído, no: AdGuard es el DNS de la casa).
IMPORT_STOPPED_CONTAINERS=""

importer_stopped_add() {
  IMPORT_STOPPED_CONTAINERS+="$1 "
}

importer_stopped_clear() {
  IMPORT_STOPPED_CONTAINERS="${IMPORT_STOPPED_CONTAINERS// $1 / }"
  IMPORT_STOPPED_CONTAINERS="${IMPORT_STOPPED_CONTAINERS/#$1 /}"
}

# Trap EXIT de import-v1: borra el directorio de extracción,
# vuelve a arrancar lo que quedó detenido y restaura el eco del teclado.
# Vuelve a iniciar un contenedor detenido por la importación. Si falla (p. ej.
# sudo sin contraseña en caché tras una espera larga), lo deja registrado en
# stderr y en el log con el comando exacto: nunca un servicio caído en silencio.
_importer_restart_container() {
  local c="$1"
  hli_docker start "$c" >/dev/null 2>&1 && return 0
  hli_error "no se pudo volver a iniciar el contenedor '$c'. Inícielo a mano: sudo docker start $c"
  return 1
}

importer_exit_cleanup() {
  local c
  if [[ -n "${IMPORT_WORK_DIR:-}" ]]; then importer_cleanup "$IMPORT_WORK_DIR"; fi
  for c in ${IMPORT_STOPPED_CONTAINERS:-}; do
    _importer_restart_container "$c" || true
  done
  IMPORT_STOPPED_CONTAINERS=""
  hli_busy_end
  return 0
}

# --- Seguridad: estado del contenedor destino --------------------------------

# ¿Es seguro importar sobre el servicio $1 (id de services/<id>.conf, KIND
# container) sin más trámite? Solo "detenido", "no instalado" o "docker no
# disponible" (el contenedor sencillamente no existe) lo son. "activo" y
# "desconocido" NUNCA: fallar cerrado ante cualquier duda, nunca escribir
# appdata de un servicio que puede estar corriendo ahora mismo. Para decidir
# qué hacer con cada uno de esos dos casos, ver importer_gate_service.
importer_container_safe() {
  local service_id="$1" state
  state="$(service_state "$service_id")"
  case "$state" in
    detenido|"no instalado"|"docker no disponible") return 0 ;;
    *) return 1 ;;
  esac
}

# Servicios (ids) que el usuario aceptó detener para importar; se vuelven a
# desplegar (o no, ver importer_apply_service) al terminar.
IMPORT_STOP_IDS=" "

# Decide, ANTES de extraer nada, si se importa sobre el servicio $1 ($2 =
# nombre para mostrar). Retorna 0 = continuar, 1 = omitir (ya se avisó al
# usuario por msg).
#   detenido / no instalado / docker no disponible -> continuar.
#   activo      -> ofrece detenerlo, importar y volver a desplegarlo; si el
#                  usuario acepta, queda marcado en IMPORT_STOP_IDS (el
#                  stop real ocurre en importer_apply_service, justo antes de
#                  copiar: así un fallo de extracción no deja el servicio
#                  parado). Si no, se omite explícitamente.
#   desconocido (u otro) -> mensaje aparte: no se pudo consultar Docker.
#                  NUNCA se mezcla con "activo".
importer_gate_service() {
  local service_id="$1" label="$2" state
  state="$(service_state "$service_id")"
  case "$state" in
    detenido|"no instalado"|"docker no disponible")
      return 0
      ;;
    activo)
      if confirm "El servicio $label está corriendo. ¿Detenerlo, importar su configuración y volver a desplegarlo?"; then
        IMPORT_STOP_IDS+="$service_id "
        return 0
      fi
      msg "$label: se omite la importación (el servicio sigue corriendo, sin cambios)."
      return 1
      ;;
    *)
      msg "No se pudo consultar el estado de Docker (¿sudo sin contraseña en caché?). Se omite $label por seguridad."
      return 1
      ;;
  esac
}

# ¿El usuario aceptó detener el servicio $1 en importer_gate_service?
importer_will_stop() {
  [[ "${IMPORT_STOP_IDS:- }" == *" $1 "* ]]
}

# Vuelve a desplegar el servicio $1 con el composeId registrado por el
# módulo del servicio (dokploy_compose_id_for: el mismo compose que
# desplegó modules/<id>.sh, revalidado contra Dokploy). Si no hay composeId
# registrado, falla: sin él habría que re-renderizar el compose, que es
# justamente lo que hace el módulo del servicio.
importer_redeploy_service() {
  local service_id="$1" composeId
  composeId="$(dokploy_compose_id_for "$service_id")" || return 1
  [[ -n "$composeId" ]] || return 1
  hli_busy "Volviendo a desplegar $service_id en Dokploy..."
  dokploy_compose_deploy "$composeId"
}

# Corre la importación $2 (función importer_*) sobre el directorio extraído $3
# para el servicio $1 ($4 = nombre para mostrar), con el ciclo de
# detener/volver a desplegar si el usuario lo aceptó en importer_gate_service.
# Códigos: 0 = todo bien; 1 = falló la importación (se intenta dejar el
# contenedor como estaba: se vuelve a arrancar); 10 = importado, pero el
# redespliegue falló (la configuración YA está importada).
importer_apply_service() {
  local service_id="$1" fn="$2" dir="$3" label="$4"
  local container rc=0 stopped=0
  container="$(service_get "$service_id" CONTAINER)" || container="$service_id"

  if importer_will_stop "$service_id"; then
    hli_busy "Deteniendo $label..."
    # Se registra ANTES de detener: si 'docker stop' devuelve error pero el
    # contenedor igual se detuvo, la trampa de salida lo vuelve a iniciar.
    importer_stopped_add "$container"
    if ! hli_docker stop "$container" >/dev/null 2>&1; then
      if [[ "$(hli_docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" == "true" ]]; then
        importer_stopped_clear "$container"
      fi
      hli_error "no se pudo detener el contenedor '$container'; se omite la importación de $label."
      msg "No se pudo detener $label. No se importó nada de este servicio."
      return 1
    fi
    stopped=1
  fi

  hli_busy "Copiando $label..."
  "$fn" "$dir" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    hli_error "falló la importación de $label (código $rc)."
    if [[ "$stopped" -eq 1 ]]; then
      _importer_restart_container "$container" && importer_stopped_clear "$container"
    fi
    return 1
  fi

  if [[ "$stopped" -eq 1 ]]; then
    if importer_redeploy_service "$service_id"; then
      importer_stopped_clear "$container"
    else
      # La config ya está copiada: al menos dejar el servicio corriendo.
      _importer_restart_container "$container" && importer_stopped_clear "$container"
      hli_error "no se pudo volver a desplegar $label tras importar."
      msg "La configuración de $label ya está importada, pero no se pudo volver a desplegar. Ejecute el módulo de $label desde el menú para desplegarlo."
      return 10
    fi
  fi
  return 0
}

# ¿El destino $1 ya tiene contenido? (para pedir confirmación antes de
# pisarlo). "No existe" y "existe pero vacío" cuentan como "sin contenido".
importer_dest_has_content() {
  local dest="$1"
  [[ -d "$dest" ]] || return 1
  [[ -n "$(sudo find "$dest" -mindepth 1 -print -quit 2>/dev/null)" ]]
}

# --- Jellyfin ----------------------------------------------------------------

# Copia jellyfin/lib -> APPDATA/jellyfin/config (raíz del volumen /config,
# JELLYFIN_DATA_DIR) y jellyfin/etc -> APPDATA/jellyfin/config/config
# (JELLYFIN_CONFIG_DIR, subcarpeta DENTRO del mismo volumen). Reescribe
# referencias absolutas a las rutas nativas viejas dentro de los archivos de
# texto copiados (XML/json), porque esos paths quedaron grabados adentro de
# la config y la ruta nueva dentro del contenedor es /config (no
# /var/lib/jellyfin). Ajusta dueño a SERVER_USER:MEDIA_GROUP (mismo uid/gid
# que usa el compose vía 'user:').
importer_jellyfin() {
  local extract_dir="$1" dest="$APPDATA_ROOT/jellyfin/config"
  local src_lib="$extract_dir/jellyfin/lib" src_etc="$extract_dir/jellyfin/etc"

  if [[ ! -d "$src_lib" && ! -d "$src_etc" ]]; then
    echo "El backup no incluye datos de Jellyfin (jellyfin/lib ni jellyfin/etc); nada que importar." >&2
    return 0
  fi

  sudo mkdir -p "$dest" "$dest/config"

  [[ -d "$src_lib" ]] && sudo rsync -aHAX "$src_lib/" "$dest/"
  [[ -d "$src_etc" ]] && sudo rsync -aHAX "$src_etc/" "$dest/config/"

  # Reescritura de rutas viejas: solo archivos de texto (XML/json/config);
  # 'grep -Il' descarta binarios. Best-effort: un archivo puntual que falle
  # no debe abortar el resto.
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    sudo sed -i \
      -e 's#/var/lib/jellyfin#/config#g' \
      -e 's#/etc/jellyfin#/config/config#g' \
      "$f" 2>/dev/null || true
  done < <(sudo grep -rIl -e '/var/lib/jellyfin' -e '/etc/jellyfin' "$dest" 2>/dev/null || true)

  sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$dest"
}

# --- qBittorrent -------------------------------------------------------------

# Copia qbittorrent/config (~/.config/qBittorrent nativo) y qbittorrent/share
# (~/.local/share/qBittorrent nativo, incluye BT_backup/*.fastresume) al
# MISMO destino APPDATA/qbittorrent/config/qBittorrent: la imagen
# linuxserver/qbittorrent no separa config de datos (ver
# compose/qbittorrent/docker-compose.yml). Avisa (no reescribe) si
# Session\DefaultSavePath en qBittorrent.conf no apunta a una raíz de media
# montada: al mantenerse rutas /srv/media... idénticas dentro/fuera del
# contenedor debería seguir siendo válida tal cual; si no lo es, hay que
# revisarla a mano.
importer_qbittorrent() {
  local extract_dir="$1" dest="$APPDATA_ROOT/qbittorrent/config/qBittorrent"
  local src_cfg="$extract_dir/qbittorrent/config" src_share="$extract_dir/qbittorrent/share"

  if [[ ! -d "$src_cfg" && ! -d "$src_share" ]]; then
    echo "El backup no incluye datos de qBittorrent; nada que importar." >&2
    return 0
  fi

  sudo mkdir -p "$dest"
  [[ -d "$src_cfg" ]] && sudo rsync -aHAX "$src_cfg/" "$dest/"
  [[ -d "$src_share" ]] && sudo rsync -aHAX "$src_share/" "$dest/"

  sudo chown -R "$SERVER_USER:$MEDIA_GROUP" "$APPDATA_ROOT/qbittorrent"

  local conf="$dest/qBittorrent.conf" save_path root ok=0
  if [[ -f "$conf" ]]; then
    save_path="$(sudo sed -n 's/^Session\\DefaultSavePath=//p' "$conf" | head -n1 | tr -d '\r')" || true
    if [[ -n "$save_path" ]]; then
      while read -r root; do
        [[ -n "$root" ]] || continue
        [[ "$save_path" == "$root"* ]] && ok=1
      done < <(media_roots)
      if [[ "$ok" -eq 0 ]]; then
        echo "AVISO: Session\\DefaultSavePath en qBittorrent.conf ('$save_path') no cae bajo ninguna raíz de media montada ($MEDIA_ROOT...). Revíselo manualmente desde el WebUI." >&2
      fi
    fi
  fi
}

# --- AdGuard Home ------------------------------------------------------------

# Fuerza http.address (panel web) a "0.0.0.0:<puerto>" en el YAML $1,
# reemplazando SOLO la primera coincidencia (el bloque http, no otros
# 'address:' del archivo). Adaptado de
# homelab-installer/lib/common.sh:245-262 (adguard_normalize_bind), pero acá
# el puerto SIEMPRE se fuerza al que pasa el llamador (3053, registro de
# servicios) en vez de conservar el que traía el YAML importado: el objetivo
# no es solo "que levante" sino que el panel quede exactamente en 3053
# (3000 es de Dokploy).
adguard_yaml_set_http_address() {
  local yaml="$1" port="$2"
  sudo test -f "$yaml" || return 0
  sudo sed -i -E "0,/^[[:space:]]*address:[[:space:]]/ s|^([[:space:]]*address:[[:space:]]*).*\$|\\10.0.0.0:${port}|" "$yaml"
}

# Reemplaza TODA la lista dns.bind_hosts por una sola entrada 0.0.0.0, para
# escuchar en todas las interfaces del host (network_mode: host) sin
# arrastrar una IP vieja del servidor de origen. Adaptado de
# homelab-installer/lib/common.sh:245-262.
adguard_yaml_set_dns_bind() {
  local yaml="$1" tmp
  sudo test -f "$yaml" || return 0
  tmp="$(mktemp)"
  sudo awk '
    /^[[:space:]]*bind_hosts:[[:space:]]*$/ {
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
      print; print ind "  - 0.0.0.0"; in_bh = 1; next
    }
    in_bh && /^[[:space:]]*-[[:space:]]/ { next }
    { in_bh = 0; print }
  ' "$yaml" > "$tmp"
  # El temporal es del usuario (mktemp): se escribe SIN sudo. Con 'sudo tee'
  # falla en el servidor real: fs.protected_regular impide que root abra
  # para escritura un archivo ajeno en /tmp (validado en la X230).
  sudo cp "$tmp" "$yaml"
  rm -f "$tmp"
}

# --- AdGuard Home: usuario admin inicial ------------------------------------
#
# ¿El YAML $1 ya tiene al menos un usuario real bajo 'users:'? Un
# 'users: []' (lista vacía explícita) NO cuenta como "tiene usuarios": según
# la propia documentación de AdGuard Home (Configuration wiki, sección
# "users"), una lista vacía desactiva la autenticación — mismo caso que "no
# hay clave 'users:' en absoluto" para efectos de modules/adguard.sh (hay
# que crear un admin antes de arrancar el contenedor). Se lee siempre con
# 'sudo cat' (nunca un '[[ -f ]]'/'cat' plano): funciona sin importar si el
# archivo ya quedó en 0600 por una corrida anterior de
# adguard_yaml_append_user, o si todavía está en el modo por defecto de la
# siembra inicial.
adguard_yaml_has_users() {
  local yaml="$1"
  sudo test -f "$yaml" || return 1
  sudo cat -- "$yaml" 2>/dev/null | awk '
    /^users:[[:space:]]*$/ { in_users = 1; next }
    # Cualquier entrada de lista bajo users: cuenta como usuario existente
    # (sin depender del orden de las claves name/password): ante la duda,
    # nunca se reemplaza la lista. Clases POSIX, no '\S': el awk por defecto
    # de Ubuntu es mawk, que no entiende las extensiones de gawk.
    in_users && /^[[:space:]]*-[[:space:]]*[^[:space:]]/ { found = 1; exit }
    /^[^[:space:]]/ { in_users = 0 }
    END { exit (found ? 0 : 1) }
  '
}

# Agrega un único usuario ($2 nombre, $3 hash bcrypt ya generado y validado
# por el llamador) a la sección 'users:' de nivel superior del YAML $1,
# preservando el resto del archivo intacto. Reemplaza una sección 'users:'
# existente SOLO si está vacía (ningún '- name:' adentro, o 'users: []')
# — este helper se llama únicamente después de que adguard_yaml_has_users ya
# confirmó que no hay usuarios reales que pudiera pisar; nunca se usa para
# agregar un segundo usuario a una lista con contenido.
#
# A propósito, NUNCA pasa por 'sed': el hash bcrypt contiene '$' y puede
# contener '/' (ambos con significado especial para los delimitadores
# habituales de 's///' y para el lado derecho de un reemplazo de sed, donde
# '&'/'\' son especiales), así que toda la transformación va por 'awk' con
# el usuario/hash pasados como variables (-v, nunca interpolados en el texto
# del programa awk en sí) — un simple 'print "..." hash' los imprime tal
# cual, sin que '$' dispare ninguna referencia a campo ($0/$1/...) porque esa
# sintaxis solo aplica en el CÓDIGO awk, nunca sobre el contenido de una
# variable de datos.
#
# El archivo nunca pasa por 'sudo sed -i'/'sudo awk' directo tampoco (esos
# subcomandos no están soportados por el stub de 'sudo' de los tests, ver
# tests/stubs/sudo): se lee con 'sudo cat', se transforma con 'awk' SIN sudo
# (no hace falta: ya está en una variable del proceso actual, no en el
# archivo root-only), y se vuelve a escribir con 'sudo tee' — mismo patrón
# que ya usa modules/adguard.sh (_adguard_seed_if_missing).
#
# Deja el archivo en 0600 root:root al terminar: a partir de acá contiene un
# hash bcrypt (un secreto, aunque resistente a fuerza bruta), y
# $APPDATA_ROOT queda 0755 por storage.sh/dokploy.sh (mundialmente
# listable/atravesable) — sin este endurecimiento, cualquier usuario local
# del host podría leer el hash directo del disco.
#
# 'install -m 0600' PRIMERO, 'tee' DESPUÉS (nunca 'tee' + 'chmod' al final):
# mismo criterio exacto que secret_file_write (lib/secrets.sh) — ese orden
# ("mkdir/tee + chmod después") deja una ventana en la que el archivo recién
# truncado por 'tee' tiene el modo por defecto del proceso (umask,
# típicamente 0644, legible por cualquiera) hasta que el chmod posterior
# corre. Acá el 0600 final se aplica ANTES de que 'tee' escriba una sola
# línea de contenido nuevo.
adguard_yaml_append_user() {
  local yaml="$1" user="$2" hash="$3" new_content
  sudo test -f "$yaml" || { hli_error "no existe $yaml"; return 1; }
  [[ -n "$user" && -n "$hash" ]] || { hli_error "adguard_yaml_append_user necesita usuario y hash."; return 1; }

  new_content="$(sudo cat -- "$yaml" 2>/dev/null | awk -v user="$user" -v hash="$hash" '
    BEGIN { done = 0; in_users = 0 }
    /^users:[[:space:]]*(\[\][[:space:]]*)?$/ && !done {
      print "users:"
      print "  - name: " user
      print "    password: " hash
      done = 1
      in_users = ($0 !~ /\[\]/)
      next
    }
    in_users && /^[[:space:]]/ { next }
    { in_users = 0; print }
    END {
      if (!done) {
        print "users:"
        print "  - name: " user
        print "    password: " hash
      }
    }
  ')" || return 1

  sudo install -m 0600 -o root -g root /dev/null "$yaml"
  printf '%s\n' "$new_content" | sudo tee "$yaml" >/dev/null
}

# Copia adguard/AdGuardHome.yaml del backup a APPDATA/adguard/conf y normaliza
# el panel al puerto del registro (services/adguard.conf, 3053) + DNS
# escuchando en todas las interfaces. Dueño root (AdGuard corre como root
# dentro del contenedor por defecto en esta imagen).
importer_adguard() {
  local extract_dir="$1" dest_dir="$APPDATA_ROOT/adguard/conf"
  local src="$extract_dir/adguard/AdGuardHome.yaml"
  local port

  [[ -f "$src" ]] || { echo "El backup no incluye adguard/AdGuardHome.yaml; nada que importar." >&2; return 0; }

  port="$(service_get adguard PORT)" || port="3053"
  sudo mkdir -p "$dest_dir"
  sudo cp "$src" "$dest_dir/AdGuardHome.yaml"

  adguard_yaml_set_http_address "$dest_dir/AdGuardHome.yaml" "$port"
  adguard_yaml_set_dns_bind "$dest_dir/AdGuardHome.yaml"

  sudo chown -R root:root "$dest_dir"
  # Root-only: el YAML importado trae el hash de la contraseña del panel.
  sudo chmod 0600 "$dest_dir/AdGuardHome.yaml"
  sudo chmod 0700 "$dest_dir"
}

# --- authorized_keys (SSH) ---------------------------------------------------

# Fusiona (deduplicando) las claves públicas del backup con las actuales del
# usuario del servidor. Adaptado de
# homelab-installer/lib/common.sh:324-336 (import_authorized_keys), usando
# SERVER_USER en vez de asumir el usuario del proceso actual.
importer_authorized_keys() {
  local extract_dir="$1"
  local src="$extract_dir/ssh/authorized_keys"
  local home

  [[ -f "$src" ]] || { echo "El backup no incluye ssh/authorized_keys; nada que fusionar." >&2; return 0; }

  home="$(getent passwd "$SERVER_USER" | cut -d: -f6)" || true
  home="${home:-/home/$SERVER_USER}"

  sudo -u "$SERVER_USER" mkdir -p "$home/.ssh"
  sudo -u "$SERVER_USER" chmod 700 "$home/.ssh"

  local tmp
  tmp="$(mktemp)"
  { cat "$src" 2>/dev/null; sudo -u "$SERVER_USER" cat "$home/.ssh/authorized_keys" 2>/dev/null; } \
    | sort -u > "$tmp"
  sudo -u "$SERVER_USER" cp "$tmp" "$home/.ssh/authorized_keys"
  sudo -u "$SERVER_USER" chmod 600 "$home/.ssh/authorized_keys"
  rm -f "$tmp"
}

# --- Samba (solo referencia, NUNCA se aplica) --------------------------------

# Imprime los nombres de recurso ([share]) del smb.conf del backup, solo para
# que el usuario los compare a ojo: Samba es nativo y su smb.conf lo genera
# el módulo "samba" de HLI 2 (v2.0) — importar el de v1 a ciegas pisaría esa
# generación con un formato/marcadores distintos.
importer_samba_reference() {
  local extract_dir="$1"
  local src="$extract_dir/samba/smb.conf"
  [[ -f "$src" ]] || { echo "El backup no incluye samba/smb.conf."; return 0; }
  echo "Recursos Samba del backup de v1 (solo referencia, no se importan):"
  grep -E '^\[.+\]$' "$src" 2>/dev/null || echo "  (ninguno encontrado)"
}
