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
#   4  the classic powerline rule: solid arrow at a colour boundary, thin
#      chevron where two adjacent pills share a background
#   5  the chevron's ink defaults to the pill's own fg, and is overridable
#   6  a session colour beats "current", and only then is the marker drawn
#  6b  setting or clearing a colour redraws the strip on its own — no tmux hook
#      fires on a user-option write, so session_flag_set.sh has to do it
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
#  16  edge pills: numbered options, individually coloured, joined the same
#      way session pills are; an unconfigured side is never written; no edge
#      pills configured is byte-identical to the session-only strip
#  17  sysinfo.sh: one measurement at a time, and the bare call is unchanged
#  18  the width cascade, every stage asserted at the exact budget that selects
#      it: marker, right pills outermost first, left pills outermost first,
#      name truncation 12/8/6/4, initials, colour blocks
#  19  stages 5 and 6 never degrade a coloured or attention-holding pill while
#      an ordinary one remains
#  20  the floor: current session + "+N", with the marker always drawn
#  21  an unowned side is measured and reserved, never overrun and never
#      dropped; an unmeasurable #(job) falls back to @sidetabs-strip-reserve
#  22  a session with no attached client is budgeted at the assumed width
#  23  @sidetabs-strip-name-max, a hard cap independent of the cascade
#  24  an impossible budget draws the floor rather than clearing the strip
#
# Section 11 covers the other half of "resizing re-fits the strip": the
# client-resized hook is registered to strip.sh by the plugin itself. The budget
# it would then recompute is exercised here through SIDETABS_STRIP_TEST_WIDTH,
# because a scratch server in a test harness has no terminal to attach.
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
ARROW="$(printf '\xee\x82\xb0')"   # U+E0B0, the solid arrow — a COLOUR BOUNDARY
THIN="$(printf '\xee\x82\xb1')"    # U+E0B1, the thin chevron — a SAME-BACKGROUND join
MARKER="$(printf '\xe2\x96\x8e')"  # U+258E, the current-session marker

