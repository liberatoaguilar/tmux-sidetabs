#!/usr/bin/env bash
# "Assign client…" submenu: a display-menu listing every tag from the tags
# file (@sidetabs-timer-tags-file), one entry per row, plus an "untagged
# (clear)" entry. tmux 3.6b has no native nested display-menu, so this script
# IS the submenu — timer.sh's own menu opens it via a run-shell item (C7).
# Cloned structurally from flag_picker.sh.
# Usage: tag_picker.sh [--print|--print-items] [window_id] [client_name]
#   --print        emit the menu as "key<TAB>tag<TAB>label" lines instead of
#                  opening it — an overlay menu never lands in capture-pane
#                  output (flag_picker.sh:7-9), so this is the testable seam.
#   --print-items  emit each entry's tmux COMMAND string, one per line. The
#                  third menu element is the half that gets re-parsed (see
#                  below), so it needs a seam of its own.
set -euo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/tags.sh"

MODE="menu"
case "${1:-}" in
    --print)       MODE="print"; shift ;;
    --print-items) MODE="items"; shift ;;
esac

WID="${1:-$(tmux display-message -p '#{window_id}' 2>/dev/null)}"
CLIENT="${2:-}"
[ -z "$WID" ] && exit 0

TAB="$(printf '\t')"
# Menu shortcut keys, positionally, same convention as flag_picker.sh: "0" is
# reserved for the clear entry, so tag slots start at "1"; past 36 tags an
# entry simply has no shortcut and stays reachable with the arrow keys.
KEYCHARS="123456789abcdefghijklmnopqrstuvwxyz"

cur="$(get_window_option "$WID" "$TIMER_TAG_OPTION" "")"

# A menu entry is a triple of label, key and COMMAND. Only the first two are
# literal argv: the third is a tmux command string, and `run-shell` hands it
# to `sh -c` (refresh.sh:10-18 documents the same re-parse). A tags-file value
# interpolated there is therefore re-parsed by sh, so stripping quotes is not
# enough — a value with a SPACE word-splits, tag_set.sh takes only its first
# word ("${2:-}"), and the window is silently tagged to something no customer
# owns: the menu shows one thing and the log records another, which is a
# misattribution that no error surfaces anywhere. `;`, `$(…)` and backticks
# would execute outright. Hence the two fields are treated differently:
#
#   LABEL is literal argv — but argv POSITION 1 is still parsed by tmux with
#   getopt semantics that stop only at the first non-option argument, so a
#   first label beginning with `-` is eaten as flags and display-menu aborts
#   before the menu ever opens. Two symmetric hazards, then: the THIRD element
#   is re-parsed by sh, and the FIRST is re-parsed by getopt. sanitize() below
#   answers the former; the dash guard and the `--` at the call site answer the
#   latter.
#   TAG is checked against C2's alphabet with an ALLOWLIST, and a row that
#   fails is SKIPPED, never rewritten. Substituting a different tag for the
#   one the entry displays is precisely the failure being fixed, so a row that
#   cannot be represented must not be pickable at all. C4's "tolerate garbage
#   rows" contract is met by ignoring such a row, not by guessing at it.
sanitize() {
    printf '%s' "$1" | tr '\011' ' ' | tr -d '\000-\037' | tr -d "'" | tr -s ' '
}

ITEMS=()   # flat triples: label, key, command
PRINTED=""
i=0
while IFS="$TAB" read -r rawtag rawlabel; do
    [ -n "$rawtag" ] || continue
    tag="$(printf '%s' "$rawtag" | tr -d '\000-\037')"
    # Skipped BEFORE the key counter moves, so an unusable row does not burn a
    # shortcut and leave a gap in the menu.
    case "$tag" in
        ''|*[!A-Za-z0-9:._-]*) continue ;;
    esac
    i=$((i + 1))
    if [ "$i" -le 36 ]; then key="${KEYCHARS:$((i - 1)):1}"; else key=""; fi
    label="$(sanitize "$rawlabel")"
    [ -n "$label" ] || label="$tag"
    [ "$tag" = "$cur" ] && label="${label} (current)"
    # Dash guard, AFTER the fallback and the suffix so it sees the FINAL label:
    # the fallback can itself hand back a dash-leading label, because C2's tag
    # alphabet permits `-foo`. Rows are emitted sorted by tag, so the
    # lowest-sorting customer supplies argv position 1 and one dash-leading
    # label would abort the submenu for EVERY client — leaving windows
    # unassignable, i.e. logging untagged time, the C9 abort path. GUARD, not
    # skip: these rows are trusted data written by `usage configure --sync`, and
    # dropping one makes that customer unpickable, which is the failure being
    # fixed. One leading space costs a column of indent and keeps the operator's
    # label intact, where stripping the dash would show a name the CLI does not
    # have on file. The tag written by the entry is untouched either way.
    case "$label" in -*) label=" $label" ;; esac
    # Belt and braces: the allowlist above already guarantees a single sh word,
    # and the added quotes keep it one even if that alphabet is ever widened.
    # They are not a substitute for it — sh still expands `$`, backticks and
    # backslash inside double quotes, and the allowlist excludes all three.
    ITEMS+=("$label" "$key" "run-shell -b '$CURRENT_DIR/tag_set.sh $WID \"$tag\"'")
    PRINTED="${PRINTED}${key}${TAB}${tag}${TAB}${label}
"
done < <(tags_list)

clear_label="untagged (clear)"
{ [ -z "$cur" ] || [ "$cur" = "-" ]; } && clear_label="${clear_label} (current)"
ITEMS+=("$clear_label" "0" "run-shell -b '$CURRENT_DIR/tag_set.sh $WID none'")
PRINTED="${PRINTED}0${TAB}none${TAB}${clear_label}
"

if [ "$MODE" = "print" ]; then
    printf '%s' "$PRINTED"
    exit 0
fi

if [ "$MODE" = "items" ]; then
    i=2
    while [ "$i" -lt "${#ITEMS[@]}" ]; do
        printf '%s\n' "${ITEMS[$i]}"
        i=$((i + 3))
    done
    exit 0
fi

# `--` ends tmux's flag parsing (arguments.c args_parse_flags, present since
# well before the 3.4 floor), so no menu element can ever be read as a flag,
# including the clear entry and any future reordering of ITEMS. The per-label
# dash guard above stays as the version-independent belt.
if [ -n "$CLIENT" ]; then
    tmux display-menu -c "$CLIENT" -T ' assign client ' -- "${ITEMS[@]}"
else
    tmux display-menu -T ' assign client ' -- "${ITEMS[@]}"
fi
