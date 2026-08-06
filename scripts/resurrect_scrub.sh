#!/usr/bin/env bash
# tmux-resurrect @resurrect-hook-post-save-all
#
# Scrub sidebar strips out of the save file's restore-relevant fields. Two
# problems if we don't: (1) the strip is pane index 0 of every window and
# resurrect builds each window with `new_session/new_window -c <first pane's
# cwd>` — so every restored window's base shell opens in the PLUGIN dir; (2)
# sidebar navigation keeps the sidebar pane active, so resurrect records the
# strip as most windows' active pane and restores land focus in a dead strip.
#
# Rewrite, for each strip pane line: cwd <- the window's first content pane's
# cwd (fallback $HOME), and if the strip was the active pane, move the flag to
# that content pane. Pane counts and the layout string are untouched, so
# resurrect_post.sh's geometry-based adoption still works.
#
# Usage: resurrect_scrub.sh [savefile]
#   No argument (hook mode): resolves @resurrect-dir (else resurrect's default
#   locations) and scrubs the target of the `last` symlink.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/helpers.sh"
PLUGIN_ROOT="$( cd "$CURRENT_DIR/.." && pwd )"

resurrect_dir() {
    local d
    d="$(get_tmux_option '@resurrect-dir' '')"
    if [ -n "$d" ]; then printf '%s' "${d/#\~/$HOME}"; return; fi
    # Mirror resurrect's own fallback order: legacy dir if present, else XDG.
    if [ -d "$HOME/.tmux/resurrect" ]; then printf '%s' "$HOME/.tmux/resurrect"; return; fi
    printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
}

FILE="${1:-}"
if [ -z "$FILE" ]; then
    dir="$(resurrect_dir)"
    FILE="$dir/last"
    if [ -L "$FILE" ]; then
        tgt="$(readlink "$FILE")"
        case "$tgt" in /*) FILE="$tgt" ;; *) FILE="$dir/$tgt" ;; esac
    fi
fi
[ -f "$FILE" ] || exit 0

# A strip line is: a pane line, pane index 0, cwd = the plugin root (strips
# created before create_sidebar passed -c) or $HOME (after), whose full command
# is the render loop or its sleep tick. The full-command check is what excludes
# a real user shell parked at ~ or in the plugin dir (its full command is the
# shell itself, not sleep/render). Two passes: collect each window's first
# content pane cwd + active flag, then rewrite. Field 8 (:cwd) keeps its colon.
TMP="${FILE}.scrub.$$"
awk -F'\t' -v OFS='\t' -v pdir=":$PLUGIN_ROOT" -v home=":$HOME" '
    function is_strip() {
        return $1 == "pane" && $6 == "0" && ($8 == pdir || $8 == home) \
               && ($10 == "bash" || $10 == "sleep") \
               && $11 ~ /sleep|render\.sh/
    }
    NR == FNR {
        if ($1 == "pane" && !is_strip()) {
            k = $2 SUBSEP $3
            if (!(k in cwd)) { cwd[k] = $8; first[k] = $6 }
            if ($9 == "1") hasact[k] = 1
        }
        next
    }
    {
        if (is_strip()) {
            k = $2 SUBSEP $3
            $8 = (k in cwd) ? cwd[k] : home
            if ($9 == "1") { $9 = "0"; moved[k] = 1 }
        } else if ($1 == "pane") {
            k = $2 SUBSEP $3
            if (moved[k] && !hasact[k] && $6 == first[k]) { $9 = "1"; moved[k] = 0 }
        }
        print
    }
' "$FILE" "$FILE" > "$TMP" && mv "$TMP" "$FILE"
rm -f "$TMP" 2>/dev/null || true