tm() { tmux -L "$SOCKET" -f /dev/null "$@"; }
# The generated string for one session. -qv so an UNSET option is an empty
# string rather than an error — section 1 depends on telling those apart.
sl() { tm show-option -t "$1" -qv status-left; }
sll() { tm show-option -t "$1" -qv status-left-length; }
# run-shell WITHOUT -b: it blocks until the script finishes, so an assertion on
# the next line is reading the finished result, not racing it.
strip() { tm run-shell "$PLUGIN_DIR/scripts/strip.sh ${1:-}"; }
# The same thing with the width cascade's budget forced. Exercising the cascade
# for real would mean attaching terminals of a dozen different widths; the
# SIDETABS_STRIP_TEST_WIDTH seam forces the budget for every session instead. It
# is an environment variable, so it reaches exactly this one run — run-shell
# hands its command string to `sh -c`, which applies the assignment to it.
stripw() { tm run-shell "SIDETABS_STRIP_TEST_WIDTH=$1 $PLUGIN_DIR/scripts/strip.sh force"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
# Pill text only: drop every #[...] style and turn each separator into "|", so
# an order assertion reads like the strip looks. BOTH separator glyphs collapse
# to "|" on purpose — which glyph a given join gets is a colour question owned
# by sections 4 and 5, and every other section here is asserting pill CONTENT
# and ORDER, which must not change when two neighbours happen to share a colour.
pills() { sl "$1" | sed "s/#\[[^]]*\]//g; s/${ARROW}/|/g; s/${THIN}/|/g"; }
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
BLUEP='#[fg=#2e3440,bg=#81a1c1,bold]'    # palette slot 3, @sidetabs-flag-fg

# === setup ==================================================================
# Session names are chosen so NAME order (alpha, mid, zulu) is the exact
# reverse of CREATION order (zulu, mid, alpha). `list-sessions` sorts by name,
# so a strip built straight off it would come out backwards — this is the whole
# reason the generator sorts numerically on the session id instead.
tm new-session -d -s zulu -n w1 -x 200 -y 50
tm set-option -g @sidetabs-summary off
tm set-option -g @sidetabs-flag-store "$STORE"
# tmux's OWN default status-right is about 37 columns of content this plugin
# does not own ("<pane title>" HH:MM dd-mmm-yy), and the cascade correctly
# RESERVES those columns out of every budget. Left in place, every width
# assertion in this file would depend on the hostname, the time of day and
# today's date. It is emptied here so the budgets are arithmetic, and section 19
# puts a known status-right back to test the reserve on purpose.
tm set-option -g status-right ''
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
# first pill, so the generator sets it. It sets it to the columns the left side
# may OCCUPY — the width budget, less the columns reserved for a side the plugin
# does not own, less its own right chain — rather than to the width the strip
# happens to have come out at. Here that is the whole assumed width: no client
# is attached (200 = @sidetabs-strip-assumed-width), status-right is empty so
# nothing is reserved, and no right pill is configured.
#
# Why not the visible width: tmux's cap is then the hard backstop that stops one
# of OUR OWN #(shell) edge pills, whose rendered width can only be guessed,
# from running over content somebody else put on the bar.
[ "$(sll zulu)" = "200" ] || fail "status-left-length is [$(sll zulu)], expected 200"
pass "status-left-length is the columns the left side may occupy (the full 200-column budget)"

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

# === 4. separators: the classic powerline rule ==============================
# Which glyph a join gets is decided by whether there is a COLOUR BOUNDARY
# there. In zulu's string: zulu is current (blue), mid and alpha are both idle
# (brightblack), and the bar background is black. So:
#
#   zulu -> mid     blue        -> brightblack   boundary  -> solid arrow
#   mid  -> alpha   brightblack -> brightblack   SAME      -> thin chevron
#   alpha-> bar     brightblack -> black         boundary  -> solid arrow
#
# The counts are asserted, not just the presence of each glyph: "there is an
# arrow somewhere" would still pass if every join drew one.
n_arrows="$(sl zulu | grep -o "$ARROW" | grep -c . || true)"
n_thin="$(sl zulu | grep -o "$THIN" | grep -c . || true)"
[ "$n_arrows" = "2" ] || fail "expected 2 solid arrows (the two colour boundaries), got $n_arrows"
[ "$n_thin" = "1" ] || fail "expected 1 thin chevron (the one same-background join), got $n_thin"
pass "a colour boundary draws the solid arrow; a same-background join draws the thin chevron"

# The last pill always separates out into the bar background — a boundary here,
# so the solid arrow, in the pill's own bg exactly as any other boundary.
has "#[fg=brightblack,bg=black,nobold]${ARROW}" "$(sl zulu)" \
    || fail "the last pill does not arrow into @sidetabs-strip-bg: $(sl zulu)"
pass "the last pill arrows into the bar background"

# === 5. the chevron's ink, and its sentinel default =========================
# @sidetabs-strip-sep-fg defaults to the sentinel "match": the chevron is drawn
# in the LEFT PILL'S OWN foreground, so it stays inside that pill's colour
# family instead of being a foreign wedge sitting on it. mid is idle, so its fg
# is white and the mid->alpha chevron is white on brightblack.
# Anchored on the pill itself — "the mid pill is IMMEDIATELY followed by a
# chevron in white" — rather than on the separator alone, so this cannot be
# satisfied by some other join that happens to end up brightblack.
has "${IDLE} mid ${IDLE}${THIN}" "$(sl zulu)" \
    || fail "the default same-background ink is not the pill's own fg: $(sl zulu)"
# The differing zulu->mid join keeps the standard powerline colouring: solid
# arrow, fg = the left pill's bg. That is the look the strip is built around and
# the same-background rule must not have touched it.
has "#[fg=blue,bg=brightblack,nobold]${ARROW}" "$(sl zulu)" \
    || fail "a differing-background join did not use the left pill's bg: $(sl zulu)"
pass "the same-background chevron defaults to the pill's own fg; a boundary is unaffected"

# An explicit colour overrides the sentinel for every same-background join —
# one config line, so the ink can be taste-tested without touching the code.
tm set-option -g @sidetabs-strip-sep-fg '#123456'
strip force
has "${IDLE} mid #[fg=#123456,bg=brightblack,nobold]${THIN}" "$(sl zulu)" \
    || fail "an explicit @sidetabs-strip-sep-fg did not override the sentinel: $(sl zulu)"
if has "${IDLE} mid ${IDLE}${THIN}" "$(sl zulu)"; then
    fail "the pill's own fg was still used after an explicit ink was configured: $(sl zulu)"
fi
# It must not leak into a boundary join, which has no ink to choose.
has "#[fg=blue,bg=brightblack,nobold]${ARROW}" "$(sl zulu)" \
    || fail "the explicit sep ink leaked into a colour-boundary join: $(sl zulu)"
tm set-option -gu @sidetabs-strip-sep-fg
strip force
has "${IDLE} mid ${IDLE}${THIN}" "$(sl zulu)" \
    || fail "unsetting @sidetabs-strip-sep-fg did not return to the sentinel: $(sl zulu)"
pass "@sidetabs-strip-sep-fg overrides the sentinel and applies only to same-background joins"

# The same-background GLYPH is configurable too; the boundary arrow is not, and
# deliberately has no option at all.
tm set-option -g @sidetabs-strip-sep-glyph ':'
strip force
has "#[fg=white,bg=brightblack,nobold]:" "$(sl zulu)" \
    || fail "@sidetabs-strip-sep-glyph is not configurable: $(sl zulu)"
if has "$THIN" "$(sl zulu)"; then fail "the default chevron survived an explicit glyph: $(sl zulu)"; fi
has "#[fg=blue,bg=brightblack,nobold]${ARROW}" "$(sl zulu)" \
    || fail "@sidetabs-strip-sep-glyph changed the boundary arrow, which is not configurable: $(sl zulu)"
tm set-option -gu @sidetabs-strip-sep-glyph
strip force
has "$THIN" "$(sl zulu)" || fail "unsetting @sidetabs-strip-sep-glyph did not restore U+E0B1"
pass "the same-background glyph is configurable; the boundary arrow is fixed"

# Both glyphs are ONE display column, so a join costs 1 whichever is drawn and
# the whole width cascade is unaffected by which one a join happens to get.
# status-left-length is still the full 200-column budget, and the strip that was
# fitted into 200 columns is byte-for-byte the one section 2 asserted.
[ "$(sll zulu)" = "200" ] || fail "the separator rule changed the width budget: [$(sll zulu)]"
[ "$(pills zulu)" = " zulu | mid | alpha |" ] \
    || fail "the separator rule changed the pill layout: [$(pills zulu)]"
pass "a join still costs exactly one column, whichever glyph it draws"

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

# === 6b. setting or clearing a colour redraws the strip BY ITSELF ============
# Note what is missing from this section: a `strip force`. Section 6 calls one
# explicitly, which is right for what it asserts (the colour RESOLUTION) but
# would hide this: tmux fires NO hook on a user-option write, so nothing in the
# hook table can notice @sidetabs_sflag changing. Unless session_flag_set.sh
# regenerates the strip itself, the pill keeps its old colour until some
# unrelated event — a resize, a new session — happens to fire, which can be
# minutes later or never. Read from mid's string, where alpha is an ordinary
# non-current pill, so this is about the colour and not about the marker.
before="$(sl mid)"
has "${IDLE} alpha " "$before" || fail "setup: alpha should be idle in mid's string: $before"
tm run-shell "$PLUGIN_DIR/scripts/session_flag_set.sh $(appane alpha) 3"
has "${BLUEP} alpha " "$(sl mid)" \
    || fail "setting a session colour did not redraw the strip: $(sl mid)"
if has "${IDLE} alpha " "$(sl mid)"; then fail "alpha's pill kept its idle colour after a set"; fi
pass "setting a session colour recolours the strip pill immediately"

tm run-shell "$PLUGIN_DIR/scripts/session_flag_set.sh $(appane alpha) none"
has "${IDLE} alpha " "$(sl mid)" \
    || fail "clearing a session colour did not redraw the strip: $(sl mid)"
if has "${BLUEP} alpha " "$(sl mid)"; then fail "alpha's pill kept its colour after a clear"; fi
# Back to exactly the state section 6 left behind, so section 7 starts where it
# expects to: zulu green, mid and alpha uncoloured.
[ "$(sl mid)" = "$before" ] || fail "6b did not leave the strip as it found it: $(sl mid)"
pass "clearing a session colour returns the strip pill to idle immediately"

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

# The width must count the DISPLAYED name (7 columns: "##" is ONE "#" on
# screen), not the 8-character escape. Squeezing the budget to exactly the
# displayed width is what proves it: one column out either way changes which
# cascade stage is chosen, and the marker is the tell.
#
#   zulu is coloured, so the marker is drawn      1
#   " zulu "   + arrow                            7
#   " middle " + arrow                            9
#   " alpha "  + arrow                            8
#   " a#b'c$d "+ arrow                           10   (7 displayed, not 8)
#                                                --
#                                                 35
# At 35 everything fits and the marker stays. Counting the escape instead would
# make it 36, so the cascade would drop the marker to get under the budget.
stripw 35
has "${MARKER} zulu " "$(sl zulu)" \
    || fail "at a 35-column budget the escaped name was counted as escaped, not as displayed: $(pills zulu)"
stripw 34
if has "$MARKER" "$(sl zulu)"; then
    fail "at 34 columns the strip did not degrade at all, so the width count is too small: $(pills zulu)"
fi
strip force
tm kill-session -t "$odd_id"
sleep 0.9
pass "a session name full of tmux metacharacters round-trips and is width-counted as displayed"

# === 14. switching off leaves the last strip alone ==========================
# House rule: a run that cannot proceed is a NO-OP, never a clear. Switching the
# master switch off is exactly that — the strip stays as last generated. It is
# NOT the same thing as uninstalling, which does clear it, deliberately and per
# session (section 15).
last="$(sl zulu)"
[ -n "$last" ] || fail "setup: expected a strip before switching off"
tm set-option -g @sidetabs-session-strip off
strip force
[ "$(sl zulu)" = "$last" ] \
    || fail "switching the strip off modified status-left; that must be a no-op, never a clear"
pass "switching the strip off leaves the installed strip alone rather than clearing it"
tm set-option -g @sidetabs-session-strip on
strip force

# === 15. uninstall hands the status line back and stops regenerating =========
# Two things at once, and the second is only observable because of the first:
# uninstall UNSETS status-left per session (it is a per-session option, so a
# global one the user's conf sets is shadowed until it is unset — see
# tests/uninstall_hooks_smoke.sh §3, which owns that assertion), and it tears
# down the hooks, so nothing writes one back afterwards. If a hook were
# orphaned, the session created below would regenerate the strip and status-left
# would be non-empty again — a louder signal than the old before/after compare,
# which could not tell "nothing happened" from "the same thing happened twice".
[ -n "$(sl zulu)" ] || fail "setup: expected a strip before uninstalling"
tm run-shell "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.6
[ -z "$(sl zulu)" ] || fail "uninstall left a per-session status-left behind: [$(sl zulu)]"
[ -z "$(sll zulu)" ] || fail "uninstall left a per-session status-left-length behind"
tm new-session -d -s posthumous -n w1
sleep 0.9
[ -z "$(sl zulu)" ] \
    || fail "a session created after uninstall regenerated the strip — a hook is orphaned"
pass "uninstall unsets the per-session strip and tears down its hooks, so nothing writes it back"

# === 16. edge pills ==========================================================
# Content pinned outside the session pills as its own individually coloured
# pill(s). Numbered options (@sidetabs-strip-left-1, -2, ...), not a
# delimited list — chosen deliberately so a pill whose VALUE is itself
# "#(foo | bar)" cannot break the parse; there is nothing here to prove that
# would fail differently, so this section proves the actual contract instead:
# join rule, per-pill colour, an unconfigured side never written, and the
# session-only baseline is exactly unaffected when no edge pill is set.
# A fresh forced run first, so there IS a strip again and it reflects the
# CURRENT session set: section 15's uninstall unset status-left outright and
# tore down the hooks, so "posthumous" never triggered a regenerate and nothing
# is installed at all until this forced run puts it back.
strip force
baseline="$(sl zulu)"
[ -z "$(tm show-option -t zulu -qv status-right)" ] \
    || fail "setup: status-right is already set before any right pill is configured"

# no -1 on either side: byte-identical to the session-only strip, and
# status-right does not exist as a session-scoped option at all.
strip force
[ "$(sl zulu)" = "$baseline" ] \
    || fail "an unconfigured edge changed the strip: [$(sl zulu)] vs baseline [$baseline]"
[ -z "$(tm show-option -t zulu -qv status-right)" ] \
    || fail "status-right was written even though no right pill is configured"
pass "with no edge pills configured, the strip is byte-identical to the session-only output"

# one left pill, two right pills (the second left with no colour set, to
# exercise the idle-theme fallback), each individually coloured.
tm set-option -g @sidetabs-strip-left-1 'cpu'
tm set-option -g @sidetabs-strip-left-1-bg 'cyan'
tm set-option -g @sidetabs-strip-left-1-fg 'black'
tm set-option -g @sidetabs-strip-right-1 'clock'
tm set-option -g @sidetabs-strip-right-1-bg 'yellow'
tm set-option -g @sidetabs-strip-right-1-fg 'black'
tm set-option -g @sidetabs-strip-right-2 'battery'
strip force

got="$(pills zulu)"
case "$got" in
    " cpu |"*) ;;
    *) fail "a configured left pill did not land before the session pills: [$got]" ;;
