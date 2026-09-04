#!/usr/bin/env bash
# Smoke test for the plugin-owned bottom session strip (scripts/strip.sh).
#
# The strip GENERATES a literal status-left per session, so every assertion here
# reads the generated string straight out of `show-option -t <session> -v
# status-left`. That needs no attached client at all, which is what makes the
# per-session, per-client behaviour testable in the first place: "which pill is
# the current one" is baked into each session's own string at generation time,
# so it can be checked by comparing two sessions' strings rather than by
# attaching two terminals and squinting at them.
#
# Sections:
#   1  off by default — the plugin does not touch the status line at all
#   2  one pill per session in stable CREATION order (not name order)
#   3  each session's string highlights ITSELF, and no other string does
#   4  every separator is the solid arrow; the thin bar is never drawn
#   5  a same-background join uses the contrast ink; a differing one does not
#   6  a session colour beats "current", and only then is the marker drawn
#   7  agent attention beats a session colour, and clearing it restores the pill
#   8  a bell beats a session colour, and the alert-bell hook delivers it
#   9  no #{S:}, no @strip_next, no per-client conditional survives into output
#  10  emitted hex is lowercase even when the palette is not
#  11  the hooks are registered BY THE PLUGIN (so they survive a restart) and
#      really do regenerate on create / rename / close; a rename also re-files
#      the session's stored colour under its new name
#  12  a burst is debounced, and `force` bypasses the debounce
#  13  a session name full of tmux metacharacters round-trips intact
#  14  switching the strip off leaves the last strip alone (no clear)
#  15  uninstall stops the regeneration
#
# -f /dev/null is on EVERY tmux call, not just the first: without it a new
# server on this socket auto-loads the user's ~/.tmux.conf, which run-shells
# this plugin (and others) and would defeat the isolation entirely. The socket
# is scratch and per-PID, so nothing here can reach the user's real server.
#
# Note the assertion style: `if has X "$v"; then fail ...; fi` rather than
# `has X "$v" && fail ...`. Under `set -e` the second form exits the script the
# moment the check PASSES, because the whole && list then returns non-zero.
set -euo pipefail

SOCKET="sidetab_strip_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STORE="${TMPDIR:-/tmp}/sidetabs_strip_store_$$.tsv"

cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$STORE" "${STORE}.lock" "${STORE}"*.tmp.* "${STORE}"*.live.*
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

TAB="$(printf '\t')"
ARROW="$(printf '\xee\x82\xb0')"   # U+E0B0, the solid arrow — the only separator
THIN="$(printf '\xee\x82\xb1')"    # U+E0B1, the thin bar — must never appear
MARKER="$(printf '\xe2\x96\x8e')"  # U+258E, the current-session marker

