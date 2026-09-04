#!/usr/bin/env bash
# Smoke test for the uninstall.sh hook-teardown fix (ticket 02).
#
# Naming an array hook without an index clears EVERY index on that name
# (verified on tmux 3.6) — so a bare `set-hook -gu after-new-window` doesn't
# just remove sidetabs' own handler, it wipes any handler another plugin
# appended with `set-hook -ga` on the same name. tmux-ticker (a separate
# plugin the user also runs) does exactly that on after-new-window,
# after-new-session, window-renamed, window-layout-changed and
# session-window-changed, so the old bare-name unset silently broke it with
# no error. Two independent assertions:
#   1. Drift check (static, no tmux needed): the hook name+index set
#      sidetabs.tmux registers and the set scripts/uninstall.sh tears down
#      must be identical, so a future hook can't be added to one without the
#      other — a real grep of both files, not a hardcoded expectation.
#   2. Foreign-handler survival (live, scratch server): append a foreign -ga
#      handler on a shared hook name, uninstall, and assert the foreign
#      handler is still registered and still fires while every sidetabs
#      handler is gone.
#
# -f /dev/null is required on every new-session/tmux -L call below: without
# it a new server on this socket still auto-loads the user's ~/.tmux.conf
# (which run-shells this plugin AND tmux-ticker), polluting hooks and
# defeating test isolation.
set -euo pipefail

SOCKET="sidetab_uninhook_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MARKER_NEW="${TMPDIR:-/tmp}/sidetabs_uninhook_new_$$"
MARKER_RENAMED="${TMPDIR:-/tmp}/sidetabs_uninhook_renamed_$$"
# Section 3 runs on a server of its own: section 2 has already uninstalled on
# $SOCKET, and the status-line assertions need a server where the strip was
# never torn down before they start.
SOCKET2="sidetab_uninstrip_$$"
STORE2="${TMPDIR:-/tmp}/sidetabs_uninstrip_store_$$.tsv"

cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    tmux -L "$SOCKET2" kill-server 2>/dev/null || true
    rm -f "$MARKER_NEW" "$MARKER_RENAMED"
    rm -rf "$STORE2" "${STORE2}.lock" "${STORE2}"*.tmp.* "${STORE2}"*.live.*
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
run() { tmux -L "$SOCKET" run-shell "$*"; }

# === 1. Drift check =========================================================
# Extract every `set-hook -g` target sidetabs.tmux registers, normalizing a
# bare (unbracketed) name to its implicit index [0] per tmux's array-hook
# rules — the same normalization the fix in uninstall.sh applies by hand.
plugin_hooks="$(grep -oE "set-hook -g ('[A-Za-z-]+\[[0-9]+\]'|[A-Za-z-]+)" "$PLUGIN_DIR/sidetabs.tmux" \
    | sed -E "s/^set-hook -g //; s/'//g" \
    | awk '{ if ($0 !~ /\[/) $0 = $0 "[0]"; print }' \
    | sort -u)"

# Extract every quoted "name[index]" token uninstall.sh's teardown array unsets.
uninstall_hooks="$(grep -oE "'[A-Za-z-]+\[[0-9]+\]'" "$PLUGIN_DIR/scripts/uninstall.sh" \
    | tr -d "'" \
    | sort -u)"

[ -n "$plugin_hooks" ] || fail "drift check: extracted zero hooks from sidetabs.tmux — extraction regex is broken"
[ -n "$uninstall_hooks" ] || fail "drift check: extracted zero hooks from uninstall.sh — extraction regex is broken"

missing="$(comm -23 <(printf '%s\n' "$plugin_hooks") <(printf '%s\n' "$uninstall_hooks") | tr '\n' ' ')"
extra="$(comm -13 <(printf '%s\n' "$plugin_hooks") <(printf '%s\n' "$uninstall_hooks") | tr '\n' ' ')"

if [ -n "$missing" ] || [ -n "$extra" ]; then
    [ -n "$missing" ] && echo "  registered by sidetabs.tmux but NOT torn down by uninstall.sh: $missing"
    [ -n "$extra" ]   && echo "  torn down by uninstall.sh but NOT registered by sidetabs.tmux: $extra"
    fail "hook registration (sidetabs.tmux) and teardown (uninstall.sh) sets disagree"
fi
hook_count="$(printf '%s\n' "$plugin_hooks" | wc -l | tr -d ' ')"
pass "uninstall.sh tears down exactly the $hook_count hook(s) sidetabs.tmux registers"

# === 2. Foreign-handler survival ============================================
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -x 200 -y 50
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.5

# `show-hooks -g` only enumerates a fixed table of tmux-internal hook names —
# on tmux 3.6b it silently omits window-renamed, window-layout-changed and
# pane-focus-in even when set (they still fire; verified separately below).
# Detect which of our hooks are actually visible through it BEFORE touching
# any of them, so the static assertions below never depend on a hardcoded,
# version-specific quirk list.
visible_base_names="$(tmux -L "$SOCKET" show-hooks -g | awk '{print $1}' | sed -E 's/\[[0-9]+\]$//' | sort -u)"