esac
has "#[fg=black,bg=cyan,nobold] cpu " "$(sl zulu)" \
    || fail "the left pill was not coloured as configured: $(sl zulu)"
pass "a configured left pill lands before the session pills, in its configured colour"

# the left pill's own trailing arrow joins it to the FIRST session pill using
# the exact same rule session-to-session joins use (section 5). By this point
# in the file zulu is coloured green ($GREEN, set in section 6) rather than
# plain "current" — backgrounds differ (cyan -> zulu's #a3be8c), so fg = the
# left pill's own bg, exactly like any other differing-background join.
has "#[fg=cyan,bg=#a3be8c,nobold]${ARROW}" "$(sl zulu)" \
    || fail "the left pill's join into the session strip did not follow the standard rule: $(sl zulu)"
pass "an edge pill joins the session strip using the same separator rule session pills use"

# status-right holds ONLY the right pills — no session content at all — and
# follows the identical join rule between its own pills and into the bar
# background; the second pill's colour was left unset, so it must fall back
# to the idle theme rather than being left blank or erroring.
rgt="$(tm show-option -t zulu -qv status-right)"
[ -n "$rgt" ] || fail "status-right was not written once a right pill is configured"
if has 'zulu' "$rgt"; then fail "status-right leaked session-pill content: $rgt"; fi
has "#[fg=black,bg=yellow,nobold] clock " "$rgt" \
    || fail "the first right pill was not coloured as configured: $rgt"
