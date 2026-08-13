#!/usr/bin/env bash
# "Register repo for <label>…" passthrough (C7): tells the aguilabs CLI that
# this window's content-pane cwd belongs to the window's tagged customer.
# Shelled out to and run in the BACKGROUND from timer.sh's menu (run-shell -b)
# since it invokes an external CLI and must never block the UI. Reports its
# outcome via display-message — there's no other feedback channel from a
# backgrounded run-shell.
# Usage: register_repo.sh <window_id>
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

WID="${1:-}"
[ -z "$WID" ] && exit 0
TAB="$(printf '\t')"

tag="$(get_window_option "$WID" "$TIMER_TAG_OPTION" "")"
if [ -z "$tag" ] || [ "$tag" = "-" ]; then
    tmux display-message "sidetabs: window has no assigned client"
    exit 0
fi
# C2: split on the first ':' — the part before it is always the customer id,
# whether the tag is customer-only or customer:project.
customer="${tag%%:*}"

if ! command -v aguilabs >/dev/null 2>&1; then
    tmux display-message "sidetabs: aguilabs CLI not found on PATH"
    exit 0
fi

# Active-content-pane cwd: same idiom as timer.sh log_event (:63-65) — never
# the bare active pane, which may BE the sidetab strip (its cwd is the
# plugin's own directory, not the work this window is tracking).
cwd="$(tmux list-panes -t "$WID" \
    -F "#{pane_active}${TAB}#{@is_sidetab}${TAB}#{pane_current_path}" 2>/dev/null \
    | awk -F"$TAB" '$2 != "1"' | sort -r | cut -d"$TAB" -f3 | head -1)"
if [ -z "$cwd" ]; then
    tmux display-message "sidetabs: could not resolve a content-pane cwd"
    exit 0
fi

if out="$(aguilabs usage configure --customer "$customer" --add-repo "$cwd" 2>&1)"; then
    tmux display-message "sidetabs: registered $cwd for $customer"
else
    tmux display-message "sidetabs: aguilabs usage configure failed: $(printf '%s' "$out" | head -1)"
fi
