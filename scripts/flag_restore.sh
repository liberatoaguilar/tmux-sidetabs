#!/usr/bin/env bash
# Re-seed flag colours after a tmux server restart — both the per-WINDOW flag
# (@sidetabs_flag) and the per-SESSION colour (@sidetabs_sflag). The live state
# dies with the server — tmux does not save user options and neither does
# tmux-resurrect — so the TSV written by flag_store.sh is the durable record.
# Replay it onto the live windows and sessions.
#
# Matching is by session + window NAME for a window flag, and by session NAME
# alone for a session colour: ids do not survive a restart. First window with a
# given name wins, a window whose name has changed since the flag was set simply
# does not match, and a row naming a window that no longer exists is never
# applied at all (the loop walks LIVE entities and looks each one up, rather than
# walking the store and hunting for a target).
#
# Anything that ALREADY carries a colour is never touched. Whatever is live now
# was either set by the user this generation or seeded by an earlier run, and in
# both cases it is fresher than the store.
#
# The two row shapes are told apart by the middle field, and each pass ignores
# the other's rows: a session row applied to a window (or vice versa) would paint
# the wrong thing entirely. They share this file so the two states need only one
# lock and one restore pass.
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
# BOTH paths hold @sidetabs_flag_restoring for the duration of the replay, and
# flag_store.sh stands down while it is set. Without it a window-renamed or
# session-renamed sync landing mid-replay would snapshot every not-yet-seeded
# entity as legitimately unflagged and DELETE the rows this script was about to
# read — permanent loss of the durable record, on the path where nothing else
# guards it (the resurrect path is additionally covered by @sidetabs_restoring;
# `boot` runs on a live server where nothing raises that at all). See
# variables.sh for why it is a flag of its own rather than @sidetabs_restoring.
# It is released from a trap so no failure path can leak it.
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
# Test hook: SIDETABS_FLAG_RESTORE_TEST_DELAY_S holds the replay open for N
# seconds after the write-through guard goes up, so a test can land a
# flag_store.sh sync squarely inside the window this script exists to protect —
# a race that is otherwise milliseconds wide and cannot be asserted on. Same
# convention as the boot-age override above: integer or ignored, and passed
# inline on the run-shell command string, since run-shell does not inherit a
# test shell's exports.
TEST_DELAY_S="${SIDETABS_FLAG_RESTORE_TEST_DELAY_S:-0}"
case "$TEST_DELAY_S" in ''|*[!0-9]*) TEST_DELAY_S=0 ;; esac

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

# --- write-through guard -----------------------------------------------------
# Everything from here on is the replay, and while it runs the live state is a
# half-truth: the entities exist but their colours have not landed yet. A
# flag_store.sh sync in that window would snapshot them as unflagged and delete
# their rows, so the store is frozen for the duration.
#
# The trap comes FIRST, and covers the signals as well as EXIT: bash runs an
# EXIT trap on a fatal signal only when that signal is trapped too, and a guard
# that leaks stays "1" for the rest of the server's life — silently disabling
# every write-through, so every flag set afterwards would be lost at the next
# restart. Releasing it too often is harmless (a second release is a no-op);
# releasing it never is the failure mode that matters.
release_flag_guard() { set_tmux_option "$FLAG_RESTORING_OPTION" "0" 2>/dev/null || true; }
trap release_flag_guard EXIT INT TERM HUP
set_tmux_option "$FLAG_RESTORING_OPTION" "1"
# Test seam only; 0 in every real run, so this is a no-op outside the tests.
# Spelled as an `if` and not `[ … ] && sleep …`: under `set -e` a trailing &&
# list that evaluates false is a non-zero statement and would abort the script.
if [ "$TEST_DELAY_S" -gt 0 ]; then sleep "$TEST_DELAY_S"; fi

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

changed=0