has "#[fg=white,bg=brightblack,nobold] battery " "$rgt" \
    || fail "an uncoloured right pill did not fall back to the idle theme colour: $rgt"
has "#[fg=yellow,bg=brightblack,nobold]${ARROW}" "$rgt" \
    || fail "the join between two right pills did not follow the standard rule: $rgt"
has "#[fg=brightblack,bg=black,nobold]${ARROW}" "$rgt" \
    || fail "the last right pill did not arrow into the bar background: $rgt"
pass "right pills form their own status-right, individually coloured, joined the same way"

# ...and the same-background half of the rule reaches edge pills too. This is
# the shape the strip is actually used in: several sysinfo pills all sharing one
# colour, where a solid arrow at every join draws a row of heavy wedges between
# pills that are the same colour. Both pills black-on-yellow, so the join is a
# thin chevron in the left pill's own fg (black), and no arrow at all.
tm set-option -g @sidetabs-strip-right-2-bg 'yellow'
tm set-option -g @sidetabs-strip-right-2-fg 'black'
strip force
rgt="$(tm show-option -t zulu -qv status-right)"
has "#[fg=black,bg=yellow,nobold]${THIN}" "$rgt" \
    || fail "two same-coloured edge pills did not get the thin chevron: $rgt"
if has "bg=yellow,nobold]${ARROW}" "$rgt"; then
    fail "a same-background edge-pill join still drew the solid arrow: $rgt"
fi
# The last pill still crosses a real boundary into the bar background.
has "#[fg=yellow,bg=black,nobold]${ARROW}" "$rgt" \
    || fail "the last right pill did not arrow into the bar background: $rgt"
pass "adjacent edge pills sharing a colour are joined by the chevron, not a solid arrow"
tm set-option -gu @sidetabs-strip-right-2-bg
tm set-option -gu @sidetabs-strip-right-2-fg
strip force
rgt="$(tm show-option -t zulu -qv status-right)"

# status-right carries no "current" concept, but the OPTION is per-session
# (fact 3, same as status-left), so every session still needs its own copy —
# checked against a session other than the one every other assertion here
# reads from.
[ -n "$(tm show-option -t middle -qv status-right)" ] \
    || fail "status-right was only written for one session; it is itself a per-session option"
[ "$(tm show-option -t middle -qv status-right)" = "$rgt" ] \
    || fail "status-right differs between sessions, but right pills have no per-session content"
pass "status-right is written identically for every session, since it is itself per-session"