tm() { tmux -L "$SOCKET" -f /dev/null "$@"; }
# The generated string for one session. -qv so an UNSET option is an empty
# string rather than an error — section 1 depends on telling those apart.
sl() { tm show-option -t "$1" -qv status-left; }
sll() { tm show-option -t "$1" -qv status-left-length; }
# run-shell WITHOUT -b: it blocks until the script finishes, so an assertion on
# the next line is reading the finished result, not racing it.
strip() { tm run-shell "$PLUGIN_DIR/scripts/strip.sh ${1:-}"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
# Pill text only: drop every #[...] style and turn each separator into "|", so
# an order assertion reads like the strip looks.
pills() { sl "$1" | sed "s/#\[[^]]*\]//g; s/${ARROW}/|/g"; }
# First non-sidetab pane of a window/session — every script that takes a
# "target" is handed a PANE id, because run-shell feeds its command string to
# `sh -c` and a session id ("$0", "$1", …) would be eaten as a positional
# parameter. No `exit` in the awk: under pipefail an early close can SIGPIPE
# tmux and fail the whole pipeline.
appane() { tm list-panes -t "$1" -F '#{pane_id} #{@is_sidetab}' \
            | awk '$2 != 1 && !seen { print $1; seen = 1 }'; }

# Exact style prefixes the defaults produce. Asserting on whole substrings
# (style + text) rather than on fragments keeps every check unambiguous.
IDLE='#[fg=white,bg=brightblack,nobold]'
CUR='#[fg=black,bg=blue,bold]'
GREEN='#[fg=#2e3440,bg=#a3be8c,bold]'    # palette slot 2, @sidetabs-flag-fg
BELLP='#[fg=#eceff4,bg=#bf616a,bold]'

# === setup ==================================================================
# Session names are chosen so NAME order (alpha, mid, zulu) is the exact
# reverse of CREATION order (zulu, mid, alpha). `list-sessions` sorts by name,
# so a strip built straight off it would come out backwards — this is the whole
# reason the generator sorts numerically on the session id instead.
tm new-session -d -s zulu -n w1 -x 200 -y 50
tm set-option -g @sidetabs-summary off
tm set-option -g @sidetabs-flag-store "$STORE"
tm run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.6
tm new-session -d -s mid -n w1
tm new-session -d -s alpha -n w1
sleep 0.8

ids="$(tm list-sessions -F '#{session_id}=#{session_name}' | sort | tr '\n' ' ')"
[ "$ids" = '$0=zulu $1=mid $2=alpha ' ] || fail "setup: unexpected session ids/names: $ids"

# === 1. off by default ======================================================
# Not merely "the strip is empty" — the plugin must not have TOUCHED the status
# line, so both the per-session option and the debounce stamp must still be
# unset. sidetabs.tmux ran a forced strip.sh at load and three session-created
# hooks have fired since; all four had to be no-ops.
for s in zulu mid alpha; do
    [ -z "$(sl "$s")" ] || fail "off by default: $s has a generated status-left: [$(sl "$s")]"
    [ -z "$(sll "$s")" ] || fail "off by default: $s has a generated status-left-length"
done
[ -z "$(tm show-option -gqv @sidetabs_strip_last_ms)" ] \
    || fail "off by default: the debounce stamp was written, so strip.sh got past the gate"
strip force
[ -z "$(sl zulu)" ] || fail "off by default: an explicit forced run still wrote a status-left"
pass "the strip is off by default and touches neither status-left nor its own stamp"

# === 2. one pill per session, in creation order =============================
tm set-option -g @sidetabs-session-strip on
strip force

[ -n "$(sl zulu)" ] || fail "enabling @sidetabs-session-strip produced no status-left"
got="$(pills zulu)"
[ "$got" = " zulu | mid | alpha |" ] \
    || fail "pill order is not creation (session-id) order: [$got]"
pass "one pill per session, in creation order, not the name order list-sessions returns"

# status-left defaults to a 10-column cap, which would clip the strip after the
# first pill. The generator sets the length to the strip's own visible width:
# " zulu "6 + arrow, " mid "5 + arrow, " alpha "7 + arrow = 21.
[ "$(sll zulu)" = "21" ] || fail "status-left-length is [$(sll zulu)], expected 21"
pass "status-left-length is set to the strip's real visible width (21)"

# === 3. each session's string highlights itself =============================
has "${CUR} zulu " "$(sl zulu)"   || fail "zulu's own string does not highlight zulu: $(sl zulu)"
has "${IDLE} zulu " "$(sl mid)"   || fail "mid's string should render zulu idle: $(sl mid)"
has "${IDLE} zulu " "$(sl alpha)" || fail "alpha's string should render zulu idle: $(sl alpha)"
has "${CUR} mid "   "$(sl mid)"   || fail "mid's own string does not highlight mid: $(sl mid)"
has "${IDLE} mid "  "$(sl zulu)"  || fail "zulu's string should render mid idle: $(sl zulu)"
has "${CUR} alpha " "$(sl alpha)" || fail "alpha's own string does not highlight alpha"
# Exactly one pill per string may carry the current colour — with several
# clients on different sessions each sees only its own session's string, so
# this is what "each client sees its own session highlighted" reduces to.
# Matched on the whole pill style, not on "bg=blue": a separator ARROW pointing
# INTO the current pill legitimately carries bg=blue too.
for s in zulu mid alpha; do
    c="$(sl "$s" | grep -oF "$CUR" | grep -c . || true)"
    [ "$c" = "1" ] || fail "$s's string has $c current-coloured pills, expected exactly 1"
done
pass "each session's string highlights itself and exactly itself"

# === 4. separators ==========================================================
n_arrows="$(sl zulu | grep -o "$ARROW" | grep -c . || true)"
[ "$n_arrows" = "3" ] || fail "expected 3 solid arrows (one per pill), got $n_arrows"
if has "$THIN" "$(sl zulu)"; then fail "the thin U+E0B1 bar was emitted; every separator must be U+E0B0"; fi
pass "every separator is the solid arrow and the thin bar is never drawn"

# The last pill always arrows out into the bar background.
has "#[fg=brightblack,bg=black,nobold]${ARROW}" "$(sl zulu)" \
    || fail "the last pill does not arrow into @sidetabs-strip-bg: $(sl zulu)"
pass "the last pill arrows into the bar background"

# === 5. same-background joins get the contrast ink ==========================
# In zulu's string: zulu is current (blue), mid and alpha are both idle
# (brightblack). The mid->alpha join therefore has matching backgrounds, where
# the standard powerline fg (= the left pill's bg) would draw the arrow in the
# same ink as the surface under it and make it vanish.
has "#[fg=#2e3440,bg=brightblack,nobold]${ARROW}" "$(sl zulu)" \
    || fail "a same-background join did not use @sidetabs-strip-sep-fg: $(sl zulu)"
# ...while the differing zulu->mid join keeps the standard powerline colouring.
has "#[fg=blue,bg=brightblack,nobold]${ARROW}" "$(sl zulu)" \
    || fail "a differing-background join did not use the left pill's bg: $(sl zulu)"
tm set-option -g @sidetabs-strip-sep-fg '#123456'
strip force
has "#[fg=#123456,bg=brightblack,nobold]${ARROW}" "$(sl zulu)" \
    || fail "@sidetabs-strip-sep-fg is not configurable: $(sl zulu)"
tm set-option -gu @sidetabs-strip-sep-fg
strip force
pass "same-background joins use the configurable contrast ink; differing ones do not"

# === 6. session colour beats current; the marker follows the colour =========
# No session is coloured yet, so no marker may exist anywhere — an uncoloured
# current session has to look exactly like it did before this feature landed.
for s in zulu mid alpha; do
    if has "$MARKER" "$(sl "$s")"; then fail "$s: a marker was drawn with no session coloured"; fi
done
pass "no marker is drawn while no session is coloured"

tm run-shell "$PLUGIN_DIR/scripts/session_flag_set.sh $(appane zulu) 2"
strip force
has "${GREEN}${MARKER} zulu " "$(sl zulu)" \
    || fail "a coloured CURRENT session should be its colour plus the marker: $(sl zulu)"
has "${GREEN} zulu " "$(sl mid)" \
    || fail "a coloured non-current session should be its colour: $(sl mid)"
if has "$MARKER" "$(sl mid)"; then fail "mid's string drew a marker on a session that is not mid"; fi
if has 'bg=blue' "$(sl zulu)"; then fail "the session colour did not beat the current-session colour"; fi
pass "a session colour beats 'current', and the marker appears only on the coloured current pill"

# === 7. agent attention beats the colour, and clearing restores the pill ====
tm run-shell "$PLUGIN_DIR/scripts/session_flag_set.sh $(appane mid) 2"
strip force
has "${GREEN} mid " "$(sl zulu)" || fail "setup: mid should be green before the attention"

p_mid="$(appane mid)"
[ -n "$p_mid" ] || fail "setup: no content pane found in session mid"
# Driven through agent_status.sh itself, with NO manual strip.sh call: agent
# state is invisible to tmux's own alert machinery (agent_status.sh mimics bell
# semantics rather than using them), so agent_status.sh calling strip.sh on an
# attention transition is the only thing that can deliver this.
tm run-shell "$PLUGIN_DIR/scripts/agent_status.sh attention $p_mid"
sleep 0.4
[ "$(tm show-option -w -t mid:w1 -qv @sidetabs_agent)" = "attention" ] \
    || fail "setup: agent_status.sh did not raise attention on mid's window"
has "${BELLP} mid " "$(sl zulu)" \
    || fail "agent attention did not colour mid's pill (and beat its colour): $(sl zulu)"
pass "a window whose agent waits for input colours its session's pill, over the session colour"

tm run-shell "$PLUGIN_DIR/scripts/agent_status.sh clear $p_mid"
sleep 0.4
has "${GREEN} mid " "$(sl zulu)" \
    || fail "clearing the attention did not return mid's pill to its colour: $(sl zulu)"
pass "clearing the attention returns the pill to what it was"

# === 8. a bell beats the session colour, delivered by the alert-bell hook ===
# A dedicated session, so the bell cannot contaminate the assertions above; it
# is killed again at the end of this section. Two windows, with the bell raised
# in the one that is NOT current — tmux never raises window_bell_flag on the
# window you are already on.
tm new-session -d -s bel -n b1
sleep 0.4
tm new-window -t bel -n b2
sleep 0.6
tm select-window -t bel:b1
tm set-option -g monitor-bell on
tm set-option -g bell-action any
tm run-shell "$PLUGIN_DIR/scripts/session_flag_set.sh $(appane bel:b1) 2"
strip force
has "${GREEN} bel " "$(sl zulu)" || fail "setup: bel should be green before the bell"

tm send-keys -t "$(appane bel:b2)" 'printf "\a"' Enter
sleep 1.2
# #{session_bell_flag} IS BROKEN on tmux 3.6b and always answers 0 — upstream
# returns inside the first iteration of its window loop, so only the
# lowest-index window is ever examined. That is why the rollup is done in bash
# over #{window_bell_flag}. Asserted here (as a note, not a failure) so the day
# it is fixed upstream this test says so, rather than a future refactor
# quietly reintroducing a dependency on a format that cannot work.
if [ "$(tm display-message -p -t bel '#{session_bell_flag}')" != "0" ]; then
    echo "NOTE: #{session_bell_flag} now reports non-zero — upstream may have fixed it"
fi
[ "$(tm list-windows -t bel -F '#{window_bell_flag}' | sort -u | tail -1)" = "1" ] \
    || fail "setup: no window of bel is actually ringing"
has "${BELLP} bel " "$(sl zulu)" \
    || fail "a bell did not colour its session's pill via the alert-bell hook: $(sl zulu)"
pass "a bell beats the session colour, aggregated per window and delivered by alert-bell"
tm kill-session -t bel
sleep 0.4

# === 9. none of the old mechanism survives into the output ==================
for s in zulu mid alpha; do
    v="$(sl "$s")"
    if has '#{S:' "$v";          then fail "$s: the generated strip still contains a #{S:} loop"; fi
    if has '@strip_next' "$v";   then fail "$s: the generated strip still references @strip_next"; fi
    if has '@strip_first' "$v";  then fail "$s: the generated strip still references @strip_first"; fi
    if has '#{?' "$v";           then fail "$s: a per-client conditional survived into the output"; fi
    if has 'client_session' "$v"; then fail "$s: the output still tests #{client_session} at render time"; fi
done
[ -z "$(tm show-option -t zulu -qv @strip_next)" ] \
    || fail "a neighbour option was written; the generator must not need one"
pass "no #{S:} loop, no @strip_next bookkeeping and no per-client conditional in the output"

# === 10. emitted hex is lowercase ===========================================
# Uppercase hex CORRUPTS under a second format expansion: #D is tmux's legacy
# alias for pane_id, so #D08770 would expand to "<pane_id>08770". A user's
# palette may well be uppercase, so the generator lowercases what it emits.
tm set-option -g @sidetabs-flag-colors '#EBCB8B #A3BE8C #81A1C1'
strip force
has '#a3be8c' "$(sl zulu)" || fail "an uppercase palette entry was not lowercased: $(sl zulu)"
for s in zulu mid alpha; do
    bad="$(sl "$s" | grep -oE '#[0-9a-fA-F]{6}' | grep -E '[A-F]' || true)"
    [ -z "$bad" ] || fail "$s: uppercase hex emitted: $bad"
done
tm set-option -gu @sidetabs-flag-colors
strip force
pass "emitted hex is lowercase even when the configured palette is not"

# === 11. hooks are registered by the plugin, and really fire ================
# Registered by sidetabs.tmux — which is the fix for the reported bug. The strip
# this replaces depended on hooks that only ever existed in a running server, so
# they were gone after a machine restart and the strip rendered stale.
hooks="$(tm show-hooks -g)"
for h in 'session-created\[0\]' 'session-closed\[0\]' 'session-renamed\[0\]' \
         'alert-bell\[0\]' 'client-resized\[0\]' 'client-attached\[4\]' \
         'client-session-changed\[2\]' 'client-detached\[2\]'; do
    echo "$hooks" | grep -qE "^${h} .*strip\.sh" \
        || fail "hook ${h} is not registered to strip.sh by sidetabs.tmux"
done
echo "$hooks" | grep -qE '^session-renamed\[1\] .*flag_store\.sh sync' \
    || fail "the session-renamed store-sync hook is not registered"
pass "every strip hook is registered by the plugin itself, so it survives a restart"

# create — through the hook only, no manual strip call. The sleep first clears
# the 100ms debounce, so the assertion is about the hook and not about timing.
sleep 0.3
tm new-session -d -s omega -n w1
sleep 0.9
has ' omega ' "$(sl zulu)" || fail "session-created did not regenerate the strip: $(sl zulu)"
# zulu carries the marker by now (it was coloured in section 6, and it is the
# current session of its own string).
[ "$(pills zulu)" = "${MARKER} zulu | mid | alpha | omega |" ] \
    || fail "a new session did not land last in creation order: [$(pills zulu)]"
pass "session-created regenerates the strip, and the new pill lands last"

# rename — the strip follows, AND the durable store re-files the colour under
# the new name. mid is coloured (slot 2, set in section 7), so its row must move
# or the colour would come back on the old name after a restart.
grep -q "^mid${TAB}${TAB}2\$" "$STORE" \
    || fail "setup: no session-colour row for 'mid' in the store: $(cat "$STORE" 2>/dev/null)"
sleep 0.3
tm rename-session -t mid middle
sleep 1.0
has ' middle ' "$(sl zulu)" || fail "session-renamed did not regenerate the strip: $(sl zulu)"
if has ' mid ' "$(sl zulu)"; then fail "the strip still shows the old session name"; fi
grep -q "^middle${TAB}${TAB}2\$" "$STORE" \
    || fail "the rename did not re-file the session colour under the new name: $(cat "$STORE")"
pass "session-renamed regenerates the strip and re-files the stored colour under the new name"

# close
sleep 0.3
tm kill-session -t omega
sleep 0.9
if has ' omega ' "$(sl zulu)"; then fail "session-closed did not drop the closed session's pill"; fi
pass "session-closed regenerates the strip without the closed session"

# === 12. debounce, and the force escape =====================================
# The stamp is pinned far in the future rather than raced against a real 100ms
# window, so this asserts the debounce LOGIC deterministically instead of
# flaking on a slow machine.
strip force
before="$(sl zulu)"
tm set-option -g @sidetabs_strip_last_ms 99999999999999
tm set-option -g @sidetabs-strip-idle-bg 'colour99'
strip                       # unforced, inside the window: must be swallowed
[ "$(sl zulu)" = "$before" ] \
    || fail "an unforced run inside the debounce window was not swallowed"
pass "a burst of events is debounced into one regenerate"
strip force
has 'bg=colour99' "$(sl zulu)" || fail "force did not bypass the debounce"
tm set-option -gu @sidetabs-strip-idle-bg
strip force
pass "force bypasses the debounce, so a restore's final state is never dropped"

# === 13. tmux metacharacters in a session name ==============================
# A "#" in a name would otherwise start a format sequence, and the whole value
# is delivered through a tmux config line where a quote or a $ could break the
# parse. The value is single-quoted (tmux expands #{...} and $VAR inside DOUBLE
# quotes but not single) with any embedded quote closed-escaped-reopened.
# "a#b'c$d" is the worst name tmux will actually keep: new-session itself
# format-expands the name it is given, so a literal "#{x}" cannot survive
# creation at all (tmux drops it as an unknown format) and is not worth testing.
export SIDETABS_STRIP_ODD="a#b'c\$d"
sleep 0.3
tm new-session -d -s "$SIDETABS_STRIP_ODD" -n w1
sleep 0.9
# ENVIRON, not `awk -v`: a -v value has its backslash escapes expanded, so a
# name containing one would never match itself. Same rule flag_store.sh follows.
odd_id="$(tm list-sessions -F "#{session_id}${TAB}#{session_name}" \
    | awk -F"$TAB" '$2 == ENVIRON["SIDETABS_STRIP_ODD"] { print $1 }')"
