#!/usr/bin/env bash
# C7 smoke test: the "assign client…" submenu (tag_picker.sh / tag_set.sh) and
# timer.sh's menu construction (shared ITEMS array; conditional register-repo
# item). Uses the --print seam throughout — an overlay menu never lands in
# capture-pane output (flag_picker.sh:7-9).
set -euo pipefail

SOCKET="sidetab_tagmenu_$$"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPLOG="${TMPDIR:-/tmp}/sidetabs_tagmenu_$$.tsv"
TMPTAGS="${TMPDIR:-/tmp}/sidetabs_tagmenu_tags_$$.tsv"
PICKOUT="${TMPDIR:-/tmp}/sidetabs_tagmenu_pick_$$.out"

cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -f "$TMPLOG" "$TMPTAGS" "$PICKOUT"; }
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
winopt() { tmux -L "$SOCKET" show-option -w -t "$1" -qv "$2"; }

# 1. Boot: 1 window, hermetic log + tags-file paths, no tags file yet.
tmux -L "$SOCKET" -f /dev/null new-session -d -s main -x 200 -y 50
tmux -L "$SOCKET" set-option -g @sidetabs-summary off
tmux -L "$SOCKET" set-option -g @sidetabs-timer-log "$TMPLOG"
tmux -L "$SOCKET" set-option -g @sidetabs-timer-tags-file "$TMPTAGS"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/sidetabs.tmux"
sleep 0.4
w0="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_id}' | sed -n 1p)"
[ -n "$w0" ] || fail "setup: expected a window"

# 2. tag_picker --print with no tags file: only the clear entry, marked
#    current (window is untagged), on key 0.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_picker.sh --print $w0 > $PICKOUT"
n="$(grep -c . "$PICKOUT" || true)"
[ "$n" = "1" ] || fail "tag_picker --print with no tags file: expected 1 item, got $n"
grep -q '^0	none	' "$PICKOUT" || fail "clear entry not on key 0: $(cat "$PICKOUT")"
grep -q '(current)' "$PICKOUT" || fail "clear entry not marked current on an untagged window"
pass "tag_picker --print with no tags file: only the clear entry"

# 3. Write a tags file (note.sh/timer_restore_smoke.sh convention: #-comment
#    header, tag<TAB>label<TAB>reset_day). Also throws in a blank line, to
#    confirm tags_list's `!/^#/` skip doesn't choke on one (a blank line has
#    NF==0, already excluded by the `$1 != ""` guard). tag_picker --print now
#    lists both real rows plus the clear entry, unique shortcut keys, no row
#    marked current — a stray 4th item would mean the comment or blank line
#    leaked through.
printf '# tag\tlabel\treset_day\n\ncust-A\tClient A\t15\ncust-B\tClient B\t1\n' > "$TMPTAGS"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_picker.sh --print $w0 > $PICKOUT"
n="$(grep -c . "$PICKOUT" || true)"
[ "$n" = "3" ] || fail "tag_picker --print: expected 3 items (2 tags + clear), got $n"
grep -q $'\tcust-A\tClient A$' "$PICKOUT" || fail "cust-A row missing/mislabeled: $(cat "$PICKOUT")"
grep -q $'\tcust-B\tClient B$' "$PICKOUT" || fail "cust-B row missing/mislabeled: $(cat "$PICKOUT")"
if awk -F'\t' '$2 != "none"' "$PICKOUT" | grep -q '(current)'; then
  fail "a tag row is marked current before any tag is assigned"
fi
nkeys="$(cut -f1 "$PICKOUT" | sort -u | grep -c . || true)"
[ "$nkeys" = "3" ] || fail "tag_picker shortcut keys not unique: $nkeys distinct of 3"
pass "tag_picker --print lists tags-file rows + clear entry, keys unique"

# 4. tag_set writes @sidetabs_timer_tag; tag_picker then marks that row (only
#    that row) as current.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 cust-A"
got="$(winopt "$w0" @sidetabs_timer_tag)"
[ "$got" = "cust-A" ] || fail "tag_set cust-A: expected cust-A, got '$got'"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_picker.sh --print $w0 > $PICKOUT"
awk -F'\t' '$2 == "cust-A"' "$PICKOUT" | grep -q '(current)' \
  || fail "tag_picker did not mark cust-A as current"
if awk -F'\t' '$2 != "cust-A"' "$PICKOUT" | grep -q '(current)'; then
  fail "tag_picker marked a non-current item as current"
