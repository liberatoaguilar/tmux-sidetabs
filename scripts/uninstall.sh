#!/usr/bin/env bash
# Kill every sidetab pane, unset hooks, unbind keys.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

# Unhook everything FIRST — otherwise killing a sidetab pane fires
# window-layout-changed and the resurrection hook recreates it.
for hook in after-new-window after-new-session window-renamed \
            session-window-changed window-linked window-unlinked \
            pane-focus-in alert-activity window-layout-changed window-resized; do
    tmux set-hook -gu "$hook" 2>/dev/null || true
done

# Now kill all sidetab panes.
tmux list-panes -a -F '#{pane_id} #{@is_sidetab}' 2>/dev/null \
    | awk '$2 == "1" { print $1 }' \
    | while read -r pid; do
        tmux kill-pane -t "$pid" 2>/dev/null || true
      done

# Unbind the toggle (and optional uninstall) key.
toggle_key="$(get_tmux_option "@sidetabs-toggle-key" "$DEFAULT_TOGGLE_KEY")"
tmux unbind-key "$toggle_key" 2>/dev/null || true

uninstall_key="$(get_tmux_option "@sidetabs-uninstall-key" "")"
[ -n "$uninstall_key" ] && tmux unbind-key "$uninstall_key" 2>/dev/null || true

# Unbind the navigation + window-management overrides (C-h is left to the user's).
for k in 'C-j' 'C-k' 'C-n' 'C-r' 'C-x' 'M-j' 'M-k'; do
    tmux unbind-key -n "$k" 2>/dev/null || true
done

tmux display-message "tmux-sidetabs uninstalled. Reload ~/.tmux.conf to restore C-j/C-k."