# restore_pass <window|session>: walk the LIVE entities of one scope on stdin
# and replay each one's stored row. ONE function for both passes, because the
# two differ in only three places — what a key is made of, which row shape the
# lookup matches, and which option is written — while everything that is easy to
# get wrong (the palette bounds, first-match-wins, the never-clobber rule, the
# ENVIRON lookup) is identical and is therefore written once.
#
# Input is the same field order and the same "f" prefix flag_store.sh writes
# with; see the comment on flag_store_write_live for why the flag leads and the
# name trails (IFS=TAB collapses empty fields, and a window name may hold a tab).
restore_pass() {
    local mode="$1" applied="$US" fval id sname wname key idx
    while IFS="$TAB" read -r fval id sname wname; do
        if [ "$mode" = "session" ]; then
            # list-sessions emits THREE fields, so a tab inside the session name
            # spills into the fourth read variable. Glue it back on before the
            # squash below: flag_store.sh squashes the same name the same way
            # when it writes the row, and the two have to agree or the row never
            # matches itself. A session row's window field is empty by
            # definition, which is also what confines the lookup to session rows.
            if [ -n "$wname" ]; then sname="${sname}${TAB}${wname}"; fi
            wname=""
        fi
        [ -n "$id" ] || continue
        # An entity with no representable key is never RECORDED either (see
        # flag_store_write_live), so it can have no row to look up.
        [ -n "$sname" ] || continue
        sname="${sname//$TAB/ }"
        if [ "$mode" = "window" ]; then
            [ -n "$wname" ] || continue
            wname="${wname//$TAB/ }"
        fi
        key="${sname}${US}${wname}"
        case "$applied" in *"${US}${key}${US}"*) continue ;; esac
        # Names go in through ENVIRON, not -v: awk expands backslash escapes in
        # a -v value, so a name holding a literal \t or \\ would never match
        # itself. (note.sh and timer_restore.sh still carry that wart; new code
        # does not inherit it.) The store is read as a FILE, so awk's early
        # `exit` cannot SIGPIPE a writer the way it can on a piped input.
        #
        # `$2 == ENVIRON["w"]` is what keeps each pass inside its own row shape,
        # in one expression rather than two: `w` is the window name in the
        # window pass, so a session row (window field empty) can never match it;
        # `w` is EMPTY in the session pass, so only a session row can.
        idx="$(s="$sname" w="$wname" awk -F"$TAB" \
            '$1 == ENVIRON["s"] && $2 == ENVIRON["w"] { print $3; exit }' \
            "$STORE" 2>/dev/null || true)"
        [ -n "$idx" ] || continue
        case "$idx" in *[!0-9]*) continue ;; esac
        { [ "$idx" -ge 1 ] && [ "$idx" -le "$nc" ]; } || continue
        # Marked applied BEFORE the live check, so a second window with the same
        # name does not get seeded from the row the first one already owns.
        # (Session names are unique within a server, so there is no first-wins
        # question there; the bookkeeping is kept anyway, so a duplicate row in a
        # hand-edited store cannot be applied twice.)
        applied="${applied}${key}${US}"
        # Live value wins: whatever is set now was either set by the user this
        # generation or seeded by an earlier run, and is fresher than the store.
        if [ -z "${fval#f}" ]; then
            if [ "$mode" = "window" ]; then
                set_window_option "$id" "$FLAG_OPTION" "$idx"
            else
                set_session_option "$id" "$SFLAG_OPTION" "$idx"
            fi
            changed=1
        fi
    done
}

restore_pass window <<< "$(tmux list-windows -a \
    -F "f#{$FLAG_OPTION}${TAB}#{window_id}${TAB}#{session_name}${TAB}#{window_name}" 2>/dev/null)"

# The session pass is deliberately NOT gated on `changed`: a store holding only
# session rows must still restore, and a window pass that found nothing says
# nothing at all about the sessions.
restore_pass session <<< "$(tmux list-sessions \
    -F "f#{$SFLAG_OPTION}${TAB}#{session_id}${TAB}#{session_name}" 2>/dev/null)"

if [ "$changed" = "1" ]; then
    "$CURRENT_DIR/refresh.sh" force
    # The session strip renders session colours, so a re-seed changes it too.
    # `force`, and NOT left to the client-attached strip hook: that hook and
    # this script's own boot hook are both `run-shell -b`, so the strip can
    # easily regenerate BEFORE the colours land and would then show the
    # pre-restore state until the next unrelated event. No-op while the strip
    # is off; `|| true` so a strip failure never makes a restore look failed.
    "$CURRENT_DIR/strip.sh" force || true
fi
