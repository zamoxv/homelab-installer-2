#!/usr/bin/env bash
# Informe de diagnóstico del servidor para Hermes (v2.6d): un resumen FILTRADO
# y de solo lectura del estado del equipo (servicios, disco, backup, errores
# recientes), escrito cada 5 minutos en $REPORT_DIR/report.md. Hermes lo ve
# montado en solo lectura en /opt/host-report: diagnostica y recomienda, el
# usuario aplica. Ver ROADMAP.md, v2.6d.
#
# Esta biblioteca corre COMO ROOT: la invoca bin/hli2-report (servicio systemd
# hli2-report.service) siempre desde la copia root-owned en /usr/local/lib/hli2
# (la deja backup_refresh_install); root nunca ejecuta código de un checkout
# del usuario.
#
# Diseño (el agente puede ser manipulado por una página web: lo que entra acá
# es lo único del host que puede leer, y puede enviarlo afuera):
#   - Solo se consultan datos de una lista blanca: de 'docker inspect' nada más
#     que REPORT_INSPECT_FORMAT (estado, salud, reinicios, inicio, imagen);
#     jamás el entorno, las etiquetas, los montajes ni los argumentos.
#   - Todo lo que sale de un log, del journal o del archivo de estado pasa por
#     report_redact (patrones de secretos + los valores literales de
#     /etc/hli2/*.env) y el informe completo pasa otra vez antes de escribirse.
#   - Tamaño acotado (REPORT_MAX_BYTES) para no inflar el contexto de Hermes.
#   - Escritura atómica (archivo temporal en la misma carpeta + mv) en una
#     carpeta root:root 0755 con el informe 0644; el contenedor la monta :ro.
set -euo pipefail

# Carpeta del informe: regenerable, NO es un SERVICE_DATA (no entra en backups).
REPORT_DIR="${HLI2_REPORT_DIR:-$APPDATA_ROOT/hermes-report}"
REPORT_FILE="$REPORT_DIR/report.md"
# Topes (un solo lugar): informe completo, sección de logs de contenedores,
# renglones por origen y ancho de cada renglón.
REPORT_MAX_BYTES=65536
REPORT_LOGS_MAX_BYTES=24576
REPORT_LOG_LINES=20
REPORT_LOG_WIDTH=300
REPORT_LOG_TAIL=500
REPORT_LOG_SINCE_DOCKER="2h"
REPORT_LOG_SINCE_JOURNAL="2 hours ago"
REPORT_LOG_FILTER='error|warn|fail'
# Un valor de /etc/hli2/*.env más corto que esto no se enmascara (borraría
# palabras comunes del informe).
REPORT_MIN_SECRET_LEN=6
REPORT_MASK="<OCULTO>"
# Límite de espera de cada consulta externa (docker, journalctl, tailscale).
REPORT_CMD_TIMEOUT=20
# Única lista blanca de campos de 'docker inspect'.
REPORT_INSPECT_FORMAT='{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.StartedAt}}|{{.Config.Image}}'

# Archivo temporal con los valores literales a enmascarar (lo arma y borra
# report_main; report_redact lo usa si existe).
REPORT_SECRET_VALUES_FILE="${REPORT_SECRET_VALUES_FILE:-}"

# --- Privilegios y consultas externas ----------------------------------------------

# Como root (el servicio systemd) se ejecuta directo; si no (tests, uso manual)
# se antepone 'sudo -n', igual que el resto de la biblioteca.
_report_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo -n "$@"; fi
}

_report_docker() {
  if [[ "$(id -u)" -eq 0 ]]; then
    timeout "$REPORT_CMD_TIMEOUT" docker "$@"
  else
    timeout "$REPORT_CMD_TIMEOUT" sudo -n docker "$@"
  fi
}

_report_journal() {
  if [[ "$(id -u)" -eq 0 ]]; then
    timeout "$REPORT_CMD_TIMEOUT" journalctl "$@"
  else
    timeout "$REPORT_CMD_TIMEOUT" sudo -n journalctl "$@"
  fi
}

