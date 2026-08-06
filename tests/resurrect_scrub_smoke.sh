#!/usr/bin/env bash
# Post-save scrub (resurrect_scrub.sh): sidebar strip lines in the resurrect
# save file must not leak the strip's cwd (the plugin dir) into the
# `new_session -c` / `new_window -c` that tmux-resurrect builds each window
# from, and must not stay recorded as the window's active pane. The scrub
# rewrites strip pane lines in place: cwd <- the window's first content pane's
# cwd (fallback $HOME), active flag <- moved to the first content pane.
# Everything else must pass through byte-identical.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOCKET="sidetab_scrub_$$"
D="${TMPDIR:-/tmp}/rez_scrub_$$"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$D"; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

mkdir -p "$D"
F="$D/tmux_resurrect_test.txt"
P=":$PLUGIN_DIR"    # cwd field exactly as resurrect writes it (leading colon)
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

# Save-file fields: pane session win_idx win_active :flags pane_idx title :cwd
# pane_active command :full_command
{
  # w0: strip is the ACTIVE pane (the reported bug) + two content panes
  row pane main 0 1 ':*' 0 host "$P"        1 bash ':sleep 5'
  row pane main 0 1 ':*' 1 tA   ':/proj/a'  0 zsh  ':'
  row pane main 0 1 ':*' 2 tB   ':/proj/b'  0 vim  ':vim .'
  # w1: strip NOT active; content pane already active
  row pane main 1 0 ':-' 0 host "$P"        0 bash ':(sleep)'
  row pane main 1 0 ':-' 1 tC   ':/proj/c'  1 zsh  ':'
  # w2: USER shell that happens to sit in the plugin dir at index 0 (no strip
  # in this window) — must be untouched (command is zsh, not the strip's bash)
  row pane main 2 0 ':-' 0 tD   "$P"        1 zsh  ':'
  # w3 (other session): strip-only window -> cwd falls back to $HOME
  row pane other 0 0 ':-' 0 host "$P"       1 bash ':sleep 5'
  # w4: NEW-style strip (created with -c $HOME) — still a strip, still scrubbed
  row pane main 4 0 ':-' 0 host ":$HOME"    1 bash ':sleep 5'
  row pane main 4 0 ':-' 1 tE   ':/proj/e'  0 zsh  ':'
  # w5: user bash parked at ~ in pane 0 of a sidebar-less window — full command
  # is the shell, not sleep/render -> untouched
  row pane main 5 0 ':-' 0 tF   ":$HOME"    1 bash ':-bash'
  # non-pane lines must survive byte-identical
  printf 'window\tmain\t0\t1\t:*\t64abc,200x50,0,0{20x50,0,0,1,179x50,21,0}\n'
  printf 'state\tmain\tmain\n'
  printf 'bash %s/scripts/render.sh\n' "$PLUGIN_DIR"
} > "$F"

cp "$F" "$F.orig"

# --- 1. Direct file-arg mode --------------------------------------------------
bash "$PLUGIN_DIR/scripts/resurrect_scrub.sh" "$F" || fail "scrub exited non-zero"

[ "$(wc -l < "$F")" = "$(wc -l < "$F.orig")" ] || fail "line count changed"

# w0 strip: cwd rewritten to first content pane's, active moved off
line="$(awk -F'\t' '$1=="pane" && $2=="main" && $3=="0" && $6=="0"' "$F")"
[ "$(echo "$line" | cut -f8)" = ":/proj/a" ] || fail "w0 strip cwd not rewritten: '$(echo "$line" | cut -f8)'"
[ "$(echo "$line" | cut -f9)" = "0" ] || fail "w0 strip still active"
[ "$(awk -F'\t' '$1=="pane" && $2=="main" && $3=="0" && $6=="1" {print $9}' "$F")" = "1" ] \
  || fail "w0 active flag not moved to first content pane"
[ "$(awk -F'\t' '$1=="pane" && $2=="main" && $3=="0" && $9=="1"' "$F" | wc -l | tr -d ' ')" = "1" ] \
  || fail "w0 does not have exactly one active pane"
