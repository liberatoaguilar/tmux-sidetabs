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

cleanup() {
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -f "$MARKER_NEW" "$MARKER_RENAMED"
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

echo "ALL UNINSTALL HOOK SMOKE TESTS PASSED"
