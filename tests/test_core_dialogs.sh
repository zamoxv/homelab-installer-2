#!/usr/bin/env bash
# Altura de input_box/password_box (lib/core.sh). El render real se validó con
# dialog en Ubuntu 24.04 (tmux): con altura 0 y un texto largo el campo se
# superponía a los botones y el texto se cortaba. El stub de dialog no dibuja,
# así que acá se verifica lo que se le pide: altura explícita suficiente.

# Altura (3er argumento posicional tras --inputbox/--passwordbox: texto, alto,
# ancho) de la última llamada a dialog con el widget $1.
_dlg_logged_height() {
  local widget="$1"
  grep -F $'\t'"$widget"$'\t' "$STUB_CALL_LOG" | tail -n1 | awk -F'\t' -v w="$widget" '{for(i=1;i<=NF;i++) if($i==w){print $(i+2); exit}}'
}

test_input_box_height_covers_text_field_and_buttons() {
  local prompt='Línea 1\n\nLínea 3\nLínea 4:' h
  echo "valor" > "$DIALOG_INPUTBOX_QUEUE"
  h="$( ( source "$REPO_ROOT/lib/core.sh"; v="$(input_box T "$prompt")"; echo "got:$v" ) 2>&1 )"
  assert_contains "$h" "got:valor" "el valor sigue capturándose" || return 1
  h="$(_dlg_logged_height --inputbox)"
  [[ "$h" =~ ^[0-9]+$ ]] || { fail "altura no numérica: [$h]"; return 1; }
  # 4 líneas de texto + 7 filas (bordes, campo de 3, separador, botones).
  (( h >= 11 )) || { fail "altura insuficiente para inputbox: $h (mínimo 11)"; return 1; }
}

test_password_box_height_covers_text_field_and_buttons() {
  local prompt='Línea 1\n\nLínea 3\nLínea 4:' h out
  echo "secreto" > "$DIALOG_PASSWORDBOX_QUEUE"
  out="$( ( source "$REPO_ROOT/lib/core.sh"; v="$(password_box T "$prompt")"; echo "got:$v" ) 2>&1 )"
  assert_contains "$out" "got:secreto" "el valor sigue capturándose" || return 1
  h="$(_dlg_logged_height --passwordbox)"
  [[ "$h" =~ ^[0-9]+$ ]] || { fail "altura no numérica: [$h]"; return 1; }
  (( h >= 11 )) || { fail "altura insuficiente para passwordbox: $h (mínimo 11)"; return 1; }
}

test_input_box_short_prompt_has_room_for_field() {
  local h
  echo "x" > "$DIALOG_INPUTBOX_QUEUE"
  ( source "$REPO_ROOT/lib/core.sh"; input_box T "Nombre:" >/dev/null )
  h="$(_dlg_logged_height --inputbox)"
  (( h >= 8 )) || { fail "altura insuficiente para un prompt de 1 línea: $h (mínimo 8)"; return 1; }
}
