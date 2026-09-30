#!/usr/bin/env bash
# Tests unitarios de lib/dokploy_api.sh, enfocados en la fuga de secretos
# que se encontró y corrigió al sumar el campo "env" (v2.3): ni el body de
# dokploy_api_call ni el 'env_content' de dokploy_compose_create_or_update
# deben pasar NUNCA por el argv de un proceso real (curl/jq) — ver el
# comentario de dokploy_api_call en lib/dokploy_api.sh para el detalle de
# por qué (y por qué NO se usa 'trap ... RETURN' para la limpieza).

test_dokploy_api_call_body_never_in_argv() {
  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    out="$(dokploy_api_call POST "project.create" '{"name":"secreto-de-prueba-9f8e7d"}')"
    [[ -n "$out" ]] || { echo "no hubo respuesta"; exit 1; }
  ) || return 1

  assert_file_not_contains "$STUB_CALL_LOG" "secreto-de-prueba-9f8e7d" \
    "el body nunca debe estar en el argv de curl" || return 1
  # Sí debe haber pasado por el body real que curl leyó del archivo.
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "secreto-de-prueba-9f8e7d" \
    "el body sí debe llegar al contenido real enviado" || return 1
}

test_dokploy_compose_env_never_in_jq_argv() {
  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    compose_file="$(mktemp)"
    echo "services: {}" > "$compose_file"
    dokploy_compose_create_or_update "env-1" "demo-app" "$compose_file" "ADMIN_TOKEN=marca-de-agua-abc123" >/dev/null
    rm -f "$compose_file"
  ) || return 1

  assert_file_not_contains "$STUB_CALL_LOG" "marca-de-agua-abc123" \
    "el secreto de 'env' nunca debe estar en el argv de jq (debe ir por --rawfile, no --arg)" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "marca-de-agua-abc123" \
    "el secreto sí debe llegar al body real enviado a Dokploy" || return 1
}

# dokploy_compose_create_or_update SIN 'env' (los tres servicios de v2.2:
# jellyfin/qbittorrent/adguard) no debe romper ni mandar un campo "env"
# vacío/basura — comportamiento previo intacto.
test_dokploy_compose_without_env_unchanged() {
  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    compose_file="$(mktemp)"
    echo "services: {}" > "$compose_file"
    dokploy_compose_create_or_update "env-1" "jellyfin" "$compose_file" >/dev/null
    rm -f "$compose_file"
  ) || return 1

  assert_file_not_contains "$STUB_HTTP_BODIES_LOG" '"env"' \
    "sin env_content no debe mandarse el campo env" || return 1
}

# CRÍTICO 1 (ronda 2 de revisión), mismo bug que en lib/secrets.sh pero acá
# para $DOKPLOY_ENV_FILE: en producción vive bajo /etc/hli2 (0700 root:root),
# así que un '[[ -f ]]'/'sed' SIN privilegios (como tenía la versión
# anterior de dokploy_api_configured()/_dokploy_env_get) fallaba SIEMPRE,
# aunque el archivo existiera — "credenciales ya configuradas" nunca se
# detectaba, y cada llamada a la API habría vuelto a pedir el token por TUI.
# El harness deja $DOKPLOY_ENV_FILE bajo un directorio root-only simulado
# (STUB_ROOT_AREA, modo 000); este test prueba que un acceso plano falla y
# que dokploy_api_configured()/_dokploy_env_get (que usan 'sudo -n' por
# dentro) sí funcionan.
test_dokploy_env_file_unreadable_plain_but_configured_detects_it() {
  # (a) Acceso plano: debe fallar (permiso denegado al atravesar el
  # directorio root-only simulado).
  if [[ -f "$DOKPLOY_ENV_FILE" ]]; then
    fail "el harness no está simulando /etc/hli2 root-only para DOKPLOY_ENV_FILE"
    return 1
  fi

  # (b) Vía las funciones reales (usan 'sudo -n' por dentro): deben
  # funcionar y devolver los valores correctos.
  ( set -euo pipefail
    source "$REPO_ROOT/lib/core.sh"
    dokploy_api_configured || { echo "dokploy_api_configured debería detectar las credenciales vía sudo"; exit 1; }
    url="$(_dokploy_env_get DOKPLOY_URL)"
    [[ "$url" == "http://test-dokploy:3000" ]] || { echo "URL leída no coincide: [$url]"; exit 1; }
  ) || return 1
}