pass "active strip: cwd rewritten, active moved to content pane"

# w1 strip: cwd rewritten, active flags untouched
line="$(awk -F'\t' '$1=="pane" && $2=="main" && $3=="1" && $6=="0"' "$F")"
[ "$(echo "$line" | cut -f8)" = ":/proj/c" ] || fail "w1 strip cwd not rewritten"
[ "$(echo "$line" | cut -f9)" = "0" ] || fail "w1 strip became active"
[ "$(awk -F'\t' '$1=="pane" && $2=="main" && $3=="1" && $6=="1" {print $9}' "$F")" = "1" ] \
  || fail "w1 content pane lost its active flag"
pass "inactive strip: cwd rewritten, active flags untouched"

# w2: user zsh in the plugin dir is NOT a strip -> byte-identical
diff <(awk -F'\t' '$1=="pane" && $3=="2"' "$F") <(awk -F'\t' '$1=="pane" && $3=="2"' "$F.orig") >/dev/null \
  || fail "user pane at plugin dir was modified"
pass "user pane in plugin dir untouched"

# w3: strip-only window falls back to $HOME, active cleared
line="$(awk -F'\t' '$1=="pane" && $2=="other"' "$F")"
[ "$(echo "$line" | cut -f8)" = ":$HOME" ] || fail "strip-only window cwd not \$HOME: '$(echo "$line" | cut -f8)'"
pass "strip-only window falls back to \$HOME"

# w4: new-style ($HOME-cwd) strip scrubbed like the old kind
line="$(awk -F'\t' '$1=="pane" && $2=="main" && $3=="4" && $6=="0"' "$F")"
[ "$(echo "$line" | cut -f8)" = ":/proj/e" ] || fail "home-cwd strip cwd not rewritten: '$(echo "$line" | cut -f8)'"
[ "$(echo "$line" | cut -f9)" = "0" ] || fail "home-cwd strip still active"
[ "$(awk -F'\t' '$1=="pane" && $2=="main" && $3=="4" && $6=="1" {print $9}' "$F")" = "1" ] \
  || fail "w4 active flag not moved to content pane"
pass "new-style (\$HOME-cwd) strip scrubbed too"

# w5: user bash at ~ (full command is the shell) untouched
diff <(awk -F'\t' '$1=="pane" && $3=="5"' "$F") <(awk -F'\t' '$1=="pane" && $3=="5"' "$F.orig") >/dev/null \
  || fail "user bash at ~ was modified"
pass "user bash at ~ untouched (full-command discriminator)"

# window/state/garbage lines byte-identical
for pat in '^window' '^state' '^bash '; do
  diff <(grep -E "$pat" "$F") <(grep -E "$pat" "$F.orig") >/dev/null \
    || fail "non-pane line matching '$pat' was modified"
done
pass "window/state/other lines byte-identical"

# --- 2. Hook mode (no arg): resolve @resurrect-dir, follow the `last` symlink,
# ---    scrub the target, keep the symlink a symlink --------------------------
cp "$F.orig" "$D/tmux_resurrect_hook.txt"
ln -sf "tmux_resurrect_hook.txt" "$D/last"
tmux -L "$SOCKET" -f /dev/null new-session -d -s hooktest -x 80 -y 24
tmux -L "$SOCKET" set -g @resurrect-dir "$D"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/resurrect_scrub.sh"
sleep 0.3
[ -L "$D/last" ] || fail "hook mode replaced the 'last' symlink with a file"
[ "$(awk -F'\t' '$1=="pane" && $2=="main" && $3=="0" && $6=="0" {print $8}' "$D/tmux_resurrect_hook.txt")" = ":/proj/a" ] \
  || fail "hook mode did not scrub the symlink target"
pass "hook mode: resolves @resurrect-dir/last symlink and scrubs the target"

echo "ALL RESURRECT SCRUB TESTS PASSED"
