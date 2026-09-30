#!/usr/bin/env bash
# Almacenamiento local de secretos de servicio (ADMIN_TOKEN de Vaultwarden,
# INITIAL_ADMIN_PASSWORD de OpenCloud...): un archivo "CLAVE=valor" por
# línea, root-only 0600, en /etc/hli2/<servicio>.env. Mismo patrón de
# creación segura que $DOKPLOY_ENV_FILE (lib/dokploy_api.sh):
#   install -m 0600 /dev/null <archivo>   # crea YA con el modo final
#   tee <archivo>                          # solo trunca+escribe, no reabre
# Nunca "mkdir + tee + chmod después": ese orden deja una ventana en la que
# el archivo recién creado por 'tee' tiene el modo por defecto del proceso
# (umask, típicamente 0644 — legible por cualquiera) hasta que el chmod
# posterior corre. Acá el 0600 se aplica ANTES de escribir una sola línea.
set -euo pipefail

# 'HLI2_SECRETS_DIR' (no 'SECRETS_DIR' pelado): ver el comentario sobre
# namespacing en lib/core.sh (LOG_DIR/STATE_DIR) — mismo motivo acá.
SECRETS_DIR="${HLI2_SECRETS_DIR:-/etc/hli2}"

# --- Lectura privilegiada de archivos root-only -----------------------------
#
# /etc/hli2 se crea 0700 root:root (ver secret_file_write) — el usuario sin
# privilegios que corre bootstrap.sh NO puede ni siquiera ATRAVESAR ese
# directorio (falta permiso de búsqueda/ejecución), así que un '[[ -f ]]' o
# un 'cat'/'sed' sin privilegios sobre un archivo de ahí adentro fallan
# SIEMPRE (permiso denegado), exista o no el archivo. Esto es lo que rompía
# "reusar el secreto existente": secret_file_exists/secret_get devolvían
# "no existe" incondicionalmente, nunca "sí existe pero hace falta sudo para
# leerlo". Hallazgo de una revisión de seguridad posterior a la primera
# versión de v2.3 — se corrigió leyendo TODO acceso a estos archivos vía
# 'sudo -n' (non-interactive: bootstrap.sh ya cachea sudo con un keepalive,
# así que esto no debería pedir contraseña). Mismo problema y misma
# corrección aplican a _dokploy_env_get en lib/dokploy_api.sh.
#
# Fail-closed: si 'sudo -n' en sí no funciona (sesión de sudo no cacheada o
# expirada), NUNCA se asume "el archivo no existe" — eso llevaría a
# regenerar/pedir de nuevo un secreto que en realidad sí está guardado, o a
# reportar la API de Dokploy como "no configurada" cuando en realidad no se
# pudo ni preguntar. Se avisa por stderr y se falla igual (return 1): el
# valor de retorno no puede distinguir los dos casos sin romper a todos los
# llamadores existentes, pero el mensaje sí permite diagnosticarlo en los
# logs en vez de fallar en silencio.

priv_file_exists() {
  local f="$1"
  if ! sudo -n true 2>/dev/null; then
    echo "ERROR: no se pudo verificar $f (sudo -n no está disponible; ¿expiró la sesión de sudo cacheada por bootstrap.sh?). Se trata como 'no accesible', NUNCA como 'no existe'." >&2
    return 1
  fi
  # 'test'/'[' NO soporta '--' como fin-de-opciones (comprobado a mano:
  # "se esperaba un operador binario" — a diferencia de 'cat', que sí lo
  # soporta bien). $f siempre es una ruta absoluta propia (secret_file_path/
  # DOKPLOY_ENV_FILE), nunca algo influido desde afuera que pudiera
  # parecer un flag, así que omitir '--' acá es seguro.
  sudo -n test -f "$f" 2>/dev/null
}

# Contenido de un archivo root-only, vía 'sudo -n cat'. Vacío + return 1 si
# no existe o no se pudo leer (mismo fail-closed que priv_file_exists: nunca
# se distingue "vacío de verdad" de "no se pudo leer" con el valor de
# retorno solo, pero ningún llamador de este proyecto necesita esa
# distinción — todos tratan "sin contenido" como "no hay nada que usar").
priv_file_read() {
  local f="$1"
  priv_file_exists "$f" || return 1
  sudo -n cat -- "$f" 2>/dev/null
}

# Ruta del archivo de secretos del servicio $1 (ej. "vaultwarden" ->
# /etc/hli2/vaultwarden.env). No valida que exista.
secret_file_path() {
  printf '%s/%s.env' "$SECRETS_DIR" "$1"
}

# ¿Existe ya un archivo de secretos para el servicio $1?
secret_file_exists() {
  priv_file_exists "$(secret_file_path "$1")"
}

# Valor de la clave $2 dentro del archivo de secretos del servicio $1.
# Parseo seguro y explícito (NUNCA 'source' el archivo: un secreto
# corrupto/manipulado no debe poder ejecutar código) con 'case' en vez de
# una regex de 'sed' armada con la clave: comparación EXACTA de la clave al
# principio de cada línea ("${key}="), valor = todo lo que sigue al PRIMER
# '=' de esa línea (así un valor que a su vez contenga '=' queda intacto).
secret_get() {
  local service="$1" key="$2" f content line
  f="$(secret_file_path "$service")"
  content="$(priv_file_read "$f")" || return 1
  while IFS= read -r line; do
    case "$line" in
      "${key}="*)
        printf '%s' "${line#"${key}="}"
        return 0
        ;;
    esac
  done <<<"$content"
  return 1
}

# Guarda "CLAVE=valor" (uno o más pares, uno por línea, ya armados por el
# llamador en $2) en el archivo de secretos del servicio $1. Crea
# /etc/hli2 (si falta) y el archivo YA con el modo final 0600 antes de
# escribir. NUNCA imprime ni loguea el contenido.
#
# Valida la FORMA de cada línea ANTES de escribir nada (clave con forma de
# nombre de variable de entorno, seguida de '='): rechaza el contenido
# ENTERO si alguna línea no calza — así un valor que por accidente trajera
# un salto de línea embebido (rompiendo la invariante "una línea = un
# CLAVE=valor") se detecta como una línea extra sin forma válida, en vez de
# guardarse silenciosamente como si fuera una clave más.
# Arma una línea KEY='valor' para el campo "env" de Dokploy (que termina en
# el .env del compose). Docker Compose interpola '$var' en valores sin
# comillas o entre comillas dobles, pero NO dentro de comillas simples: un
# hash Argon2id ($argon2id$v=...) o una contraseña con '$' llegarían rotos
# sin ellas. Dentro de comillas simples no hay escape posible, así que un
# valor con comilla simple o salto de línea se rechaza (devuelve 1).
dotenv_single_quoted() {
  local key="$1"
  local val="$2"
  [[ "$val" != *"'"* && "$val" != *$'\n'* && "$val" != *$'\r'* ]] || return 1
  printf "%s='%s'" "$key" "$val"
}

secret_file_write() {
  local service="$1" content="$2" f line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      echo "ERROR: contenido de secreto con forma inválida para '$service' (línea sin forma CLAVE=valor). No se escribe nada." >&2
      return 1
    fi
  done <<<"$content"

  f="$(secret_file_path "$service")"
  sudo install -d -m 0700 -o root -g root "$SECRETS_DIR"
  sudo install -m 0600 -o root -g root /dev/null "$f"
  printf '%s\n' "$content" | sudo tee "$f" >/dev/null
}