# clearing every left pill returns status-left to the byte-identical
# session-only baseline; status-right is left exactly as last generated —
# house rule: a no-longer-configured side is a no-op, never a clear.
tm set-option -gu @sidetabs-strip-left-1
tm set-option -gu @sidetabs-strip-left-1-bg
tm set-option -gu @sidetabs-strip-left-1-fg
strip force
[ "$(sl zulu)" = "$baseline" ] \
    || fail "clearing the left pill did not restore the byte-identical session-only strip"
[ "$(tm show-option -t zulu -qv status-right)" = "$rgt" ] \
    || fail "clearing the left pill unexpectedly touched status-right"
pass "clearing every left pill restores the session-only strip exactly; status-right is untouched"

tm set-option -gu @sidetabs-strip-right-1
tm set-option -gu @sidetabs-strip-right-2
tm set-option -gu @sidetabs-strip-right-1-bg
tm set-option -gu @sidetabs-strip-right-1-fg
pass "edge-pill options cleared"

# === 17. sysinfo.sh: one measurement at a time ===============================
SYSINFO="$PLUGIN_DIR/scripts/sysinfo.sh"
ICON_LOAD="$(printf '\xef\x83\xa4')"   # U+F0E4
ICON_MEM="$(printf '\xef\x8b\x9b')"    # U+F2DB
ICON_DISK="$(printf '\xef\x82\xa0')"   # U+F0A0
THINBAR="$(printf '\xee\x82\xb1')"     # U+E0B1, sysinfo.sh's OWN internal separator

all_out="$("$SYSINFO")"
has "$ICON_LOAD" "$all_out" || fail "sysinfo.sh (no arg) is missing the load icon: $all_out"
has "$ICON_MEM"  "$all_out" || fail "sysinfo.sh (no arg) is missing the mem icon: $all_out"
has "$ICON_DISK" "$all_out" || fail "sysinfo.sh (no arg) is missing the disk icon: $all_out"
sepcount="$(printf '%s' "$all_out" | grep -o "$THINBAR" | grep -c . || true)"
[ "$sepcount" = "2" ] \
    || fail "sysinfo.sh (no arg) should join its 3 measurements with 2 separators, got $sepcount: $all_out"
pass "sysinfo.sh with no argument still prints all three measurements, exactly as before"

load_out="$("$SYSINFO" load)"
has "$ICON_LOAD" "$load_out" || fail "sysinfo.sh load is missing the load icon: $load_out"
if has "$ICON_MEM"  "$load_out"; then fail "sysinfo.sh load leaked the mem icon: $load_out"; fi
if has "$ICON_DISK" "$load_out"; then fail "sysinfo.sh load leaked the disk icon: $load_out"; fi
if has "$THINBAR"   "$load_out"; then fail "sysinfo.sh load emitted the combined form's separator: $load_out"; fi
pass "sysinfo.sh load prints only the load measurement, unjoined"

mem_out="$("$SYSINFO" mem)"
has "$ICON_MEM" "$mem_out" || fail "sysinfo.sh mem is missing the mem icon: $mem_out"
if has "$ICON_LOAD" "$mem_out"; then fail "sysinfo.sh mem leaked the load icon: $mem_out"; fi
if has "$ICON_DISK" "$mem_out"; then fail "sysinfo.sh mem leaked the disk icon: $mem_out"; fi
pass "sysinfo.sh mem prints only the memory measurement"

disk_out="$("$SYSINFO" disk)"
has "$ICON_DISK" "$disk_out" || fail "sysinfo.sh disk is missing the disk icon: $disk_out"
if has "$ICON_LOAD" "$disk_out"; then fail "sysinfo.sh disk leaked the load icon: $disk_out"; fi
if has "$ICON_MEM"  "$disk_out"; then fail "sysinfo.sh disk leaked the mem icon: $disk_out"; fi
pass "sysinfo.sh disk prints only the disk measurement"

# never errors, even on garbage input — same promise the header comment makes.
"$SYSINFO" bogus-argument >/dev/null || fail "sysinfo.sh exited non-zero on an unrecognized argument"
pass "an unrecognized argument does not error"

# === 18. the width cascade ==================================================
# tmux truncates by HARD CUT at the client edge — no ellipsis, no marker, and a
# 2-column glyph that does not fit is dropped whole — so a clipped strip is
# indistinguishable from a short one. Every stage below is therefore asserted at
# the exact budget that selects it, and at the budget one column above it, so a
# stage that fired early or late is a failure rather than a coincidence.
#
# A clean world with names of known length, replacing the accumulated cast:
#
#   zulu (4)            current in the strings read below, and COLOURED
#                       (slot 2, section 6) so the marker is drawn at stage 0
#   longsessionname(15) ordinary — the one that has to give way
#   mark (4)            COLOURED slot 3: informative, so stages 5 and 6 may
#                       never touch it while an ordinary pill remains
#   tmp (3)             ordinary
#
# The hooks are gone (section 15 uninstalled them), so every regenerate here is
# an explicit forced run — which is what `stripw` does anyway.
for s in middle alpha posthumous; do tm kill-session -t "$s" 2>/dev/null || true; done
# Section 16 configured right pills and then unset them, leaving behind the
# per-session status-right the plugin wrote while it still OWNED that side. It
# no longer owns it, so from here on that leftover is (correctly) measured as
# somebody else's content and reserved out of the budget — house rule, a side
# the plugin stops owning is left alone, not cleared. Cleared here so the
# budgets below are pure arithmetic; section 21 tests the reserve deliberately.
tm list-sessions -F '#{session_name}' | while read -r s; do
    tm set-option -t "$s" -u status-right 2>/dev/null || true