[ -n "$odd_id" ] || fail "setup: could not find the metacharacter session"
has " a##b'c\$d " "$(sl zulu)" \
    || fail "a session name with tmux metacharacters was not escaped: $(sl zulu)"
# The width must count the DISPLAYED name (## is one column on screen), not the
# escape: 1 pad + 7 name + 1 pad + 1 arrow = 10.
prev_len="$(sll zulu)"
tm kill-session -t "$odd_id"
sleep 0.9
[ "$(( prev_len - $(sll zulu) ))" = "10" ] \
    || fail "the escaped name was width-counted as escaped, not as displayed"
pass "a session name full of tmux metacharacters round-trips and is width-counted as displayed"

# === 14. switching off leaves the last strip alone ==========================
# House rule: a run that cannot proceed is a NO-OP, never a clear. Uninstall and
# the master switch both leave status-left as last generated — a conf reload is
# what restores the user's own, because that is where it comes from.
last="$(sl zulu)"
[ -n "$last" ] || fail "setup: expected a strip before switching off"
tm set-option -g @sidetabs-session-strip off
strip force
[ "$(sl zulu)" = "$last" ] \
    || fail "switching the strip off modified status-left; that must be a no-op, never a clear"
pass "switching the strip off leaves the installed strip alone rather than clearing it"
tm set-option -g @sidetabs-session-strip on
strip force

# === 15. uninstall stops the regeneration ===================================
before="$(sl zulu)"
tm run-shell "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.6
tm new-session -d -s posthumous -n w1
sleep 0.9
[ "$(sl zulu)" = "$before" ] \
    || fail "a session created after uninstall still regenerated the strip — a hook is orphaned"
pass "uninstall tears down the strip hooks, so nothing regenerates afterwards"

echo "ALL STRIP SMOKE TESTS PASSED"