# Sanity: sidetabs' own after-new-window handler is registered at index 0.
tmux -L "$SOCKET" show-hooks -g | grep -q '^after-new-window\[0\] .*create_sidebar\.sh' \
    || fail "setup: sidetabs' after-new-window[0] handler not found before uninstall"

# Append foreign handlers on two of the five hook names tmux-ticker shares
# with sidetabs: after-new-window (show-hooks-visible, so we can assert on
# its index directly) and window-renamed (not show-hooks-visible, so it is
# checked purely by firing — this is the name most directly named in the
# ticket, so it gets exercised too, not skipped just because tmux can't show it).
rm -f "$MARKER_NEW" "$MARKER_RENAMED"
tmux -L "$SOCKET" set-hook -ga after-new-window "run-shell 'touch $MARKER_NEW'"
tmux -L "$SOCKET" set-hook -ga window-renamed   "run-shell 'touch $MARKER_RENAMED'"

# -ga appends to the next free array slot — must land at [1], right after
# sidetabs' own [0], for the "same index survives" assertion below to mean
# anything.
tmux -L "$SOCKET" show-hooks -g | grep -q "^after-new-window\[1\] .*$MARKER_NEW" \
    || fail "setup: foreign after-new-window handler did not land at index 1"

# --- run uninstall -----------------------------------------------------------
run "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.5

post_hooks="$(tmux -L "$SOCKET" show-hooks -g)"

# The foreign handler must survive at its OWN index, untouched — proving the
# fix unset index [0] specifically rather than clearing the whole array.
echo "$post_hooks" | grep -q "^after-new-window\[1\] .*$MARKER_NEW" \
    || fail "foreign after-new-window[1] handler did not survive uninstall"
pass "foreign after-new-window[1] handler survives uninstall at its own index"

# Every sidetabs hook+index that show-hooks -g can actually see must be gone.
# (window-renamed / window-layout-changed / pane-focus-in are excluded here
# because tmux itself never lists them, set or not — see the note above; they
# are covered by the functional checks below instead.)
checked=0
while IFS= read -r hookidx; do
    base="${hookidx%%\[*}"
    if printf '%s\n' "$visible_base_names" | grep -qx "$base"; then
        checked=$((checked + 1))
        echo "$post_hooks" | grep -q "^${hookidx} " \
            && fail "sidetabs hook $hookidx is still registered after uninstall"
    fi
done <<EOF
$plugin_hooks
EOF
[ "$checked" -gt 0 ] || fail "no plugin hook was show-hooks-visible — assertion above checked nothing"
pass "every show-hooks-visible sidetabs hook ($checked checked) is gone after uninstall"

# Functional checks: trigger the actual tmux events. The foreign handlers
# must still fire; sidetabs' own effects (a new sidetab pane, a rename
# refresh) must not happen, proving no orphaned handler is still running.
pre_sidetabs="$(tmux -L "$SOCKET" list-panes -a -F '#{@is_sidetab}' | grep -c '^1$' || true)"
tmux -L "$SOCKET" new-window
sleep 0.5
[ -f "$MARKER_NEW" ] || fail "foreign after-new-window handler did not fire on a real new-window event"
post_sidetabs="$(tmux -L "$SOCKET" list-panes -a -F '#{@is_sidetab}' | grep -c '^1$' || true)"
[ "$post_sidetabs" = "$pre_sidetabs" ] \
    || fail "a sidetab pane was (re)created after uninstall — sidetabs' after-new-window handler is orphaned"
pass "foreign after-new-window handler fires on new-window; sidetabs no longer creates a sidetab"

tmux -L "$SOCKET" rename-window -t main renamed-after-uninstall
sleep 0.5
[ -f "$MARKER_RENAMED" ] || fail "foreign window-renamed handler did not fire on a real rename event"
pass "foreign window-renamed handler fires after uninstall"

# === 3. status-line restore =================================================
# The strip's status-left is a PER-SESSION option, and a per-session value
# SHADOWS the global one — so a config reload alone cannot take the bar back,
# whatever the global says. uninstall.sh has to unset it per session.
#
# Every assertion is made two ways on purpose:
#   show-option -t <s> -qv    the SESSION-scoped value only (empty = unset; it
#                             does not fall back to the global — verified)
#   display-message -t <s> -p '#{status-left}'
#                             what a client attached to that session actually
#                             renders, i.e. whether the global shows through
# The second is the one that matches the acceptance criterion; the first says
# why.
t2() { tmux -L "$SOCKET2" -f /dev/null "$@"; }
sopt() { t2 show-option -t "$1" -qv "$2"; }        # session scope only
rendered() { t2 display-message -t "$1" -p "#{$2}"; }

GLOBAL_LEFT='USERS-OWN-STATUS-LEFT'
GLOBAL_RIGHT='USERS-OWN-STATUS-RIGHT'
SESSION_RIGHT='BETAS-OWN-STATUS-RIGHT'

