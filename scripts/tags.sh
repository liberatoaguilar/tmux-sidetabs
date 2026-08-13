#!/usr/bin/env bash
# Read-only reader for the tags file (@sidetabs-timer-tags-file, default
# DEFAULT_TIMER_TAGS_FILE — variables.sh). Format: tag<TAB>label<TAB>reset_day,
# one row per line; `#`-comment and blank lines are skipped. The file is
# written only by `aguilabs usage configure --sync` (temp+mv, note.sh:169-184
# style) and read only here — the CLI never reads it back, so this script must
# tolerate the file being absent, empty, mid-rewrite, or containing garbage
# rows (stale customers, malformed reset_day) without ever failing a timer
# interaction: every lookup below has a documented no-match fallback and no
# path can raise a nonzero exit from bad file content.
#
# Sourced lib, not executable. Callers must already have sourced variables.sh
# (DEFAULT_TIMER_TAGS_FILE) and helpers.sh (get_tmux_option) first — same
# assumption note.sh's own helpers make of their caller.

# tags_file -> path. Same option-with-default idiom as note.sh's store_path().
tags_file() {
    get_tmux_option '@sidetabs-timer-tags-file' "$DEFAULT_TIMER_TAGS_FILE"
}

# tag_label <tag> -> label from the first matching row, or empty when the tag
# has no row, the tag is untagged (`-`/empty), or the file is absent/unreadable.
tag_label() {
    local tag="$1" f
    f="$(tags_file)"
    [ -n "$tag" ] && [ "$tag" != "-" ] && [ -r "$f" ] || return 0
    awk -F'\t' -v t="$tag" \
        '!/^#/ && NF >= 2 && $1 == t { print $2; exit }' \
        "$f" 2>/dev/null
    return 0
}

# tags_list -> "tag<TAB>label" for every valid row, in file order, or nothing
# when the file is absent/unreadable/empty. C7's tag_picker.sh source of truth
# for the assign-client submenu; same no-crash-on-garbage contract as the
# lookups above (rows missing a label column are skipped, not errored).
tags_list() {
    local f
    f="$(tags_file)"
    [ -r "$f" ] || return 0
    awk -F'\t' '!/^#/ && NF >= 2 && $1 != "" { print $1 "\t" $2 }' "$f" 2>/dev/null
    return 0
}

# tag_reset_day <tag> -> reset_day (1-31) from the first matching row, or "0"
# ("never auto-reset") when the tag is missing/untagged, the file is
# absent/unreadable, or the stored value isn't a plain 0-31 integer.
tag_reset_day() {
    local tag="$1" f day n
    f="$(tags_file)"
    if [ -n "$tag" ] && [ "$tag" != "-" ] && [ -r "$f" ]; then
        day="$(awk -F'\t' -v t="$tag" \
            '!/^#/ && NF >= 3 && $1 == t { print $3; exit }' \
            "$f" 2>/dev/null)"
    fi
    case "$day" in
        ''|*[!0-9]*) echo 0; return 0 ;;
    esac
    n=$((10#$day))
    if [ "$n" -ge 1 ] && [ "$n" -le 31 ]; then echo "$n"; else echo 0; fi
}
