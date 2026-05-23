#!/usr/bin/env bash

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

source "$SCRIPTS_DIR/variables.sh"
source "$SCRIPTS_DIR/helpers.sh"

initial_setup() {
    tmux list-windows -a -F '#{session_id} #{window_id}' 2>/dev/null \
        | while read -r sid wid; do
            "$SCRIPTS_DIR/create_sidebar.sh" "$sid" "$wid"
          done
}

main() {
    initial_setup
}
main