# --- Redacción -------------------------------------------------------------------------

# Reemplaza (literal, sin regex) cada valor de $REPORT_SECRET_VALUES_FILE, uno
# por línea y ordenados de mayor a menor longitud. La ruta viaja en una
# variable de awk (nunca los valores en argv). mawk: sin intervalos de regex.
_report_redact_literals() {
  local vf="${REPORT_SECRET_VALUES_FILE:-}"
  if [[ -z "$vf" || ! -s "$vf" ]]; then cat; return 0; fi
  LC_ALL=C awk -v vf="$vf" -v mask="$REPORT_MASK" '
    BEGIN { while ((getline l < vf) > 0) if (length(l) > 0) v[++n] = l; close(vf) }
    {
      line = $0
      for (i = 1; i <= n; i++) {
        s = v[i]; ls = length(s); out = ""
        while ((p = index(line, s)) > 0) {
          out = out substr(line, 1, p - 1) mask
          line = substr(line, p + ls)
        }
        line = out line
      }
      print line
    }'
}

# Tramos largos de base64 (>= 40 caracteres con mayúsculas, minúsculas y
# dígitos: así no se tocan rutas ni palabras largas).
_report_redact_b64() {
  LC_ALL=C awk -v mask="$REPORT_MASK" '
    {
      line = $0; out = ""
      while (match(line, /[A-Za-z0-9+\/_=-]+/)) {
        run = substr(line, RSTART, RLENGTH)
        pre = substr(line, 1, RSTART - 1)
        if (RLENGTH >= 40 && run ~ /[A-Z]/ && run ~ /[a-z]/ && run ~ /[0-9]/) run = mask
        out = out pre run
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }'
}

# stdin -> stdout sin secretos. Orden: valores literales de /etc/hli2, bloques
# de claves privadas, patrones conocidos y base64 largo.
# Las variables 'clave=valor' se enmascaran con '=' o con ':' + espacio/comilla
# (estilo de logs y JSON); 'nombre:1.0' sin espacio no (así no se pierden las
# etiquetas de imágenes como 'authelia:4.38').
report_redact() {
  local m="$REPORT_MASK"
  local kv='(password|passwd|pwd|passphrase|token|secret|api[_-]?key|apikey|access[_-]?key|private[_-]?key|credential|auth|key)[A-Za-z0-9_.-]*"?'
  local val='[^[:space:]",;&})]+'
  _report_redact_literals \
    | LC_ALL=C sed -zE "s/-----BEGIN [A-Z ]*PRIVATE KEY-----[A-Za-z0-9+\/=[:space:]]*(-----END [A-Z ]*PRIVATE KEY-----)?/${m}/g" \
    | LC_ALL=C sed -E \
      -e "s/sk-or-[A-Za-z0-9_-]+/${m}/g" \
      -e "s/sk-[A-Za-z0-9_-]{20,}/${m}/g" \
      -e "s/gh[pousr]_[A-Za-z0-9]{20,}/${m}/g" \
      -e "s/AKIA[0-9A-Z]{16}/${m}/g" \
      -e "s/[0-9]{6,}:[A-Za-z0-9_-]{30,}/${m}/g" \
      -e "s/eyJ[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){0,2}/${m}/g" \
      -e "s/(authorization|proxy-authorization)[[:space:]]*[:=][[:space:]]*(bearer|basic|token)?[[:space:]]*[^[:space:]\",;]+/\1: ${m}/Ig" \
      -e "s/(bearer)[[:space:]]+[A-Za-z0-9._~+\/=-]+/\1 ${m}/Ig" \
      -e "s#(://)[^/@[:space:]]+@#\1${m}@#g" \
      -e "s/(${kv}[[:space:]]*=[[:space:]]*\"?)${val}/\1${m}/Ig" \
      -e "s/(${kv}:[[:space:]]+\"?)${val}/\1${m}/Ig" \
      -e "s/(${kv}:\")${val}/\1${m}/Ig" \
      -e "s/[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+)/${m}@\1/g" \
      -e "s/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/<IP>/g" \
      -e "s/\b([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}\b/<IP>/g" \
      -e "s/\b([0-9A-Fa-f]{1,4}:){1,7}:([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,6})?\b/<IP>/g" \
      -e "s/::([0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4}\b/<IP>/g" \
      -e "s/[0-9A-Fa-f]{32,}/${m}/g" \
    | _report_redact_b64
}

# Arma el archivo temporal con los valores de /etc/hli2/*.env (y de la
# contraseña de restic): el valor de cada 'CLAVE=valor', sin comillas
# envolventes, de al menos REPORT_MIN_SECRET_LEN caracteres, de mayor a menor
# longitud. Escribe en $1 (ya creado 0600). Nunca imprime ni registra valores.
_report_collect_secret_values() {
  local out="$1" f line val raw="" first_only=0
  local -a files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(_report_as_root find "$SECRETS_DIR" -maxdepth 1 -type f \( -name '*.env' -o -name 'restic-password' \) 2>/dev/null | sort || true)
  for f in "${files[@]}"; do
    first_only=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      case "$f" in
        */restic-password) val="$line"; first_only=1 ;;
        *)
          [[ "$line" == *=* && "$line" != \#* ]] || continue
          val="${line#*=}"
          ;;
      esac
      if [[ "$val" == \"*\" && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
      elif [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"; fi
      (( ${#val} >= REPORT_MIN_SECRET_LEN )) || continue
      raw+="${#val}"$'\t'"$val"$'\n'
      [[ "$first_only" -eq 0 ]] || break
    done < <(_report_as_root cat -- "$f" 2>/dev/null || true)
    # La contraseña de restic es una sola línea: solo cuenta la primera.
  done
  [[ -n "$raw" ]] || return 0
  printf '%s' "$raw" | LC_ALL=C sort -t$'\t' -k1,1nr | cut -f2- > "$out"
}

# --- Tope de tamaño ---------------------------------------------------------------------

# stdin -> stdout recortado a $1 bytes (con aviso).
_report_cap() {
  local max="$1" t
  local LC_ALL=C   # longitudes en bytes
  t="$(cat; printf x)"
  t="${t%x}"
  if (( ${#t} > max )); then
    printf '%s' "${t:0:max}"
    printf '\n[... recortado por el límite de tamaño ...]\n'
  else
    printf '%s' "$t"
  fi
}

# --- Utilidades de formato ---------------------------------------------------------------

# Duración legible entre ahora y la fecha ISO $1 ('-' si no es válida).
_report_since_human() {
  local iso="$1" start now d h m s
  [[ "$iso" == 0001-* ]] && { echo "-"; return; }
  start="$(date -d "$iso" +%s 2>/dev/null)" || { echo "-"; return; }
  now="$(date +%s)"
  s=$(( now - start ))
  (( s >= 0 )) || { echo "-"; return; }
  d=$(( s / 86400 )); h=$(( s % 86400 / 3600 )); m=$(( s % 3600 / 60 ))
  if (( d > 0 )); then echo "${d}d ${h}h"
  elif (( h > 0 )); then echo "${h}h ${m}m"
  else echo "${m}m"; fi
}

# Quita el digest de una referencia de imagen (nombre:etiqueta@sha256:...).
_report_image_tag() {
  printf '%s' "${1%%@*}"
}

# Texto sin '|' ni saltos de línea (cabe en una celda de tabla).
_report_cell() {
  local t="${1//$'\n'/ }"
  printf '%s' "${t//|//}"
}

# --- Secciones ------------------------------------------------------------------------------

_report_section_system() {
  local up load mem swap
  up="$(uptime -p 2>/dev/null || true)"
  load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || true)"
  printf '## Sistema\n\n'
  printf -- '- Encendido: %s\n' "${up:-N/D}"
  printf -- '- Carga (1, 5 y 15 min): %s\n' "${load:-N/D}"
  mem="$(free -m 2>/dev/null | awk '/^Mem:/ { printf "%d MiB usados de %d MiB (disponibles: %d MiB)", $3, $2, $7 }' || true)"
  swap="$(free -m 2>/dev/null | awk '/^Swap:/ { printf "%d MiB usados de %d MiB", $3, $2 }' || true)"
  printf -- '- Memoria: %s\n' "${mem:-N/D}"
  printf -- '- Swap: %s\n\n' "${swap:-N/D}"
}

_report_df_row() {
  local label="$1" path="$2" line
  [[ -e "$path" ]] || { printf '| %s | %s | sin montar o inexistente | | | |\n' "$label" "$path"; return 0; }
  line="$(df -h --output=size,used,avail,pcent -- "$path" 2>/dev/null | tail -n1 | awk '{ print $1 " | " $2 " | " $3 " | " $4 }')" || line=""
  if [[ -n "$line" ]]; then
    printf '| %s | %s | %s |\n' "$label" "$path" "$line"
  else
    printf '| %s | %s | N/D | | | |\n' "$label" "$path"
  fi
}

_report_section_disk() {
  local mr
  printf '## Disco\n\n| Qué | Ruta | Total | Usado | Libre | Uso |\n|---|---|---|---|---|---|\n'
  _report_df_row "Sistema" "/"
  _report_df_row "Datos de servicios" "$APPDATA_ROOT"
  while IFS= read -r mr; do
    [[ -n "$mr" ]] || continue
    _report_df_row "Media" "$mr"
  done < <(media_roots 2>/dev/null || true)
  _report_df_row "Repositorio de backups" "$BACKUP_ROOT"
  printf '\n'
}

# Una fila de la tabla de servicios para un contenedor. Solo REPORT_INSPECT_FORMAT.
# Deja el nombre del contenedor en $1 para que la sección de logs sepa cuáles existen.
_report_container_row() {
  local name="$1" disp="$2" out status health restarts started image state up
  if ! out="$(_report_docker inspect -f "$REPORT_INSPECT_FORMAT" "$name" 2>/dev/null)" || [[ -z "$out" ]]; then
    if _report_docker info >/dev/null 2>&1; then state="no instalado"; else state="desconocido (Docker no responde)"; fi
    printf '| %s | contenedor | %s | | | | |\n' "$(_report_cell "$disp")" "$state"
    return 0
  fi
  IFS='|' read -r status health restarts started image <<<"$out"
  case "$status" in
    running) state="running" ;;
    *) state="stopped ($status)" ;;
  esac
  [[ "$health" != "unhealthy" ]] || state="unhealthy"
  up="-"
  [[ "$status" != "running" ]] || up="$(_report_since_human "$started")"
  printf '| %s | contenedor | %s | %s | %s | %s | %s |\n' \
    "$(_report_cell "$disp")" "$state" "$health" "${restarts:-0}" "$up" "$(_report_cell "$(_report_image_tag "$image")")"
}

_report_section_services() {
  local id kind disp name unit st replicas
  printf '## Servicios\n\n| Servicio | Tipo | Estado | Salud | Reinicios | Activo hace | Imagen |\n|---|---|---|---|---|---|---|\n'
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    disp="$(service_display_name "$id" 2>/dev/null || echo "$id")"
    kind="$(service_get "$id" KIND 2>/dev/null || true)"
    case "$kind" in
      container)
        name="$(service_get "$id" CONTAINER 2>/dev/null || true)"
        _report_container_row "$name" "$disp"
        ;;
      native)
        unit="$(service_get "$id" UNIT 2>/dev/null || true)"
        st="$(systemctl is-active "$unit" 2>/dev/null || true)"
        printf '| %s | systemd | %s | | | | |\n' "$(_report_cell "$disp")" "$(_report_cell "${st:-desconocido}")"
        ;;
      swarm)
        name="$(service_get "$id" CONTAINER 2>/dev/null || true)"
        replicas="$(_report_docker service ls --filter "name=$name" --format '{{.Replicas}}' 2>/dev/null | head -n1 || true)"
        printf '| %s | swarm | réplicas %s | | | | |\n' "$(_report_cell "$disp")" "$(_report_cell "${replicas:-N/D}")"
        ;;
      *)
        printf '| %s | desconocido | | | | | |\n' "$(_report_cell "$disp")"
        ;;
    esac
  done < <(service_list)
  printf '\n'
}

_report_section_failed_units() {
  local out
  printf '## Unidades de systemd fallidas\n\n'
  out="$(systemctl --failed --no-legend --plain 2>/dev/null | cut -c1-"$REPORT_LOG_WIDTH" | head -n "$REPORT_LOG_LINES" || true)"
  if [[ -n "$out" ]]; then printf '```\n%s\n```\n\n' "$out"; else printf 'Ninguna.\n\n'; fi
}

_report_section_backup() {
  local res ts msg loc cloud chk
  printf '## Último backup\n\n'
  if [[ ! -r "$BACKUP_STATUS_FILE" ]]; then
    printf 'Sin backups todavía.\n\n'
    return 0
  fi
  ts="$(backup_status_get timestamp)"; res="$(backup_status_get result)"
  loc="$(backup_status_get local)"; cloud="$(backup_status_get cloud)"
  chk="$(backup_status_get check)"; msg="$(backup_status_get message)"
  printf -- '- Fecha: %s\n- Resultado: %s\n- Copia local: %s\n- Copia externa: %s\n- Chequeo de integridad: %s\n' \
    "${ts:-N/D}" "${res:-N/D}" "${loc:-N/D}" "${cloud:-N/D}" "${chk:-N/D}"
  [[ -z "$msg" ]] || printf -- '- Detalle: %s\n' "$(printf '%s' "$msg" | cut -c1-"$REPORT_LOG_WIDTH")"
  printf '\n'
}

_report_section_tailscale() {
  printf '## Tailscale\n\n'
  if ! command -v tailscale >/dev/null 2>&1; then
    printf 'No instalado.\n\n'
  elif timeout "$REPORT_CMD_TIMEOUT" tailscale status >/dev/null 2>&1; then
    printf 'Conectado.\n\n'
  else
    printf 'Desconectado (o sin sesión iniciada).\n\n'
  fi
}

# Últimos renglones con error|warn|fail de un contenedor (sin redactar: lo hace el llamador).
_report_container_log_errors() {
  local name="$1"
  _report_docker logs --since "$REPORT_LOG_SINCE_DOCKER" --tail "$REPORT_LOG_TAIL" "$name" 2>&1 \
    | { grep -iE "$REPORT_LOG_FILTER" || true; } \
    | tail -n "$REPORT_LOG_LINES" \
    | cut -c1-"$REPORT_LOG_WIDTH"
}

_report_section_container_logs() {
  local id name out body="" any=0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ "$(service_get "$id" KIND 2>/dev/null || true)" == "container" ]] || continue
    name="$(service_get "$id" CONTAINER 2>/dev/null || true)"
    [[ -n "$name" ]] || continue
    _report_docker inspect -f '{{.State.Status}}' "$name" >/dev/null 2>&1 || continue
    out="$(_report_container_log_errors "$name" 2>/dev/null | report_redact || true)"
    [[ -n "$out" ]] || continue
    any=1
    body+="### ${name}"$'\n\n```\n'"${out}"$'\n```\n\n'
  done < <(service_list)
  printf '## Errores recientes de los contenedores (últimas 2 horas)\n\n'
  if [[ "$any" -eq 0 ]]; then printf 'Ninguno.\n\n'; else printf '%s' "$body" | _report_cap "$REPORT_LOGS_MAX_BYTES"; fi
}

_report_section_journal() {
  local out
  printf '## Errores recientes del journal (docker y hli2, últimas 2 horas)\n\n'
  out="$(_report_journal -u docker.service -u 'hli2-*' --since "$REPORT_LOG_SINCE_JOURNAL" --no-pager -q -o short-iso 2>/dev/null \
    | { grep -iE "$REPORT_LOG_FILTER" || true; } | tail -n "$REPORT_LOG_LINES" | cut -c1-"$REPORT_LOG_WIDTH" | report_redact || true)"
  if [[ -n "$out" ]]; then printf '```\n%s\n```\n\n' "$out"; else printf 'Ninguno.\n\n'; fi
}

# --- Armado y escritura -----------------------------------------------------------------------

# Zona horaria del servidor (la configurada, no la de UTC por omisión).
_report_timezone() {
  local tz
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [[ -n "$tz" ]] || tz="$(date +%Z)"
  printf '%s' "$tz"
}

# Ejecuta una sección; si falla por cualquier motivo, el informe sigue.
_report_run_section() {
  "$@" || printf '(sección no disponible)\n\n'
}

# Informe completo por stdout, ya redactado y acotado.
report_build() {
  {
    printf '# Informe del servidor\n\n'
    printf 'Generado: %s (zona horaria: %s) en el equipo %s.\n' "$(date -Is)" "$(_report_timezone)" "$(hostname 2>/dev/null || echo N/D)"
    printf 'Se actualiza cada 5 minutos: si la fecha de arriba es mucho más vieja, el temporizador hli2-report.timer no está corriendo.\n'
    printf 'Es solo lectura y está filtrado (sin secretos, sin IP).\n\n'
    _report_run_section _report_section_system
    _report_run_section _report_section_disk
    _report_run_section _report_section_services
    _report_run_section _report_section_failed_units
    _report_run_section _report_section_backup
    _report_run_section _report_section_tailscale
    _report_run_section _report_section_container_logs
    _report_run_section _report_section_journal
    printf 'Fin del informe.\n'
  } | report_redact | { if command -v iconv >/dev/null 2>&1; then iconv -f UTF-8 -t UTF-8 -c; else cat; fi; } | _report_cap "$REPORT_MAX_BYTES"
}

# Carpeta del informe: propia de root, no un enlace simbólico, 0755. La corrige
# si otra herramienta cambió el dueño (p. ej. un 'chown -R' sobre appdata).
_report_dir_ensure() {
  if [[ -L "$REPORT_DIR" ]]; then
    echo "ERROR: $REPORT_DIR es un enlace simbólico: no se escribe el informe." >&2
    return 1
  fi
  _report_as_root install -d -m 0755 -o root -g root "$REPORT_DIR" 2>/dev/null || install -d -m 0755 "$REPORT_DIR" 2>/dev/null || true
  if [[ -L "$REPORT_DIR" || ! -d "$REPORT_DIR" ]]; then
    echo "ERROR: $REPORT_DIR no es una carpeta válida." >&2
    return 1
  fi
}

# Escribe $1 (texto) en $REPORT_FILE de forma atómica: archivo temporal en la
# MISMA carpeta (0644) y mv (rename). Si algo falla, el informe anterior queda
# intacto y no sobra el temporal.
report_write() {
  local content="$1" tmp
  _report_dir_ensure || return 1
  tmp="$(mktemp "$REPORT_DIR/.report.XXXXXX")" || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! chmod 0644 "$tmp" || ! mv -f -- "$tmp" "$REPORT_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Entrada del servicio: junta los valores secretos, arma y escribe el informe.
report_main() {
  local vf text rc=0
  vf="$(mktemp)" || return 1
  chmod 0600 "$vf"
  _report_collect_secret_values "$vf" || true
  REPORT_SECRET_VALUES_FILE="$vf"
  text="$(report_build)" || rc=$?
  REPORT_SECRET_VALUES_FILE=""
  rm -f -- "$vf"
  if [[ "$rc" -ne 0 || -z "$text" ]]; then
    echo "ERROR: no se pudo armar el informe." >&2
    return 1
  fi
  report_write "$text"
}
