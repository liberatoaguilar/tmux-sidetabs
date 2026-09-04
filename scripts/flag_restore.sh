#!/usr/bin/env bash
# Re-seed per-window flag colours after a tmux server restart. The live state
# (the @sidetabs_flag window option) dies with the server — tmux does not save
# user options and neither does tmux-resurrect — so the TSV written by
# flag_store.sh is the durable record. Replay it onto the live windows.
#
# Matching is by session + window NAME: window ids do not survive a restart.
# First window with a given name wins, a window whose name has changed since the
# flag was set simply does not match, and a row naming a window that no longer
# exists is never applied at all (the loop walks LIVE windows and looks each one
# up, rather than walking the store and hunting for a target).
#
# A window that ALREADY has a flag is never touched. Whatever is live now was
# either set by the user this generation or seeded by an earlier run, and in
# both cases it is fresher than the store.
#
# Rows in the reserved SESSION shape (empty middle field) are skipped: they are
# a session colour, not a window flag, and applying one to a window would paint
# the wrong thing. They share this file so the two states need only one lock and
# one restore pass.
#
# Two delivery paths, deliberately not symmetric — the same split timer_restore
# uses, for the same reason:
#   (default)  resurrect_post.sh, after a tmux-resurrect restore. Always runs,
#              is safe to run by hand at any time (seeding is blank-slate-only
#              and idempotent), and claims the generation on the way in.
#   boot       the client-attached fallback registered by sidetabs.tmux, for the
#              case where tmux-continuum skips auto-restore entirely (it does
#              that whenever another tmux server was running at startup, or the
#              server is older than @continuum-restore-max-delay) so the
#              resurrect hook never fires at all. This mode runs only while the
#              server is YOUNG (< BOOT_MAX_AGE_S) and only once per server
#              generation: firing on a later attach would let a window created
#              hours afterwards, whose name happens to match an old row, be
#              painted with a colour the user never gave it.
# The claim is one-directional on purpose: `boot` stands down once anything has
# restored this generation, but a resurrect restore never stands down for
# `boot` — losing that race (a client attaching before continuum restores) would
# leave every flag unseeded, and re-seeding an already-seeded window is a no-op.
#
# Disable both with:  set -g @sidetabs-flag-restore off
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"

MODE="${1:-}"
# Test hook: SIDETABS_FLAG_BOOT_MAX_AGE_S overrides the boot window in seconds
# (a non-integer is ignored). Documented here per the search.sh:7-8 convention —
# run-shell does not inherit a test shell's exports, so tests pass it inline on
# the run-shell command string.
BOOT_MAX_AGE_S="${SIDETABS_FLAG_BOOT_MAX_AGE_S:-120}"
case "$BOOT_MAX_AGE_S" in ''|*[!0-9]*) BOOT_MAX_AGE_S=120 ;; esac

[ "$(get_tmux_option '@sidetabs-flag-restore' "$DEFAULT_FLAG_RESTORE")" = "on" ] || exit 0

if [ "$MODE" = "boot" ]; then
    [ "$(get_tmux_option "$FLAG_RESTORED_OPTION" '0')" = "1" ] && exit 0
    # A restore in flight owns this generation; the post hook will claim it.
    [ "$(get_tmux_option "$RESTORING_OPTION" '0')" = "1" ] && exit 0
    # #{start_time} is raw epoch seconds. Fail CLOSED: an unreadable or nonsense
    # server age means we cannot prove we are inside the boot window, and
    # painting a window the user never flagged is worse than painting nothing.
    started="$(tmux display-message -p '#{start_time}' 2>/dev/null || true)"
    case "$started" in ''|*[!0-9]*) exit 0 ;; esac
    [ "$(( $(date +%s) - started ))" -lt "$BOOT_MAX_AGE_S" ] || exit 0
fi
set_tmux_option "$FLAG_RESTORED_OPTION" "1"

STORE="$(get_tmux_option '@sidetabs-flag-store' "$DEFAULT_FLAG_STORE")"
[ -f "$STORE" ] || exit 0

TAB="$(printf '\t')"
US=$'\x1f'   # never appears in a store row that flag_store.sh wrote

# The palette bounds what a stored index may mean. A row outside it is dropped
# rather than applied: render.sh indexes its colour arrays directly, so an index
# past the end paints nothing while still counting as "flagged" everywhere else
# (precedence, the strip, the picker's starting point). Shrinking
# @sidetabs-flag-colors is therefore a deliberate un-flagging of the slots that
# fell off the end, exactly as flag_cycle.sh already treats it.
colors="$(get_tmux_option '@sidetabs-flag-colors' "$DEFAULT_FLAG_COLORS")"
set -- $colors
nc=$#
[ "$nc" -eq 0 ] && exit 0

applied="$US"    # keys already handled — first window with a given name wins
changed=0
# Same field order and the same "f" prefix as flag_store.sh writes with; see the
# comment on flag_store_write_live for why the flag leads and the window name
# trails (IFS=TAB collapses empty fields, and a window name may hold a tab).
while IFS="$TAB" read -r fval wid sname wname; do
    [ -n "$wid" ] || continue
    [ -n "$wname" ] || continue   # unrepresentable key; never recorded either
    sname="${sname//$TAB/ }"; wname="${wname//$TAB/ }"
    key="${sname}${US}${wname}"
    case "$applied" in *"${US}${key}${US}"*) continue ;; esac
    # Names go in through ENVIRON, not -v: awk expands backslash escapes in a
    # -v value, so a window named with a literal \t or \\ would never match
    # itself. (note.sh and timer_restore.sh still carry that wart; new code
    # does not inherit it.) The store is read as a FILE, so awk's early `exit`
    # cannot SIGPIPE a writer the way it can on a piped input.
    idx="$(s="$sname" w="$wname" awk -F"$TAB" \
        '$2 != "" && $1 == ENVIRON["s"] && $2 == ENVIRON["w"] { print $3; exit }' \
        "$STORE" 2>/dev/null || true)"
    [ -n "$idx" ] || continue
    case "$idx" in *[!0-9]*) continue ;; esac
    { [ "$idx" -ge 1 ] && [ "$idx" -le "$nc" ]; } || continue
    applied="${applied}${key}${US}"
    # Live flag wins. Marked applied first, so a SECOND window with the same
    # name does not get seeded from the row the first one already owns.
    [ -n "${fval#f}" ] && continue
    set_window_option "$wid" "$FLAG_OPTION" "$idx"
    changed=1
done <<< "$(tmux list-windows -a \
    -F "f#{$FLAG_OPTION}${TAB}#{window_id}${TAB}#{session_name}${TAB}#{window_name}" 2>/dev/null)"

if [ "$changed" = "1" ]; then
    "$CURRENT_DIR/refresh.sh" force
fi