done
sleep 0.3
tm new-session -d -s longsessionname -n w1
tm new-session -d -s mark -n w1
tm new-session -d -s tmp -n w1
sleep 0.6
tm run-shell "$PLUGIN_DIR/scripts/session_flag_set.sh $(appane mark) 3"
sleep 0.4

# Stage 0, the full strip:
#   marker                                1
#   " zulu "            + arrow           7
#   " longsessionname " + arrow          18
#   " mark "            + arrow           7
#   " tmp "             + arrow           6
#                                        --
#                                        39
FULL="${MARKER} zulu | longsessionname | mark | tmp |"
BARE=" zulu | longsessionname | mark | tmp |"
stripw 39
[ "$(pills zulu)" = "$FULL" ] || fail "stage 0 at its exact budget (39) is not the full strip: [$(pills zulu)]"
pass "stage 0: at exactly the width it needs, the strip shows everything"

# stage 1 — the marker is the first thing sacrificed.
stripw 38
[ "$(pills zulu)" = "$BARE" ] \
    || fail "stage 1 should drop only the marker at 38 columns: [$(pills zulu)]"
pass "stage 1: one column short, the current-session marker goes first"

# stages 2 and 3 — edge pills, OUTERMOST first, one per stage. Two a side, each
# 2 characters wide, so each costs 1 pad + 2 + 1 pad + 1 arrow = 5:
#   stage 0 with edges 39+20 = 59, stage 1 = 58, then 53, 48, 43, 38.
tm set-option -g @sidetabs-strip-left-1 'ab'
tm set-option -g @sidetabs-strip-left-2 'cd'
tm set-option -g @sidetabs-strip-right-1 'ef'
tm set-option -g @sidetabs-strip-right-2 'gh'
# Both separator glyphs collapse to "|", for the same reason pills() does it:
# these assertions are about which pills survived the cascade, not about which
# glyph joins two pills that happen to share the idle background.
rpills() { tm show-option -t "$1" -qv status-right \
    | sed "s/#\[[^]]*\]//g; s/${ARROW}/|/g; s/${THIN}/|/g"; }

stripw 59
[ "$(pills zulu)" = " ab | cd |${FULL}" ] \
    || fail "with edge pills, stage 0 at 59 is wrong: [$(pills zulu)]"
[ "$(rpills zulu)" = " ef | gh |" ] || fail "both right pills should be present at 59: [$(rpills zulu)]"
pass "stage 0 with edge pills: everything, both sides"

stripw 53
[ "$(rpills zulu)" = " ef |" ] \
    || fail "stage 2 should drop the OUTERMOST (rightmost) right pill first: [$(rpills zulu)]"
[ "$(pills zulu)" = " ab | cd |${BARE}" ] \
    || fail "stage 2 must not touch the left side: [$(pills zulu)]"
pass "stage 2: right pills go before any left pill, rightmost first"

stripw 48
[ "$(rpills zulu)" = "" ] || fail "the second right pill should be gone at 48: [$(rpills zulu)]"
[ "$(pills zulu)" = " ab | cd |${BARE}" ] \
    || fail "the left side must survive until every right pill is gone: [$(pills zulu)]"
pass "stage 2: the whole right side is spent before the left side is touched"

stripw 43
[ "$(pills zulu)" = " cd |${BARE}" ] \
    || fail "stage 3 should drop the OUTERMOST (leftmost) left pill first: [$(pills zulu)]"
pass "stage 3: left pills go next, leftmost first"

stripw 38
[ "$(pills zulu)" = "$BARE" ] || fail "at 38 every edge pill should be gone: [$(pills zulu)]"
pass "stage 3: the last left pill goes before a session name is shortened"

for o in left-1 left-2 right-1 right-2; do tm set-option -gu "@sidetabs-strip-${o}"; done

# stage 4 — name truncation, 12 then 8 then 6 then 4. Only longsessionname is
# long enough to be affected; the arithmetic is 7 + (cap+3) + 7 + 6.
stripw 35
[ "$(pills zulu)" = " zulu | longsessionn | mark | tmp |" ] \
    || fail "stage 4 should truncate names to 12 at 35 columns: [$(pills zulu)]"
stripw 31
[ "$(pills zulu)" = " zulu | longsess | mark | tmp |" ] \
    || fail "stage 4 should truncate names to 8 at 31 columns: [$(pills zulu)]"
stripw 29
[ "$(pills zulu)" = " zulu | longse | mark | tmp |" ] \
    || fail "stage 4 should truncate names to 6 at 29 columns: [$(pills zulu)]"
stripw 27
[ "$(pills zulu)" = " zulu | long | mark | tmp |" ] \
    || fail "stage 4 should truncate names to 4 at 27 columns: [$(pills zulu)]"
pass "stage 4: names truncate 12 -> 8 -> 6 -> 4, one step per column budget"

# stage 5 — ordinary non-current sessions become a single initial. zulu is the
# viewer and mark is coloured, so both keep their (already truncated) names.
stripw 22
[ "$(pills zulu)" = " zulu | l | mark | t |" ] \
    || fail "stage 5 should reduce ordinary sessions to an initial at 22: [$(pills zulu)]"
pass "stage 5: ordinary sessions drop to a single initial; the current and the coloured keep their names"

