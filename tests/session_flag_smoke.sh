#!/usr/bin/env bash
# A session can be given a colour, and that colour tints the sidebar HEADER pill
# (ticket 04). The durable half — session rows in the flag store and their
# restore after a server restart — lives in tests/flag_restore_smoke.sh, which
# owns the store; this file owns everything visible.
#
# One scratch server, two sessions, three windows, so the header assertions can
# say something the window-flag tests cannot: the colour follows the SESSION,
# reaching every one of its windows and none of another session's.
#
# Sections:
#   1  the picker menu is built from the shared palette, plus a clear entry,
#      with the current slot marked and unique shortcut keys
#   2  a colour tints the header pill of EVERY window in the session
#   3  another session's header is untouched
#   4  clearing returns the header to @sidetabs-header-bg
#   5  the header tint costs no extra tmux call (it rides READ_STATE_FMT)
#   6  reordering @sidetabs-flag-colors recolours an existing session colour,
#      and shrinking it past a stored index falls back to the default header
#   7  the key is bound with the sidebar gate + pass-through, honours the
#      `none` opt-out, and uninstall.sh unbinds it
#
# -f /dev/null is required on every tmux call: without it a new server on this
# socket still auto-loads the user's ~/.tmux.conf (which run-shells this plugin
# AND others), polluting hooks/keys and defeating test isolation.
set -euo pipefail

SOCKET="sidetab_sflag_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STORE="${TMPDIR:-/tmp}/sidetabs_sflag_store_$$.tsv"
PICKOUT="${TMPDIR:-/tmp}/sidetabs_sflag_pick_$$.out"

cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$STORE" "$PICKOUT" "${STORE}.lock" "${STORE}"*.tmp.* "${STORE}"*.live.*
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
sopt() { tmux -L "$SOCKET" show-option -t "$1" -qv "$2"; }
# No `exit` in these awks and no `head`: under `set -o pipefail` a reader that
# closes the pipe early can SIGPIPE tmux and fail the whole pipeline. A `seen`
# flag gives first-match-wins without ever closing the pipe.
sbpane() { tmux -L "$SOCKET" list-panes -t "$1" -F '#{pane_id} #{@is_sidetab}' \
            | awk '$2 == 1 && !seen { print $1; seen = 1 }'; }
appane() { tmux -L "$SOCKET" list-panes -t "$1" -F '#{pane_id} #{@is_sidetab}' \
            | awk '$2 != 1 && !seen { print $1; seen = 1 }'; }
# The header is line 0 of the sidebar. -e keeps the SGR escapes, which is the
# only place the colour is observable at all.
header() { tmux -L "$SOCKET" capture-pane -e -p -t "$1" | sed -n 1p; }

# Palette slot -> the SGR background sequence render.sh emits for it. Truecolor
# bg is "48;2;R;G;B"; these are the first four defaults plus the header default.
SGR_HDR='48;2;94;129;172'    # @sidetabs-header-bg #5e81ac
SGR_1='48;2;235;203;139'     # palette 1 #ebcb8b
SGR_2='48;2;163;190;140'     # palette 2 #a3be8c
SGR_4='48;2;180;142;173'     # palette 4 #b48ead

# --- setup -------------------------------------------------------------------
# summary off keeps the sidebar layout deterministic (no git/dir lines racing
# the header assertions); the store is hermetic so a run cannot touch the real
# ~/.local/share copy.
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -n alpha -x 200 -y 50
tmux -L "$SOCKET" set-option -g @sidetabs-summary off
tmux -L "$SOCKET" set-option -g @sidetabs-flag-store "$STORE"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.6
tmux -L "$SOCKET" new-window -t main -n beta
tmux -L "$SOCKET" new-session -d -s other -n omega
sleep 1.0

sb_a="$(sbpane main:alpha)"; sb_b="$(sbpane main:beta)"; sb_o="$(sbpane other:omega)"
[ -n "$sb_a" ] && [ -n "$sb_b" ] && [ -n "$sb_o" ] \
    || fail "setup: expected a sidebar in every window (alpha='$sb_a' beta='$sb_b' omega='$sb_o')"
# Every set/pick addresses a PANE, never a session id: run-shell hands its
# command string to `sh -c`, which expands a session id ("$0", "$1", …) as a
# positional parameter and destroys it. This is exactly what the key binding
# passes, so the tests exercise the real path.
p_main="$(appane main:alpha)"; p_other="$(appane other:omega)"
[ -n "$p_main" ] && [ -n "$p_other" ] || fail "setup: could not find a content pane per session"