fi
pass "tag_set assigns a tag; tag_picker marks it current"

# 5. tag_set clears the tag on "none".
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 none"
got="$(winopt "$w0" @sidetabs_timer_tag)"
[ -z "$got" ] || fail "tag_set none: expected unset, got '$got'"
pass "tag_set none clears the tag"

# 5b. Reassigning a window's tag clears the stale @sidetabs_timer_last_reset
#     marker: the OLD tag's last_reset must never be compared against the NEW
#     tag's cycle boundary (it could wrongly zero a total on relabel, or
#     wrongly skip a reset the new tag genuinely owes). Re-picking the SAME
#     tag (the menu marks it "(current)") is a deliberate no-op — an
#     unconditional unset would re-seed to "now" and swallow a due reset.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 cust-A"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"   # first sighting: seeds last_reset
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh reset $w0"
lr1="$(winopt "$w0" @sidetabs_timer_last_reset)"
[ -n "$lr1" ] || fail "last_reset not seeded on first tagged interaction"

tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 cust-A"   # same tag: must NOT unset
lr2="$(winopt "$w0" @sidetabs_timer_last_reset)"
[ "$lr2" = "$lr1" ] || fail "re-picking the same tag changed last_reset ($lr1 -> $lr2)"

tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 cust-B"   # different tag: must unset
lr3="$(winopt "$w0" @sidetabs_timer_last_reset)"
[ -z "$lr3" ] || fail "reassigning to a different tag left a stale last_reset: '$lr3'"
pass "tag reassignment clears last_reset; re-picking the same tag does not"

# 6. log_event picks up the live tag: after re-tagging and starting the
#    timer, the logged row's tag column (10th field) carries it.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 cust-B"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"
tag="$(grep -v '^#' "$TMPLOG" | tail -1 | cut -f10)"
[ "$tag" = "cust-B" ] || fail "logged tag: expected cust-B, got '$tag'"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh reset $w0"
pass "log_event carries the live tag into the event log"

# 6b. Retagging a window whose timer is RUNNING closes the open interval under
#     the OLD tag and reopens it under the NEW one. A tag change is an
#     attribution boundary: the CLI replay bills a whole interval to the tag it
#     OPENED under, so leaving one interval spanning the change billed every
#     second worked after the reassignment to the previous client — an inflated
#     row for A and a short row for B, with no warning on either side, because
#     the replay's late-tagging warning only fires when the opening label was
#     unattributable. Reassigning the window you are working in is the normal
#     C7 flow, and the interval is bounded only by the next focus change.
#     The rows must be auto-pause/auto-resume, never pause/resume: the restore
#     replay maps `pause` to a sticky manual pause, which would strand the
#     window unresumable if the server died between the two rows.
billable_for_tag() {
    awk -F'\t' -v t="$1" '!/^#/ && ($2=="pause" || $2=="auto-pause") && $10==t {s+=$4} END {print s+0}' "$TMPLOG"
}
rows_n() { grep -vc '^#' "$TMPLOG" || true; }

tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 cust-A"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"   # start, tagged cust-A
[ "$(winopt "$w0" @sidetabs_timer_state)" = "run" ] || fail "retag: expected a running timer"
sleep 2

before_rows="$(rows_n)"
start_before="$(winopt "$w0" @sidetabs_timer_start)"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 cust-B"
[ "$(winopt "$w0" @sidetabs_timer_tag)" = "cust-B" ] || fail "retag: tag not rewritten to cust-B"
[ "$(winopt "$w0" @sidetabs_timer_state)" = "run" ] \
    || fail "retag: the timer stopped running: '$(winopt "$w0" @sidetabs_timer_state)'"
[ "$(winopt "$w0" @sidetabs_timer_start)" != "$start_before" ] \
    || fail "retag: the live interval start was not reopened under the new tag"
[ "$(rows_n)" = "$((before_rows + 2))" ] \
    || fail "retag while running: expected exactly 2 new rows, got $(( $(rows_n) - before_rows ))"
pair="$(grep -v '^#' "$TMPLOG" | tail -2 | cut -f2,10 | tr '\n' ',' | tr '\t' '/')"
[ "$pair" = "auto-pause/cust-A,auto-resume/cust-B," ] \
    || fail "retag: expected auto-pause under the old tag then auto-resume under the new, got: $pair"