# stage 6 — and then to a bare block of their own colour, still one pill per
# session, so the strip still says how many sessions there are.
stripw 18
[ "$(pills zulu)" = " zulu | | mark | |" ] \
    || fail "stage 6 should blank ordinary sessions to a colour block at 18: [$(pills zulu)]"
# The block really is the pill colour with no text in it, not an empty string.
has "${IDLE} #[" "$(sl zulu)" \
    || fail "a blanked pill is not a coloured block: $(sl zulu)"
pass "stage 6: ordinary sessions become a bare block of their colour"

# === 19. stages 5 and 6 never degrade an informative pill ===================
# "mark" is coloured through both stages above while its ordinary neighbours are
# spent first — that is the rule for a colour you set on purpose. The same has
# to hold for a pill that is asking for you: agent attention (and a bell, which
# takes the identical branch in resolve_pills and is exercised in section 8).
has "${BLUEP} mark " "$(sl zulu)" \
    || fail "the coloured pill lost its text while an ordinary one was still on screen: $(sl zulu)"
pass "a coloured pill keeps its full name at the stage that blanks ordinary ones"

p_tmp="$(appane tmp)"
tm run-shell "$PLUGIN_DIR/scripts/agent_status.sh attention $p_tmp"
sleep 0.4
[ "$(tm show-option -w -t tmp:w1 -qv @sidetabs_agent)" = "attention" ] \
    || fail "setup: agent_status.sh did not raise attention on tmp's window"
# tmp is now informative too, so only longsessionname may be degraded:
#   stage 5:  7 + 4 (l) + 7 + 6 = 24     stage 6:  7 + 2 + 7 + 6 = 22
stripw 24
[ "$(pills zulu)" = " zulu | l | mark | tmp |" ] \
    || fail "attention did not protect tmp from stage 5: [$(pills zulu)]"
stripw 22
[ "$(pills zulu)" = " zulu | | mark | tmp |" ] \
    || fail "attention did not protect tmp from stage 6: [$(pills zulu)]"
has "${BELLP} tmp " "$(sl zulu)" \
    || fail "the attention pill is not drawn in the bell colours: $(sl zulu)"
pass "a pill holding agent attention keeps its name while ordinary pills are spent first"
tm run-shell "$PLUGIN_DIR/scripts/agent_status.sh clear $p_tmp"
sleep 0.4

# === 20. the floor =========================================================
# Below stage 6 there is one pill left: which session you are in, and how many
# you cannot see. "▎ zulu +3 " is 1+1+4+3+1 = 10 columns plus its arrow.
stripw 11
[ "$(pills zulu)" = "${MARKER} zulu +3 |" ] \
    || fail "the floor should be the current session plus a count at 11 columns: [$(pills zulu)]"
n_arrows="$(sl zulu | grep -o "$ARROW" | grep -c . || true)"
[ "$n_arrows" = "1" ] || fail "the floor should be exactly one pill, found $n_arrows arrows"
pass "the floor names the session you are in and counts the ones it could not show"

# The marker at the floor overrides the normal rule that it is drawn only on a
# COLOURED current session: longsessionname has no colour of its own, and at
# this width the marker is the only thing saying that pill is where you are
# rather than the only session that fitted. Its name gives way to keep the
# count, which is the part you cannot infer from anything else on screen.
[ "$(pills longsessionname)" = "${MARKER} long +3 |" ] \
    || fail "an uncoloured session's floor is wrong: [$(pills longsessionname)]"
pass "at the floor the marker is always drawn, even for a session with no colour of its own"

# One session and nothing else: "+0" would be information-shaped noise.
tm new-session -d -s solo -n w1
sleep 0.3
for s in zulu longsessionname mark tmp; do tm kill-session -t "$s"; done
sleep 0.3
stripw 4
[ "$(pills solo)" = "${MARKER} s |" ] \
    || fail "a single-session floor should carry no count: [$(pills solo)]"
pass "with nothing hidden the floor carries no count, and the name gives way to the width"

# === 21. an unowned side is measured and reserved, never overrun ============
# status-left always belongs to the plugin; status-right belongs to it only when
# @sidetabs-strip-right-1 is set. Otherwise it is the user's (or another
# plugin's, or tmux's own default), so its width comes out of the budget and its
# content is never touched — an unowned side has no stage in the cascade.
tm new-session -d -s aa -n w1
tm new-session -d -s bb -n w1
sleep 0.5
# " solo " + arrow 7, " aa " + arrow 5, " bb " + arrow 5 = 17; solo is current
# and uncoloured, so there is no marker to drop.
BASE=" solo | aa | bb |"
stripw 17
[ "$(pills solo)" = "$BASE" ] || fail "setup: unexpected baseline strip: [$(pills solo)]"

tm set-option -g status-right '0123456789'
stripw 27
[ "$(pills solo)" = "$BASE" ] \
    || fail "10 reserved columns should shift the same strip from 17 to 27: [$(pills solo)]"
stripw 26
[ "$(pills solo)" != "$BASE" ] \
    || fail "the reserved columns were not subtracted from the budget at all: [$(pills solo)]"
pass "an unowned status-right is measured and its columns come out of the budget"

# Style sequences cost no columns on screen, so they must cost none here either.
tm set-option -g status-right '#[fg=red,bg=blue]0123456789#[default]'
stripw 27
[ "$(pills solo)" = "$BASE" ] \
    || fail "#[...] style runs were counted as width in the unowned side: [$(pills solo)]"
