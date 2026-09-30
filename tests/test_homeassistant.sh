#!/usr/bin/env bash
# Test end-to-end de modules/homeassistant.sh: sin secretos ni dominio, solo
# confirma que el compose se renderiza y despliega vía la API de Dokploy con
# network_mode host, y que el módulo queda marcado como hecho.

test_homeassistant_deploy_ok() {
  harness_mark_canary_done

  bash "$REPO_ROOT/modules/homeassistant.sh" || return 1

  assert_file_contains "$STATE_FILE" "homeassistant" "mark_done homeassistant" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "network_mode: host" "compose usa red del host" || return 1
  assert_file_contains "$STUB_HTTP_BODIES_LOG" "ghcr.io/home-assistant/home-assistant:stable" "imagen oficial" || return 1

  # Nota: no se verifica la ausencia de "privileged" en el body acá porque
  # el propio compose la MENCIONA en un comentario (para explicar por qué
  # no se usa) — el JSON-escapado del compose mezcla comentario y directiva
  # en una sola línea lógica, así que un grep de texto no distingue de forma
  # confiable "está comentado" de "es una directiva real". La ausencia real
  # de 'privileged:' como clave del compose se verifica por revisión directa
  # de compose/homeassistant/docker-compose.yml.

  # No hay secretos en este módulo: no debería haber llamado a
  # 'docker run ... hash' en absoluto.
  if grep -qF $'\thash' "$STUB_CALL_LOG" 2>/dev/null; then
    fail "homeassistant no debería invocar ningún generador de hash"
    return 1
  fi
}
