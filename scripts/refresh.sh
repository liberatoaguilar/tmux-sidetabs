#!/usr/bin/env bash
# Nudge every sidetab render process to redraw immediately. Called from tmux
# hooks. The viewed sidebar would catch changes on its 0.5s tick anyway; HIDDEN
# sidebars rebuild ONLY on this signal (plus a slow self-heal tick), so for
# them this is the sole freshness path.
#
# Argument: the literal word "force" skips the debounce. Visibility-transition
# hooks (window switch, attach, link/unlink) MUST use it: hidden sidebars only
# rebuild on this signal, so a swallowed wake there would leave a stale sidebar
# on screen until its slow self-heal tick. A fixed literal is safe to pass —
# only dynamic values are off-limits:
#   - tmux session ids are formatted "$N" ($0, $1, …). Passing #{session_id}
#     through `run-shell -> sh -c` makes sh expand "$2" as a positional param
#     (empty), so any passed id is unreliable. We sidestep it by signalling
#     every sidetab render PID; each render self-determines its own session.
#   - If this script returned non-zero, tmux would surface the hook failure by
#     dropping the pane into view-mode (the "[0/0]" overlay). So we swallow
#     every error and end with `exit 0`.

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

# Global debounce (per tmux server) to avoid signal storms on rapid cosmetic
# events (renames, activity, focus churn). Forced refreshes always signal, and
# still stamp so trailing cosmetic events coalesce into them.
now="$(now_ms)"
if [ "${1:-}" != "force" ]; then
    last="$(get_tmux_option "$LAST_REFRESH_OPTION" "0")"
    if [ "$((now - last))" -lt "$REFRESH_DEBOUNCE_MS" ]; then
        exit 0
    fi
fi
set_tmux_option "$LAST_REFRESH_OPTION" "$now"

tmux list-panes -a -F '#{pane_id} #{@is_sidetab}' 2>/dev/null \
    | awk '$2 == "1" { print $1 }' \
    | while read -r pane; do
        pid="$(get_pane_option "$pane" "$RENDER_PID_OPTION" "")"
        [ -n "$pid" ] && kill -USR1 "$pid" 2>/dev/null
      done

exit 0