t2 new-session -d -s alpha -n w1 -x 200 -y 50
t2 set-option -g @sidetabs-summary off
t2 set-option -g @sidetabs-flag-store "$STORE2"
t2 set-option -g status-left "$GLOBAL_LEFT"
t2 set-option -g status-right "$GLOBAL_RIGHT"
t2 set-option -g @sidetabs-session-strip on
t2 run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.6
t2 new-session -d -s beta -n w1
t2 new-session -d -s gamma -n w1
sleep 0.8
# beta owns its status-right at SESSION scope, not just globally: an
# unset-everything uninstall would take this out too, and a global-only check
# would never notice.
t2 set-option -t beta status-right "$SESSION_RIGHT"
t2 run-shell "$PLUGIN_DIR/scripts/strip.sh force"

# --- 3a. setup: the strip really is shadowing the user's status-left ---------
for s in alpha beta gamma; do
    [ -n "$(sopt "$s" status-left)" ] \
        || fail "setup: $s has no generated status-left — the strip never ran"
    [ "$(rendered "$s" status-left)" = "$(sopt "$s" status-left)" ] \
        || fail "setup: $s does not render its per-session status-left"
done
# An `if`, not `[ … ] && fail`: under this file's `set -e` a false test in that
# form exits the script with 0 assertions run and no output.
if [ "$(rendered alpha status-left)" = "$GLOBAL_LEFT" ]; then
    fail "setup: the per-session strip is NOT shadowing the global status-left — this test proves nothing"
fi
pass "setup: the generated per-session status-left shadows the user's global one"

# The plugin owns status-right ONLY when @sidetabs-strip-right-1 is set, which
# it is not here, so both the global and beta's own session value must have
# survived generation untouched. (strip_smoke covers this for the generator;
# repeated here because it is the precondition for 3c.)
[ "$(sopt beta status-right)" = "$SESSION_RIGHT" ] \
    || fail "setup: strip.sh wrote a status-right it does not own"

# --- 3b. uninstall restores the status line ---------------------------------
t2 run-shell "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.5

for s in alpha beta gamma; do
    [ -z "$(sopt "$s" status-left)" ] \
        || fail "$s still has a per-session status-left after uninstall: [$(sopt "$s" status-left)]"
    [ -z "$(sopt "$s" status-left-length)" ] \
        || fail "$s still has a per-session status-left-length after uninstall"
    [ "$(rendered "$s" status-left)" = "$GLOBAL_LEFT" ] \
        || fail "$s does not render the global status-left after uninstall: [$(rendered "$s" status-left)]"
done
pass "uninstall unsets status-left/-length on every session; the global shows through again"

# The strip's own debounce stamp is bookkeeping, not user state, and must not be
# left behind either.
[ -z "$(t2 show-option -gqv @sidetabs_strip_last_ms)" ] \
    || fail "the strip's debounce stamp survived uninstall"
pass "the plugin's own bookkeeping globals are cleared by uninstall"

# --- 3c. a status-right the plugin never owned is NOT touched ---------------
# This is the half that must NOT happen. Unsetting a side the plugin never wrote
# would destroy the user's own clock — the very content strip.sh measures and
# reserves rather than write over.
[ "$(sopt beta status-right)" = "$SESSION_RIGHT" ] \
    || fail "uninstall unset a session-scoped status-right the plugin never wrote: [$(sopt beta status-right)]"
[ "$(t2 show-option -gqv status-right)" = "$GLOBAL_RIGHT" ] \
    || fail "uninstall touched the global status-right"
[ "$(rendered alpha status-right)" = "$GLOBAL_RIGHT" ] \
    || fail "alpha no longer renders the user's own status-right after uninstall"
pass "a status-right the plugin never owned survives uninstall untouched"

# --- 3d. a status-right the plugin DID own is unset -------------------------
# Setting @sidetabs-strip-right-1 hands that side over, so from here it IS the
# plugin's to clear. Regenerating after the uninstall is fine: the hooks are
# gone but strip.sh still runs when invoked directly, which is exactly the
# "strip was live when you uninstalled" state this asserts on.
t2 set-option -g @sidetabs-strip-right-1 'RIGHT-PILL'
t2 run-shell "$PLUGIN_DIR/scripts/strip.sh force"
for s in alpha beta gamma; do
    case "$(sopt "$s" status-right)" in
        *RIGHT-PILL*) ;;
        *) fail "setup: $s has no plugin-generated status-right after handing the side over" ;;
    esac
    [ -n "$(sopt "$s" status-right-length)" ] \
        || fail "setup: $s has no generated status-right-length"
done

t2 run-shell "$PLUGIN_DIR/scripts/uninstall.sh"
sleep 0.5
for s in alpha beta gamma; do
    [ -z "$(sopt "$s" status-right)" ] \
        || fail "$s kept a plugin-owned status-right after uninstall: [$(sopt "$s" status-right)]"
    [ -z "$(sopt "$s" status-right-length)" ] \
        || fail "$s kept a plugin-owned status-right-length after uninstall"
    [ "$(rendered "$s" status-right)" = "$GLOBAL_RIGHT" ] \
        || fail "$s does not render the global status-right after uninstall: [$(rendered "$s" status-right)]"
done
pass "a status-right the plugin DID own is unset, so the global shows through there too"

echo "ALL UNINSTALL HOOK SMOKE TESTS PASSED"