pass "retagging a running window closes the interval under the old tag and reopens under the new"

# Re-picking the SAME tag mid-interval stays a total no-op: no rows, and the
# live interval is NOT restarted (that would silently discard the seconds
# accrued since it opened).
before_rows="$(rows_n)"
start_before="$(winopt "$w0" @sidetabs_timer_start)"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 cust-B"
[ "$(rows_n)" = "$before_rows" ] || fail "retag: re-picking the same tag logged rows"
[ "$(winopt "$w0" @sidetabs_timer_start)" = "$start_before" ] \
    || fail "retag: re-picking the same tag restarted the live interval"

# Clearing the tag mid-interval is the same root cause: the post-clear seconds
# must land in the unattributed bucket (tag `-`) that C9/D5's global abort
# watches, not keep flowing to the old customer.
sleep 2
before_rows="$(rows_n)"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 none"
[ -z "$(winopt "$w0" @sidetabs_timer_tag)" ] || fail "retag none: tag not cleared"
[ "$(winopt "$w0" @sidetabs_timer_state)" = "run" ] \
    || fail "retag none: the timer stopped running: '$(winopt "$w0" @sidetabs_timer_state)'"
[ "$(rows_n)" = "$((before_rows + 2))" ] \
    || fail "retag none: expected exactly 2 new rows, got $(( $(rows_n) - before_rows ))"
pair="$(grep -v '^#' "$TMPLOG" | tail -2 | cut -f2,10 | tr '\n' ',' | tr '\t' '/')"
[ "$pair" = "auto-pause/cust-B,auto-resume/-," ] \
    || fail "retag none: expected auto-pause under cust-B then auto-resume untagged, got: $pair"
sleep 2
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh toggle $w0"   # close the last interval

# The billing invariant: each tag owns the seconds worked while it was assigned,
# and none owns the whole span.
for t in cust-A cust-B -; do
    [ "$(billable_for_tag "$t")" -ge 1 ] \
        || fail "retag: tag '$t' was billed no seconds at all: $(billable_for_tag "$t")"
done
pass "clearing a tag mid-interval sends the following seconds to the unattributed bucket"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/timer.sh reset $w0"

# 7. register_repo.sh guards, run IN-SERVER via run-shell (tmux propagates the
#    shell command's own exit status as run-shell's exit status — verified
#    empirically: a foreground run-shell is not fire-and-forget). Both guard
#    branches below must exit 0 — a bad window/PATH must never crash the
#    plugin — and NEITHER may reach the real `aguilabs` CLI: the untagged
#    case returns before the command -v check is even reached, and the second
#    case forces PATH to exclude it, so this test can never write to a real
#    customer's registry no matter what is installed on this machine.
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 none"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/register_repo.sh $w0" \
  || fail "register_repo.sh on an untagged window exited nonzero"
pass "register_repo.sh on an untagged window is a no-op (exit 0)"

# 8. Tagged, but `aguilabs` deliberately excluded from PATH: hits the
#    command -v guard and exits 0 without ever shelling out. register_repo.sh
#    itself still calls `tmux`, so the trimmed PATH must keep tmux's own bin
#    dir reachable (it may not be /usr/bin — e.g. Homebrew) while dropping
#    wherever `aguilabs` actually lives, so the guard is exercised for real.
TMUXBIN_DIR="$(dirname "$(command -v tmux)")"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 cust-A"
tmux -L "$SOCKET" run-shell "PATH='$TMUXBIN_DIR:/usr/bin:/bin' '$PLUGIN_DIR/scripts/register_repo.sh' $w0" \
  || fail "register_repo.sh without aguilabs on PATH exited nonzero"
pass "register_repo.sh degrades gracefully without the aguilabs CLI on PATH"

# 9. timer.sh's menu: the "register repo…" item is present only when the tags
#    file exists AND the window is tagged (SIDETABS_TIMER_MENU_PRINT seam —
#    an overlay menu never lands in capture-pane output). Tagged + tags file
#    present -> item shows up, labeled from the tags file. No tags file at all
#    -> absent even though the window is still tagged (keeps the plugin
#    generic for non-aguilabs users, C7).
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_set.sh $w0 cust-A"
tmux -L "$SOCKET" run-shell "SIDETABS_TIMER_MENU_PRINT=1 '$PLUGIN_DIR/scripts/timer.sh' menu $w0 > $PICKOUT"
grep -q 'register repo for Client A' "$PICKOUT" \
  || fail "register-repo item missing with tags file + tag present: $(cat "$PICKOUT")"