pass "style escapes in an unowned side are not counted as width"

# A #(shell) job cannot be measured: tmux schedules it asynchronously, and the
# expansion does not even leave a "#(" behind to notice — an option holding
# "#(echo hi) %H:%M" expands to " 11:36". So the job is detected on the RAW
# value, and @sidetabs-strip-reserve covers what could not be measured.
# "#(true)" prints nothing, so the assertion cannot flake on whether tmux has
# cached the job's output by the time the strip is regenerated.
tm set-option -g status-right '#(true)'
stripw 29
[ "$(pills solo)" = "$BASE" ] \
    || fail "the auto reserve for an unmeasurable #(job) is not 12 columns: [$(pills solo)]"
stripw 28
[ "$(pills solo)" != "$BASE" ] \
    || fail "an unmeasurable #(job) reserved nothing at all: [$(pills solo)]"
pass "a side whose width cannot be measured falls back to the configured reserve (auto = 12 per job)"

tm set-option -g @sidetabs-strip-reserve 30
stripw 47
[ "$(pills solo)" = "$BASE" ] \
    || fail "an explicit @sidetabs-strip-reserve was not honoured: [$(pills solo)]"
stripw 46
[ "$(pills solo)" != "$BASE" ] || fail "an explicit reserve was ignored: [$(pills solo)]"
tm set-option -gu @sidetabs-strip-reserve
pass "@sidetabs-strip-reserve overrides the estimate for a side carrying a shell job"

# ...and through all of that the unowned side itself was never written, not even
# at a width where the plugin had to fall back to its own floor.
stripw 6
[ "$(tm show-option -t solo -qv status-right)" = "" ] \
    || fail "the plugin wrote a status-right it does not own: [$(tm show-option -t solo -qv status-right)]"
[ "$(tm show-option -gv status-right)" = '#(true)' ] \
    || fail "the plugin modified the global status-right it does not own"
has "$MARKER" "$(sl solo)" || fail "the strip did not fall back to its floor at 6 columns: [$(pills solo)]"
pass "an unowned side is reserved and never dropped, written or cleared — even at the floor"
tm set-option -g status-right ''

# === 22. a session with no attached client =================================
# Nothing is attached to this scratch server at all, so every strip in this file
# has been generated for a client-less session. What the budget is in that case
# is @sidetabs-strip-assumed-width, asserted here without the test override —
# which also proves the override is not the only path into the cascade.
# " solo " + arrow is 7, and two blocks are 2 each, so stage 6 needs 11: at 10
# even that is too wide and the floor is all that is left, with the NAME giving
# way to keep the count.
tm set-option -g @sidetabs-strip-assumed-width 10
strip force
[ "$(pills solo)" = "${MARKER} sol +2 |" ] \
    || fail "the assumed width did not drive the cascade: [$(pills solo)]"
tm set-option -g @sidetabs-strip-assumed-width 200
strip force
[ "$(pills solo)" = "$BASE" ] \
    || fail "a client-less session did not get a full-width strip at the default assumed width: [$(pills solo)]"
[ "$(sll solo)" = "200" ] || fail "status-left-length should be the assumed budget, got [$(sll solo)]"
pass "a session with no attached client is budgeted at @sidetabs-strip-assumed-width and still gets a usable strip"

# === 23. @sidetabs-strip-name-max ==========================================
# A hard cap applied at stage 0, INDEPENDENTLY of the cascade: it holds at any
# width, including one where nothing would have been truncated at all.
tm set-option -g @sidetabs-strip-name-max 2
stripw 200
[ "$(pills solo)" = " so | aa | bb |" ] \
    || fail "@sidetabs-strip-name-max did not cap names at a width with room to spare: [$(pills solo)]"
[ "$(sll solo)" = "200" ] || fail "the cap should not change the length budget, got [$(sll solo)]"
pass "@sidetabs-strip-name-max caps names at stage 0, independently of the cascade"

# ...and the cascade still runs underneath it: at 11 columns the cap is not
# enough on its own (2+3 + 2+3 + 2+3 = 15), so ordinary pills go to initials
# (5 + 4 + 4 = 13), then to blocks (5 + 2 + 2 = 9).
stripw 13
[ "$(pills solo)" = " so | a | b |" ] \
    || fail "the cascade did not continue below the name cap: [$(pills solo)]"
stripw 9
[ "$(pills solo)" = " so | | |" ] \
    || fail "the cascade did not reach the block stage below the name cap: [$(pills solo)]"
tm set-option -gu @sidetabs-strip-name-max
pass "the cascade keeps shedding detail below a configured name cap"

# === 24. the cascade never leaves an empty strip ===========================
# House rule: a run that cannot proceed is a no-op, never a clear. A budget of
# zero is not a reason to blank the bar — it is a reason to draw the floor and
# let tmux clip, because a strip that says the wrong thing is still better than
# one that says nothing about where you are.
last="$(sl solo)"
stripw 1
[ -n "$(sl solo)" ] || fail "a 1-column budget cleared the strip"
has "$MARKER" "$(sl solo)" || fail "a 1-column budget did not fall back to the floor: [$(pills solo)]"
[ "$(sll solo)" -ge 1 ] || fail "status-left-length went to zero or below: [$(sll solo)]"
pass "even an impossible budget draws the floor rather than clearing the strip"
strip force
[ -n "$(sl solo)" ] || fail "the strip did not come back after the forced-width runs"

echo "ALL STRIP SMOKE TESTS PASSED"