# === 1. Picker menu construction ============================================
# --print is the only way to see a display-menu from a test: an overlay menu
# never lands in capture-pane output.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/session_flag_set.sh $p_main 4"
sleep 0.5
[ "$(sopt main @sidetabs_sflag)" = "4" ] || fail "setup: session colour not set"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/session_flag_picker.sh --print $p_main > $PICKOUT"
sleep 0.5
nitems="$(grep -c . "$PICKOUT" || true)"
[ "$nitems" = "9" ] || fail "session picker: expected 9 items (8 colours + clear), got $nitems"
# The SHARED palette, not a second one: item 1 must be @sidetabs-flag-colors[1].
head -1 "$PICKOUT" | grep -q '#ebcb8b' || fail "session picker item 1 is not the shared palette's first colour"
head -1 "$PICKOUT" | cut -f1 | grep -qx '1' || fail "session picker item 1 not on key 1"
awk -F'\t' '$2 == "4"' "$PICKOUT" | grep -q '(current)' \
    || fail "session picker did not mark the session's own slot as current"
if awk -F'\t' '$2 != "4"' "$PICKOUT" | grep -q '(current)'; then
    fail "session picker marked a non-current item as current"
fi
clearline="$(awk -F'\t' '$2 == "none"' "$PICKOUT")"
[ -n "$clearline" ] || fail "session picker has no clear item"
echo "$clearline" | cut -f1 | grep -qx '0' || fail "session clear item not on key 0"
nkeys="$(cut -f1 "$PICKOUT" | sort -u | grep -c . || true)"
[ "$nkeys" = "9" ] || fail "session picker shortcut keys not unique: $nkeys distinct of 9"
pass "session picker offers the shared palette plus a clear entry, current marked"

# === 2. The colour tints the header of EVERY window of the session ===========
sleep 1.0
ha="$(header "$sb_a")"; hb="$(header "$sb_b")"
echo "$ha" | grep -q "$SGR_4" || fail "alpha's header is not tinted with palette 4: $(printf '%s' "$ha" | cat -v)"
echo "$hb" | grep -q "$SGR_4" || fail "beta's header is not tinted — the colour did not reach every window"
if echo "$ha" | grep -q "$SGR_HDR"; then fail "alpha's header still carries @sidetabs-header-bg alongside the tint"; fi
pass "a session colour tints the header pill in every window of the session"

# The tint must be the HEADER only. A window row is coloured by @sidetabs_flag,
# which nothing here set, so no row may have picked the session colour up
# through tmux's option inheritance.
rows="$(tmux -L "$SOCKET" capture-pane -e -p -t "$sb_a" | sed -n '3,$p')"
if echo "$rows" | grep -q "$SGR_4"; then fail "the session colour leaked onto a window row"; fi
pass "the tint reaches the header pill only, never a window row"

# === 3. Another session is untouched ========================================
ho="$(header "$sb_o")"
echo "$ho" | grep -q "$SGR_HDR" || fail "the other session's header lost its default background"
if echo "$ho" | grep -q "$SGR_4"; then fail "the other session's header was tinted too"; fi
pass "a session colour does not reach another session's header"

# === 4. Clearing returns the header to the default ==========================
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/session_flag_set.sh $p_main none"
sleep 1.2
[ -z "$(sopt main @sidetabs_sflag)" ] || fail "clear left a live session colour"
ha="$(header "$sb_a")"
echo "$ha" | grep -q "$SGR_HDR" || fail "cleared header did not return to @sidetabs-header-bg: $(printf '%s' "$ha" | cat -v)"
if echo "$ha" | grep -q "$SGR_4"; then fail "cleared header still carries the palette colour"; fi
pass "clearing the colour returns the header to its default"

# === 5. The tint costs no extra tmux call ===================================
# Static, because it is a claim about the render loop's shape, not its output:
# the option must be interpolated into the batched READ_STATE_FMT that
# read_state already runs once per tick, and must NOT be fetched with a
# show-option of its own anywhere in the loop. A `get_session_option` or
# `show-option` naming @sidetabs_sflag in render.sh would be a per-tick fork in
# every sidebar on the server.
grep -q 'READ_STATE_FMT=.*SFLAG_OPTION' "$PLUGIN_DIR/scripts/render.sh" \
    || fail "render.sh does not read the session colour from the batched READ_STATE_FMT"