pass "register-repo item present when tagged and tags file exists"

mv "$TMPTAGS" "${TMPTAGS}.bak"
tmux -L "$SOCKET" run-shell "SIDETABS_TIMER_MENU_PRINT=1 '$PLUGIN_DIR/scripts/timer.sh' menu $w0 > $PICKOUT"
mv "${TMPTAGS}.bak" "$TMPTAGS"
grep -q 'register repo' "$PICKOUT" \
  && fail "register-repo item present with no tags file: $(cat "$PICKOUT")"
pass "register-repo item absent when the tags file does not exist"

# 10. A menu entry's third element is a tmux COMMAND string, which run-shell
#     re-parses with `sh -c` — it is NOT literal argv like the label and key.
#     A hand-edited or foreign-written tags row whose tag carries a space would
#     word-split there and tag_set.sh would take only its first word: the menu
#     shows one client while the log records a tag no customer owns, silently
#     misattributing every later interval with no error anywhere. `;`/`$(…)`
#     rows would execute outright. Such rows must be SKIPPED — never rewritten
#     into some other tag — while a well-formed C2 `uuid:uuid` tag still
#     round-trips. --print-items is the seam for the command element, the way
#     --print is for the label/key pair.
ITEMSOUT="${TMPDIR:-/tmp}/sidetabs_tagmenu_items_$$.out"
SRCCONF="${TMPDIR:-/tmp}/sidetabs_tagmenu_cmd_$$.conf"
SENTINEL="${TMPDIR:-/tmp}/sidetabs_tagmenu_pwned_$$"
trap 'cleanup; rm -f "$ITEMSOUT" "$SRCCONF" "$SENTINEL"' EXIT
rm -f "$SENTINEL"
UUIDTAG="27909867-8d0a-4764-9318-88ca1746b240:11111111-2222-3333-4444-555555555555"
# Single-quoted format string on purpose: `$(id)` must reach the file literally.
printf '# tag\tlabel\treset_day\n%s\tGood Client\t15\n27909867-8d0a 4764\tSpacey\t15\ncust-x;touch %s\tEvil\t1\n$(id)\tSubshell\t1\n' \
  "$UUIDTAG" "$SENTINEL" > "$TMPTAGS"
tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_picker.sh --print $w0 > $PICKOUT"
n="$(grep -c . "$PICKOUT" || true)"
[ "$n" = "2" ] || fail "unusable rows still pickable: expected 2 items (1 tag + clear), got $n: $(cat "$PICKOUT")"
grep -q "	${UUIDTAG}	Good Client" "$PICKOUT" || fail "well-formed uuid:uuid row rejected: $(cat "$PICKOUT")"
[ "$(sed -n 1p "$PICKOUT" | cut -f1)" = "1" ] || fail "a skipped row burned a shortcut key: $(cat "$PICKOUT")"
pass "tags rows that are not one safe sh word are skipped, not silently rewritten"

tmux -L "$SOCKET" run-shell "$PLUGIN_DIR/scripts/tag_picker.sh --print-items $w0 > $ITEMSOUT"
if grep -q ';' "$ITEMSOUT"; then
  fail "a menu command string carries a shell metacharacter: $(cat "$ITEMSOUT")"
fi
[ "$(grep -c . "$ITEMSOUT" || true)" = "2" ] || fail "--print-items and --print disagree on entry count"
idx=0
while IFS= read -r cmdline; do
  idx=$((idx + 1))
  want="$(sed -n "${idx}p" "$PICKOUT" | cut -f2)"
  printf '%s\n' "$cmdline" > "$SRCCONF"
  tmux -L "$SOCKET" source-file "$SRCCONF"   # the parser a chosen menu item goes through
  sleep 0.5
  got="$(winopt "$w0" @sidetabs_timer_tag)"
  if [ "$want" = "none" ]; then
    [ -z "$got" ] || fail "clear entry left a tag behind: '$got'"
  else
    [ "$got" = "$want" ] || fail "menu entry $idx wrote '$got' but displays '$want'"
  fi
done < "$ITEMSOUT"
[ ! -e "$SENTINEL" ] || fail "a tags-file row executed a command through the menu"
pass "every menu entry writes exactly the tag it displays; no row can execute"

echo "ALL TAG MENU SMOKE TESTS PASSED"