if grep -nE '@sidetabs_sflag|SFLAG_OPTION' "$PLUGIN_DIR/scripts/render.sh" \
    | grep -v 'READ_STATE_FMT' | grep -qE 'show-option|get_session_option|get_tmux_option'; then
    fail "render.sh fetches the session colour with a tmux call of its own"
fi
pass "the header tint rides the existing batched read — no extra tmux call"

# === 6. Palette order is API ================================================
# The option stores an INDEX, so reordering the list must recolour an existing
# session colour — the same contract window flags already have.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/session_flag_set.sh $p_main 1"
sleep 1.2
echo "$(header "$sb_a")" | grep -q "$SGR_1" || fail "palette slot 1 did not tint the header"
tmux -L "$SOCKET" set-option -g @sidetabs-flag-colors '#a3be8c #ebcb8b #81a1c1 #b48ead'
# render.sh builds its colour arrays once at startup, so the sidebars must be
# respawned for a palette change to take effect — the same as any theme option.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.5
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 1.5
sb_a="$(sbpane main:alpha)"
[ -n "$sb_a" ] || fail "sidebar not recreated after the palette change"
ha="$(header "$sb_a")"
echo "$ha" | grep -q "$SGR_2" \
    || fail "reordering the palette did not recolour the session: $(printf '%s' "$ha" | cat -v)"
pass "reordering @sidetabs-flag-colors recolours an existing session colour"

# Shrinking the palette past a stored index is not a crash and not a random
# colour: the header falls back to its default, exactly as a window flag whose
# index fell off the end stops painting.
tmux -L "$SOCKET" set-option -t main -q @sidetabs_sflag 8
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/refresh.sh force"
sleep 1.2
ha="$(header "$sb_a")"
echo "$ha" | grep -q "$SGR_HDR" \
    || fail "an out-of-palette session index did not fall back to the default header: $(printf '%s' "$ha" | cat -v)"
tmux -L "$SOCKET" set-option -t main -qu @sidetabs_sflag
tmux -L "$SOCKET" set-option -g @sidetabs-flag-colors '#ebcb8b #a3be8c #81a1c1 #b48ead #d08770 #8fbcbb #9d7cd8 #8b95a8'
pass "an index past the end of the palette falls back to the default header"

# === 7. The key binding =====================================================
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.8
keyline="$(tmux -L "$SOCKET" list-keys -T root 2>/dev/null | grep 'session_flag_picker.sh' || true)"
[ -n "$keyline" ] || fail "the session colour key is not bound on load"
echo "$keyline" | grep -q 'M-s' || fail "the session colour key is not bound to the M-s default: $keyline"
# The same shape as every other sidebar key: act only when the focused pane is
# a sidetab, otherwise hand the key straight back to the application.
echo "$keyline" | grep -q '@is_sidetab' || fail "the session key is not gated on #{@is_sidetab}: $keyline"
echo "$keyline" | grep -q 'send-keys' || fail "the session key has no pass-through arm: $keyline"
# A session id would be destroyed by run-shell's `sh -c` (it is spelled "$0"),
# so the binding must pass a PANE id and let the script resolve the session.
echo "$keyline" | grep -q 'pane_id' || fail "the session key does not pass #{pane_id}: $keyline"
if echo "$keyline" | grep -q 'session_id'; then fail "the session key passes #{session_id}, which sh will eat: $keyline"; fi
pass "M-s is bound with the sidebar gate, a pass-through arm and a pane-id target"

# uninstall must unbind it, the way it unbinds every other sidebar key.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.5
if tmux -L "$SOCKET" list-keys -T root 2>/dev/null | grep -q 'session_flag_picker.sh'; then
    fail "the session colour key survived uninstall"
fi
pass "uninstall.sh unbinds the session colour key"

# The `none` opt-out, the same escape hatch every other key option has. An empty
# string cannot disable a key: show-option cannot tell empty from unset, so the
# default would substitute.
tmux -L "$SOCKET" set-option -g @sidetabs-session-flag-key none
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.8
if tmux -L "$SOCKET" list-keys -T root 2>/dev/null | grep -q 'session_flag_picker.sh'; then
    fail "@sidetabs-session-flag-key none still bound the key"
fi
# The other sidebar keys must still be bound — `none` disables one key, not all.
tmux -L "$SOCKET" list-keys -T root 2>/dev/null | grep -q 'flag_picker.sh' \
    || fail "the none opt-out disabled an unrelated key"
pass "@sidetabs-session-flag-key none skips the binding and leaves the others alone"

echo "ALL SESSION FLAG TESTS PASSED"
