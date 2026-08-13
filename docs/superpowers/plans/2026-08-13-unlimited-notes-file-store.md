# Unlimited-Length Notes (File-Per-Note Store) Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking. This
> plan is executed inline (no subagents) per the session's tooling constraints.

**Goal:** Remove the 200-character note cap entirely by moving note text out of
the tmux window option and into a file per note, so a note can be any length.

**Architecture:** The window option `@sidetabs_note` stops holding text and holds
an opaque **note id** (`n1-XXXXXXXX`). The text lives in its own file at
`"${store}.d/<id>"`, holding raw multi-line text with no escaping and no cap. The
TSV store keeps its `session \t window \t value` shape, with `value` now the id.
The sidebar's presence check (`#{!=:#{@sidetabs_note},}`) is unchanged, because
an id is non-empty exactly when a note exists. Legacy values (inline
escape-encoded text, written by the current release) are still readable and are
converted to a file on the next save.

**Tech Stack:** POSIX shell targeting **macOS bash 3.2**, tmux 3.x, BSD/GNU
`awk`/`sed`/`tr`, `mktemp`.

**Spec:** This document (design settled in-session; the user chose the
"unlimited (file-per-note)" option over raising the cap).

## Global Constraints

- **bash 3.2**: no associative arrays, no `${var^^}`, no `$'\uXXXX'`, `read -t`
  is integer-only. Existing scripts already obey this.
- **No text in any tmux command.** tmux rejects a command over ~16KB with
  `command too long` (bisected: 16,289 value bytes on tmux 3.6b). The limit is on
  **bytes**, not characters — 8,000 CJK chars is 24,000 bytes and fails. Since
  the option now holds only a ~11-character id, this ceiling becomes unreachable.
- **No text in any render format.** `render.sh:594` interpolates only the
  presence boolean. Do not change that.
- **`set -euo pipefail`** is in force in `note.sh`. Any command that may
  legitimately fail must be guarded (`|| true`, `if`, etc.) or it aborts the
  script — and the `EXIT` trap in `edit-popup` then deletes the user's editor
  buffer. This is the data-loss path the whole design must keep shut.
- **No text may enter the TSV store.** Rows stay exactly 3 tab-separated fields.
- **Sanitizing must scale.** The current `while read` accumulator is O(n²) in
  bash (measured: 50KB ≈ 1s, so 200KB ≈ 16s). All text processing must be done
  by a streaming pipeline (`tr`/`sed`/`awk`), never a bash accumulation loop.
- **Existing user data must survive.** The live store
  (`~/.local/share/tmux-sidetabs/notes.tsv`) has 6 real rows today, 2 of them at
  the 207-byte encoded cap. They must remain readable and editable.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `scripts/variables.sh` | Defaults + option names | Drop `NOTE_MAX_CHARS`; document the notes dir derivation |
| `scripts/note.sh` | All note state transitions | Rewrite storage layer: id in option, text in file, streaming sanitize, `gc` command |
| `scripts/render.sh` | Sidebar drawing | **No change** (presence-only already) |
| `scripts/resurrect_post.sh` | Post-restore hook | **No change** (already calls `note.sh restore`) |
| `tests/notes_smoke.sh` | Note behaviour under a live tmux | Rewrite the storage-shape assertions; add unlimited-length, legacy-migration, gc, and file-lifecycle sections |
| `README.md` | User docs | Update the notes rows in the options table and the Notes section |

### Note id format

`n1-` + 8 `mktemp` characters, e.g. `n1-Ab3xK9zQ`. Properties this buys:

- **Structurally recognizable**, so a legacy inline-text value can be told apart
  from an id without a version field in the store.
- **Created atomically** by `mktemp` in the notes dir, so two concurrent `set`s
  can never mint the same id.
- **Filesystem-safe** — validated to contain no `/` and only `[A-Za-z0-9]` after
  the prefix, so a hostile store row can never escape the notes dir.

### Directory layout

```
~/.local/share/tmux-sidetabs/
  notes.tsv                 # session \t window \t note-id
  notes.tsv.d/              # "${store}.d" — derived, moves with @sidetabs-note-store
    n1-Ab3xK9zQ             # raw note text, any length
    .stage-XXXXXXXX         # transient; mv'd into place, same filesystem
```

The dir is derived as `"${store}.d"` rather than `$(dirname store)/notes.d` so
that two different `@sidetabs-note-store` paths in one directory never share a
note pool (which would make `gc` delete the other store's notes).

### Why `gc` is explicit, not automatic

Orphan note files are a few KB of text; deleting a wanted note is unrecoverable.
The asymmetry says: never delete on a timer. `note.sh gc` is a command the user
runs. Normal operation produces almost no orphans anyway, because `apply_note`
**reuses** the window's existing id on overwrite instead of minting a new one.

---

### Task 1: Storage layer — id in the option, text in a file

**Files:**
- Modify: `scripts/variables.sh:114-121`
- Modify: `scripts/note.sh` (header comment, lines 1-20; storage helpers 31-62;
  `sanitize_note` 71-114; `apply_note` 189-201; `edit-popup` 219-238; `restore` 240-266)
- Test: `tests/notes_smoke.sh`

**Interfaces produced** (later tasks rely on these exact names):
- `notes_dir()` → echoes `"${store}.d"`
- `valid_id <value>` → exit 0 if the value is a well-formed note id
- `note_path <id>` → echoes the absolute path of that note's text file
- `new_id` → sets global `NEW_ID`, having atomically created the empty file
- `sanitize_file <in> <out>` → streaming sanitize, no cap
- `seed_file <value> <out>` → writes the note's current text (id → file copy;
  legacy → decoded inline text) to `<out>`
- `apply_note <window_id> <srcfile>` → **signature change**: takes a FILE, not a
  text argument, so no note text is ever held in a shell variable

- [ ] **Step 1: Update the failing test first — storage shape**

In `tests/notes_smoke.sh`, replace section 3's assertions (lines 59-67). The
option must now hold an id, and the TEXT must be in the file:

```bash
got="$(winopt "$w0" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "option is not a note id: '$got'" ;; esac
NDIR="$STORE.d"
[ -f "$NDIR/$got" ] || fail "note file $NDIR/$got missing"
# Tabs and indentation are now PRESERVED; only control chars die.
[ "$(cat "$NDIR/$got")" = "$(printf '  first\tsecondthird    fourth')" ] \
  || fail "note file content wrong: [$(cat "$NDIR/$got")]"
nf="$(awk -F'\t' '{print NF}' "$STORE" | sort -u)"
[ "$nf" = "3" ] || fail "expected 3 TSV fields on every store row, got: $nf"
awk -F'\t' -v id="$got" '$1=="main" && $2=="alpha" && $3==id' "$STORE" | grep -q . \
  || fail "store row does not reference the note id: $(cat "$STORE")"
```

Also change the driver at line 54 to keep the trailing-space trim meaningful:

```bash
exec "$PLUGIN_DIR/scripts/note.sh" set "$w0" \$'  first\tsecond\x01third    fourth  '
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./tests/notes_smoke.sh`
Expected: FAIL at section 3 — `option is not a note id: 'first secondthird fourth'`

- [ ] **Step 3: Rewrite the storage helpers in `note.sh`**

Replace `store_path` (line 31) and the `encode_note` block (lines 33-42) with:

```bash
store_path() { get_tmux_option '@sidetabs-note-store' "$DEFAULT_NOTE_STORE"; }

# Text lives one file per note, in a directory derived from the store path so
# both move together when @sidetabs-note-store is repointed. Deriving it from
# the store PATH (not its dirname) keeps two stores in one directory from
# sharing a note pool, which `gc` would resolve by deleting the other's files.
notes_dir() { printf '%s.d' "$(store_path)"; }
note_path() { printf '%s/%s' "$(notes_dir)" "$1"; }

# A note id is the option's whole value and a bare filename. The character
# class is the security boundary: it admits no '/' and no '..', so a hostile
# store row can never point note_path outside the notes dir. The n1- prefix is
# what lets a legacy inline-text value be recognized without a version field.
valid_id() {
    case "$1" in
        n1-*[!A-Za-z0-9]*) return 1 ;;
        n1-?*)             return 0 ;;
        *)                 return 1 ;;
    esac
}

# new_id -> NEW_ID, with the (empty) file already created. mktemp is what makes
# minting atomic: two concurrent sets can never agree on the same id.
new_id() {
    local d f
    NEW_ID=""
    d="$(notes_dir)"
    mkdir -p "$d" 2>/dev/null || return 1
    f="$(mktemp "$d/n1-XXXXXXXX" 2>/dev/null)" || return 1
    case "${f##*/}" in
        n1-*[!A-Za-z0-9]*) rm -f "$f" 2>/dev/null; return 1 ;;
    esac
    NEW_ID="${f##*/}"
    return 0
}
```

Keep `decode_note` (lines 44-62) exactly as it is — it is now used **only** to
read legacy inline values. Update its comment to say so.

- [ ] **Step 4: Replace `sanitize_note` with a streaming `sanitize_file`**

Delete `sanitize_note` (lines 64-114) and put this in its place:

```bash
# sanitize_file <in> <out>: normalize a raw editor buffer into the durable form.
# Everything is streamed — the old bash accumulation loop was O(n^2) (50KB took
# a second, 200KB would take ~16), and notes are now unbounded.
#
# Stage order matters. NULs die FIRST, because a NUL reaching sed truncates the
# line on BSD. CR is deliberately spared by that pass so the next two can tell
# CRLF (strip the CR) from a lone CR (a line break in its own right) — deleting
# CR outright would silently join the lines of an old-Mac file.
#
# Kept, unlike the pre-file implementation: TABS and LEADING whitespace, because
# a long note holds indented lists and code, and nothing downstream is
# whitespace-sensitive any more (the text no longer passes through the TSV store
# or a render format). Interior blank runs are kept verbatim for the same
# reason; the old squeeze existed to stop a 200-char budget being padded out.
# The trailing `|| :` is load-bearing, not decoration. Under `set -euo pipefail`
# a non-zero exit from ANY stage (ENOSPC writing <out> is the realistic one)
# fires errexit before the `return 0` below is ever reached — which kills the
# script inside edit-popup, whose EXIT trap then deletes the user's editor
# buffer. Swallowing the status turns a failed save into an empty stage file,
# which apply_note reads as "no change worth making" and leaves the note alone.
sanitize_file() {
    tr -d '\000-\010\013-\014\016-\037\177' < "$1" 2>/dev/null \
        | sed -e 's/'$'\r''$//' 2>/dev/null \
        | tr '\015' '\012' 2>/dev/null \
        | awk '
            # Trailing whitespace goes; leading whitespace stays.
            { sub(/[[:space:]]+$/, "") }
            $0 == "" { if (started) pending++; next }
            { while (pending > 0) { print ""; pending-- }
              started = 1; print }
          ' > "$2" 2>/dev/null || :
    return 0
}
```

Note what the awk does at the ends: blank lines before the first real line are
never counted (`started` is still 0), and blank lines after the last real line
sit in `pending` and are never flushed — so leading and trailing blank lines are
both dropped without a second pass.

- [ ] **Step 5: Add `seed_file` and rewrite `apply_note`**

Replace `apply_note` (lines 186-201) with:

```bash
# seed_file <option value> <out>: write the note's CURRENT text to <out>.
# An id reads its file; anything else is a legacy inline value from before
# notes moved to files, and is decoded in place. That legacy branch is the
# whole migration story — the value converts to a file the next time it is
# saved, so no eager migration pass is needed.
seed_file() {
    local v="$1" out="$2" p
    : > "$out" 2>/dev/null || return 0
    [ -n "$v" ] || return 0
    if valid_id "$v"; then
        p="$(note_path "$v")"
        [ -f "$p" ] && { cat "$p" > "$out" 2>/dev/null || true; }
    else
        decode_note "$v"
        printf '%s\n' "$DEC" > "$out" 2>/dev/null || true
    fi
    return 0
}

# apply_note <window_id> <srcfile>: the shared set/clear body. Takes a FILE,
# never a string, so note text is never held in a shell variable and never
# reaches a tmux command line.
#
# An empty result after sanitizing is a clear — "set it to nothing" and "clear
# it" are the same user intent, and it is the only sane reading of an emptied
# editor buffer.
#
# The window's EXISTING id is reused on overwrite. That keeps the option value
# stable, makes the write a single atomic rename, and means routine editing
# produces no orphan files at all.
apply_note() {
    local wid="$1" src="$2" cur id d stage
    d="$(notes_dir)"
    mkdir -p "$d" 2>/dev/null || return 0
    # Stage inside the notes dir so the mv below is same-filesystem, hence
    # atomic: a reader never sees a half-written note.
    stage="$(mktemp "$d/.stage-XXXXXXXX" 2>/dev/null)" || return 0
    sanitize_file "$src" "$stage"
    window_key "$wid"
    cur="$(get_window_option "$wid" "$NOTE_OPTION" "")"
    if [ ! -s "$stage" ]; then
        rm -f "$stage" 2>/dev/null
        valid_id "$cur" && rm -f "$(note_path "$cur")" 2>/dev/null
        unset_window_option "$wid" "$NOTE_OPTION"
        [ -n "$WNAME" ] && store_write "$SNAME" "$WNAME"
    else
        if valid_id "$cur"; then
            id="$cur"
        else
            new_id || { rm -f "$stage" 2>/dev/null; return 0; }
            id="$NEW_ID"
        fi
        mv "$stage" "$(note_path "$id")" 2>/dev/null \
            || { rm -f "$stage" 2>/dev/null; return 0; }
        set_window_option "$wid" "$NOTE_OPTION" "$id"
        [ -n "$WNAME" ] && store_write "$SNAME" "$WNAME" "$id"
    fi
    "$CURRENT_DIR/refresh.sh" force
}
```

- [ ] **Step 6: Rewrite the `set`, `clear` and `edit-popup` arms**

`set` and `clear` must now hand `apply_note` a file:

```bash
set)
    WID="${2:-}"
    [ -z "$WID" ] && WID="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
    [ -z "$WID" ] && exit 0
    shift 2 2>/dev/null || shift $#
    SRC="$(mktemp "${TMPDIR:-/tmp}/sidetabs_noteset.XXXXXX")" || exit 0
    trap 'rm -f "$SRC" 2>/dev/null' EXIT INT TERM HUP
    printf '%s\n' "$*" > "$SRC"
    apply_note "$WID" "$SRC"
    ;;

clear)
    WID="${2:-}"
    [ -z "$WID" ] && WID="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
    [ -z "$WID" ] && exit 0
    SRC="$(mktemp "${TMPDIR:-/tmp}/sidetabs_noteclr.XXXXXX")" || exit 0
    trap 'rm -f "$SRC" 2>/dev/null' EXIT INT TERM HUP
    : > "$SRC"
    apply_note "$WID" "$SRC"
    ;;
```

`edit-popup` seeds from `seed_file` instead of decoding inline:

```bash
edit-popup)
    WID="${2:-}"
    [ -z "$WID" ] && WID="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
    [ -z "$WID" ] && exit 0
    TMPF="$(mktemp "${TMPDIR:-/tmp}/sidetabs_note.XXXXXX")" || exit 0
    trap 'rm -f "$TMPF" 2>/dev/null' EXIT INT TERM HUP
    seed_file "$(get_window_option "$WID" "$NOTE_OPTION" "")" "$TMPF"
    ED="${EDITOR:-${VISUAL:-vi}}"
    # Unquoted so an EDITOR carrying flags ("code -w") still works.
    $ED "$TMPF" || true
    apply_note "$WID" "$TMPF"
    ;;
```

- [ ] **Step 7: Teach `restore` to skip a dangling id**

In the `restore` arm, after `[ -n "$note" ] || continue` (line 255), add:

```bash
        # A row pointing at a deleted note file would set the option and light
        # the row's glyph for a note with no text. Drop it instead.
        if valid_id "$note" && [ ! -f "$(note_path "$note")" ]; then
            continue
        fi
```

Everything else in `restore` is unchanged: the value it copies into the option
is now an id for new notes and legacy inline text for old rows, and both are
correct as-is.

- [ ] **Step 8: Drop the cap from `variables.sh`**

Replace lines 114-121:

```bash
# Notes. Unlike flags/timers the note text is durable on its own: every
# set/clear writes through to a TSV store keyed by (session name, window name),
# which note.sh restore replays after a server restart. The row glyph is
# presence-only — the text itself is never interpolated into a render format.
#
# The store holds a note ID; the text lives in its own file under
# "${store}.d/<id>". That indirection is what makes a note UNBOUNDED: tmux
# refuses any command over ~16KB ("command too long", measured in BYTES, so a
# CJK note hits it three times sooner), which capped a text-in-the-option note
# no matter how the cap was tuned. An id is ~11 characters, so the ceiling is
# gone. Run `note.sh gc` to sweep note files no store row or live window
# references.
DEFAULT_NOTE_KEY="M-n"
DEFAULT_NOTE_ICON=$'\xef\x89\x89'   # U+F249 nerd-font sticky-note
DEFAULT_NOTE_STORE="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-sidetabs/notes.tsv"
```

- [ ] **Step 9: Update the `note.sh` header comment**

Replace lines 1-20 so the file's contract statement matches reality: the option
holds an id, the text file is unbounded, escaping survives only to read legacy
values, and `gc` exists.

- [ ] **Step 10: Run the test**

Run: `./tests/notes_smoke.sh`
Expected: section 3 PASSes. Later sections still fail — they assert the old
encoded-text shape and are rewritten in Task 3.

- [ ] **Step 11: Commit**

```bash
git add scripts/note.sh scripts/variables.sh tests/notes_smoke.sh
git commit -m "feat(notes): store note text in a file per note, id in the option"
```

---

### Task 2: `gc` — sweep unreferenced note files

**Files:**
- Modify: `scripts/note.sh` (new `gc` case arm, and its entry in the usage comment)
- Test: `tests/notes_smoke.sh` (new section)

**Interfaces:**
- Consumes: `notes_dir`, `note_path`, `valid_id`, `store_path` from Task 1
- Produces: `note.sh gc` — prints `removed N orphaned note file(s)`

- [ ] **Step 1: Write the failing test**

Add to `tests/notes_smoke.sh`, before the uninstall section:

```bash
# --- 21. gc removes only unreferenced note files ----------------------------
# An orphan is a file no store row AND no live window option points at. A file
# that either one references must survive, and gc must never touch the staging
# files a concurrent save is using.
NDIR="$STORE.d"
tmux -L "$SOCKET" new-window -n gckeep; sleep 0.4
wg="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="gckeep"{print $2}')"
[ -n "$wg" ] || fail "setup: gckeep window missing"
run "$PLUGIN_DIR/scripts/note.sh set $wg keep me"
sleep 0.4
keep_id="$(winopt "$wg" @sidetabs_note)"
valid_keep=0; case "$keep_id" in n1-[A-Za-z0-9]*) valid_keep=1 ;; esac
[ "$valid_keep" = "1" ] || fail "setup: gckeep has no note id"

# A file nothing references.
orphan="$NDIR/n1-orphan01"
printf 'nobody points at me\n' > "$orphan"
# A file only the STORE references (its window is gone) must also survive.
storeonly="$NDIR/n1-storeonly"
printf 'the store still knows me\n' > "$storeonly"
printf 'main%sdeparted%sn1-storeonly\n' "$TAB" "$TAB" >> "$STORE"

run "$PLUGIN_DIR/scripts/note.sh gc"
sleep 0.4
[ ! -f "$orphan" ] || fail "gc did not remove the orphaned note file"
[ -f "$storeonly" ] || fail "gc removed a file the store still references"
[ -f "$NDIR/$keep_id" ] || fail "gc removed a file a live window references"
pass "gc removes only note files nothing references"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./tests/notes_smoke.sh`
Expected: FAIL — `gc did not remove the orphaned note file` (the `gc` arm does
not exist yet, so `note.sh gc` falls through the `case` and does nothing).

- [ ] **Step 3: Implement the `gc` arm**

Add before the closing `esac`:

```bash
gc)
    # Sweep note files that neither the durable store nor any live window
    # points at. Deliberately a COMMAND, never a timer: an orphan costs a few
    # KB, while deleting a wanted note is unrecoverable, and routine editing
    # produces no orphans anyway because apply_note reuses a window's id.
    #
    # The reference set is the union of both sources, because either one alone
    # is incomplete: a window renamed since its note was set is referenced only
    # by the live option (its row sits under the old name), and a note whose
    # window is gone is referenced only by the store.
    NDIR="$(notes_dir)"
    [ -d "$NDIR" ] || exit 0
    STORE="$(store_path)"
    REFS="$US"
    if [ -f "$STORE" ]; then
        while IFS= read -r id; do
            [ -n "$id" ] && REFS="${REFS}${id}${US}"
        done <<< "$(awk -F"$TAB" 'NF>=3 && $3 != "" { print $3 }' "$STORE" 2>/dev/null)"
    fi
    while IFS= read -r id; do
        [ -n "$id" ] && REFS="${REFS}${id}${US}"
    done <<< "$(tmux list-windows -a -F "#{${NOTE_OPTION}}" 2>/dev/null)"
    removed=0
    for f in "$NDIR"/n1-*; do
        [ -f "$f" ] || continue
        id="${f##*/}"
        valid_id "$id" || continue
        case "$REFS" in *"${US}${id}${US}"*) continue ;; esac
        rm -f "$f" 2>/dev/null && removed=$((removed + 1))
    done
    # Staging files are transient; one older than a day is the debris of a save
    # that was killed mid-write. The age guard is what keeps this from racing a
    # save that is in flight right now.
    find "$NDIR" -maxdepth 1 -name '.stage-*' -type f -mtime +1 -exec rm -f {} \; 2>/dev/null || true
    echo "removed $removed orphaned note file(s)"
    ;;
```

- [ ] **Step 4: Run the test**

Run: `./tests/notes_smoke.sh`
Expected: section 21 PASSes.

- [ ] **Step 5: Commit**

```bash
git add scripts/note.sh tests/notes_smoke.sh
git commit -m "feat(notes): add note.sh gc to sweep unreferenced note files"
```

---

### Task 3: Rewrite the storage-shape test sections

**Files:**
- Modify: `tests/notes_smoke.sh` sections 4, 12, 15, 16, 17, 18, 19

**Interfaces:**
- Consumes: everything from Tasks 1-2. No production code changes in this task —
  if a section fails here, the bug is in Task 1's implementation, not the test.

- [ ] **Step 1: Section 4 — the cap is gone**

Replace the whole "200-char cap" section with an unbounded round-trip. 200KB is
chosen because it is >12x the tmux command ceiling that made the old cap
necessary, so a regression to text-in-the-option cannot pass this:

```bash
# --- 4. No length cap: a 200KB note round-trips intact ----------------------
# The old 200-char cap existed because the text lived in a tmux option, and
# tmux refuses a command over ~16KB. With the text in its own file there is no
# ceiling, and this note is >12x that limit.
BIG="$WORK/big.txt"
awk 'BEGIN { for (i = 1; i <= 5000; i++) printf "line %05d padded out to fifty characters ok\n", i }' > "$BIG"
bigbytes="$(wc -c < "$BIG" | tr -d ' ')"
[ "$bigbytes" -gt 200000 ] || fail "setup: big note is only $bigbytes bytes"
ED_BIG="$WORK/ed_big.sh"
cat > "$ED_BIG" <<EOF
#!/usr/bin/env bash
cp "$BIG" "\$1"
EOF
chmod +x "$ED_BIG"
run "EDITOR=$ED_BIG $PLUGIN_DIR/scripts/note.sh edit-popup $w1"
sleep 1
got="$(winopt "$w1" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "big note: option is not an id: '$got'" ;; esac
NDIR="$STORE.d"
[ -f "$NDIR/$got" ] || fail "big note file missing"
cmp -s "$BIG" "$NDIR/$got" || fail "200KB note did not round-trip byte-for-byte"
[ "$(storerows)" = "2" ] || fail "expected 2 store rows, got $(storerows)"
# And the editor gets all of it back.
rm -f "$CAP_EARLY"
run "EDITOR=$ED_CAPTURE_EARLY $PLUGIN_DIR/scripts/note.sh edit-popup $w1"
sleep 1
cmp -s "$BIG" "$CAP_EARLY" || fail "editor was not re-seeded with the full 200KB note"
pass "a 200KB note round-trips with no cap"
```

This needs the capture editor earlier than section 15 defines it, so move its
definition up to just below the `pass` of section 3, naming it
`ED_CAPTURE_EARLY` / `CAP_EARLY`:

```bash
CAP_EARLY="$WORK/captured_early.txt"
ED_CAPTURE_EARLY="$WORK/ed_capture_early.sh"
cat > "$ED_CAPTURE_EARLY" <<EOF
#!/usr/bin/env bash
cp "\$1" "$CAP_EARLY"
EOF
chmod +x "$ED_CAPTURE_EARLY"
```

- [ ] **Step 2: Sections 9 and 10 — they compare the option to text too**

Both sections predate the id and assert `winopt == <the note text>`.

Section 9, at lines 132-133 and 142, becomes a shape check plus a content check:

```bash
got="$(winopt "$w0" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "edit-popup did not store an id: '$got'" ;; esac
[ "$(cat "$STORE.d/$got")" = "note from the editor" ] \
  || fail "edit-popup EDITOR write: [$(cat "$STORE.d/$got")]"
[ "$(storerows)" = "1" ] || fail "edit-popup write: expected 1 store row, got $(storerows)"
edit_id="$got"
```

and the no-op-editor assertion at line 142 becomes:

```bash
[ "$(winopt "$w0" @sidetabs_note)" = "$edit_id" ] || fail "no-op editor lost the note"
[ "$(cat "$STORE.d/$edit_id")" = "note from the editor" ] || fail "no-op editor changed the text"
```

Section 10 sets a live note through the new `set` path, so capture its id at
line 162 and compare against that at line 174:

```bash
run "$PLUGIN_DIR/scripts/note.sh set $w0 live note wins"
sleep 0.3
live_id="$(winopt "$w0" @sidetabs_note)"
case "$live_id" in n1-[A-Za-z0-9]*) : ;; *) fail "setup: live note not set" ;; esac
[ "$(cat "$STORE.d/$live_id")" = "live note wins" ] || fail "setup: live note text wrong"
```

```bash
[ "$(winopt "$w0" @sidetabs_note)" = "$live_id" ] \
  || fail "restore clobbered a live note: '$(winopt "$w0" @sidetabs_note)'"
```

Leave lines 175-178 alone. Those rows are hand-written plain text, so restore
copies them into the option verbatim through the legacy path — which is
correct behaviour and free extra coverage of it.

- [ ] **Step 3: Section 12 — a note whose TEXT is "0"**

The option can no longer be the literal `0` (it is always an id), but the
underlying hazard is worth keeping under test. Change the two assertions:

```bash
got="$(winopt "$w0" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "note '0' not stored as an id: '$got'" ;; esac
[ "$(cat "$STORE.d/$got")" = "0" ] || fail "note text '0' not stored"
awk -F'\t' -v id="$got" '$2=="alpha" && $3==id' "$STORE" | grep -q . || fail "store row for note '0' missing"
```

The glyph assertion below it is unchanged and still meaningful.

- [ ] **Step 4: Sections 15-17 — the stored form is a file now**

Section 15's premise ("the stored form must stay single-line") is obsolete. Keep
the round-trip, drop the encoding assertions:

```bash
got="$(winopt "$wm" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "multi-line note: option is not an id: '$got'" ;; esac
[ "$(cat "$STORE.d/$got")" = "$(printf 'line1\n\nline3')" ] \
  || fail "multi-line note file wrong: [$(cat "$STORE.d/$got")]"
nf="$(awk -F'\t' 'NF{print NF}' "$STORE" | sort -u)"
[ "$nf" = "3" ] || fail "store rows are not all 3 TSV fields after a multi-line note: $nf"
```

Section 16 (`a\nb` stays literal) keeps its editor round-trip assertions but
drops the `'a\\nb'` option checks — with a file there is no escaping to corrupt,
which is the point. Replace the two `winopt` assertions with:

```bash
got="$(winopt "$wb" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "backslash note: option is not an id" ;; esac
[ "$(cat "$STORE.d/$got")" = 'a\nb' ] || fail "literal backslash-n not stored verbatim"
```

Section 17 (restore re-seeds) keeps its shape; change the expected option value
from `'line1\n\nline3'` to the id captured in section 15. Capture it there into
`multi_id="$got"` and assert `[ "$(winopt "$wm" @sidetabs_note)" = "$multi_id" ]`.

- [ ] **Step 5: Section 18 — sanitizing preserves indentation and tabs**

This is the behaviour change with the widest blast radius, so assert it
directly. Replace the section's expectations:

```bash
ED_DIRTY="$WORK/ed_dirty.sh"
cat > "$ED_DIRTY" <<'EOF'
#!/usr/bin/env bash
printf '%s' $'\n\n  first\tsecond\x01third   fourth  \n\n  keep  \n\n\n\ntail\n\n\n' > "$1"
EOF
chmod +x "$ED_DIRTY"
tmux -L "$SOCKET" new-window -n dirty; sleep 0.4
wdy="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="dirty"{print $2}')"
[ -n "$wdy" ] || fail "setup: dirty window missing"
run "EDITOR=$ED_DIRTY $PLUGIN_DIR/scripts/note.sh edit-popup $wdy"
sleep 0.4
got="$(winopt "$wdy" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "dirty note: option is not an id" ;; esac
# Control chars die; leading whitespace, tabs, interior space runs and blank
# runs all SURVIVE now; trailing whitespace and edge blank lines still go.
want="$(printf '  first\tsecondthird   fourth\n\n  keep\n\n\n\ntail')"
[ "$(cat "$STORE.d/$got")" = "$want" ] || fail "sanitize: got [$(cat "$STORE.d/$got")]"
pass "sanitize drops control chars and trailing space, keeps indentation, tabs and blank runs"
```

- [ ] **Step 6: Section 19 — replaced by the new section 4**

Delete section 19 entirely (the decoded-text cap no longer exists) and renumber
the uninstall section's comment to 20.

- [ ] **Step 7: Run the whole suite**

Run: `./tests/notes_smoke.sh`
Expected: `ALL NOTES SMOKE TESTS PASSED`

- [ ] **Step 8: Commit**

```bash
git add tests/notes_smoke.sh
git commit -m "test(notes): assert the file-per-note storage shape and unbounded length"
```

---

### Task 4: Legacy-value compatibility test

**Files:**
- Modify: `tests/notes_smoke.sh` (new section)

**Interfaces:**
- Consumes: `seed_file`'s legacy branch and `apply_note`'s convert-on-save from
  Task 1.

This task exists on its own because the user's real store has 6 rows written by
the current release, and losing them is the single worst outcome of this change.

- [ ] **Step 1: Write the failing test**

```bash
# --- 22. Legacy inline notes still open, and convert on save ----------------
# Rows written before notes moved to files hold escape-encoded TEXT, not an id.
# They must still open in the editor with their newlines intact, and saving must
# migrate them to a file without the user doing anything.
tmux -L "$SOCKET" new-window -n legacy; sleep 0.4
wl="$(tmux -L "$SOCKET" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="legacy"{print $2}')"
[ -n "$wl" ] || fail "setup: legacy window missing"
tmux -L "$SOCKET" set-option -w -t "$wl" @sidetabs_note 'old1\nold2\\nliteral'
printf 'main%slegacy%sold1\\nold2\\\\nliteral\n' "$TAB" "$TAB" >> "$STORE"

rm -f "$CAP_EARLY"
run "EDITOR=$ED_CAPTURE_EARLY $PLUGIN_DIR/scripts/note.sh edit-popup $wl"
sleep 0.5
[ -f "$CAP_EARLY" ] || fail "legacy note: capture editor never ran"
[ "$(cat "$CAP_EARLY")" = "$(printf 'old1\nold2\\nliteral')" ] \
  || fail "legacy note did not decode into the editor: [$(cat "$CAP_EARLY")]"
# Re-saving the seeded buffer converts it to a file, unchanged.
got="$(winopt "$wl" @sidetabs_note)"
case "$got" in n1-[A-Za-z0-9]*) : ;; *) fail "legacy note did not convert to an id: '$got'" ;; esac
[ "$(cat "$STORE.d/$got")" = "$(printf 'old1\nold2\\nliteral')" ] \
  || fail "legacy conversion changed the text: [$(cat "$STORE.d/$got")]"
awk -F'\t' -v id="$got" '$2=="legacy" && $3==id' "$STORE" | grep -q . \
  || fail "legacy store row was not rewritten to the note id"
pass "legacy inline notes open correctly and migrate to a file on save"
```

- [ ] **Step 2: Run it**

Run: `./tests/notes_smoke.sh`
Expected: PASS if Task 1 Step 5's `seed_file` legacy branch is right. A failure
here means the legacy branch is wrong — fix `note.sh`, not the test.

- [ ] **Step 3: Verify against the user's real data, read-only**

```bash
cp -a "${XDG_DATA_HOME:-$HOME/.local/share}/tmux-sidetabs/notes.tsv" \
      "${TMPDIR:-/tmp}/notes-real-copy.tsv"
awk -F'\t' '{ printf "%s | %s | %d bytes | id? %s\n", $1, $2, length($3), ($3 ~ /^n1-[A-Za-z0-9]+$/ ? "yes" : "no (legacy, decodes on open)") }' \
      "${TMPDIR:-/tmp}/notes-real-copy.tsv"
```

Expected: all 6 rows report `no (legacy, decodes on open)`. Confirms they take
the compatibility path rather than being mistaken for ids. Do not modify the
real store.

- [ ] **Step 4: Commit**

```bash
git add tests/notes_smoke.sh
git commit -m "test(notes): cover legacy inline notes decoding and converting on save"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md:114-116` (options table), `README.md:333-347` (Notes section)

- [ ] **Step 1: Update the options table rows**

`@sidetabs-note-store`'s description no longer describes escaped newlines:

```markdown
| `@sidetabs-note-store` | `~/.local/share/tmux-sidetabs/notes.tsv` | Path to the durable note index (TSV: session, window name, note id — one row per noted window). Note **text** lives one file per note in `<store>.d/`, so notes have no length limit |
```

- [ ] **Step 2: Rewrite the Notes bullet**

```markdown
- **Notes**: `M-n` (sidebar focused) opens the current window's note in a popup
  running your `$EDITOR`. **Notes have no length limit** and multi-line text,
  indentation and tabs are all preserved — reopening the popup gives the note
  back exactly as you wrote it. Saving an empty buffer clears the note. Only
  control characters, trailing whitespace and blank lines at the very start and
  end are stripped.

  The text lives in its own file (`<store>.d/<note-id>`); the window option and
  the TSV store hold only that id. That indirection is what lifts the limit —
  tmux rejects any command over ~16KB, so a note kept in the option was capped
  no matter what. The row shows the note's **presence** only — a sticky-note
  glyph, expanded mode only (the collapsed strip has no room for it) — so note
  text never reaches a render format.

  Notes survive restarts on their own: every edit writes through to
  `@sidetabs-note-store`, and the post-restore hook replays it, matching on
  session + window name. Renaming a window detaches its stored note until you
  next edit it, and with duplicate window names the first window wins; a live
  note is never overwritten by a restore.

  Notes written by an earlier version were stored inline in the window option;
  they still open normally and convert to a file the first time you save them.
  `scripts/note.sh gc` sweeps note files that no store row and no live window
  references.
```

- [ ] **Step 3: Verify the docs match the code**

```bash
grep -n 'note' README.md | grep -i '200\|escap\|single-line'
```

Expected: no output — every reference to the cap and to escaping is gone.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(notes): document unlimited notes and the file-per-note store"
```

---

### Task 6: Full-suite regression + real-world check

- [ ] **Step 1: Run every affected suite**

```bash
./tests/notes_smoke.sh
./tests/smoke.sh
./tests/features_smoke.sh
./tests/resurrect_smoke.sh
```

Expected: all pass. `tests/resurrect_complex_e2e.sh` is known-failing on this
machine for environmental reasons ("no space for new pane") and predates this
work — do not chase it, but note it if it is run.

- [ ] **Step 2: Confirm the original bug is gone, end to end**

On a scratch server with a hermetic store, save a note far longer than the old
cap through the real key path and read it back:

```bash
SOCK=notecheck$$
STORE="${TMPDIR:-/tmp}/notecheck$$.tsv"
tmux -L "$SOCK" -f /dev/null new-session -d -s main -n probe
tmux -L "$SOCK" set-option -g @sidetabs-note-store "$STORE"
tmux -L "$SOCK" run-shell "$PWD/sidetabs.tmux"; sleep 0.5
W=$(tmux -L "$SOCK" list-windows -t main -F '#{window_name} #{window_id}' | awk '$1=="probe"{print $2}')
awk 'BEGIN { for (i=1;i<=2000;i++) printf "  indented line %d with a\ttab\n", i }' > /tmp/note-in.txt
printf '#!/usr/bin/env bash\ncp /tmp/note-in.txt "$1"\n' > /tmp/ed.sh; chmod +x /tmp/ed.sh
tmux -L "$SOCK" run-shell "EDITOR=/tmp/ed.sh $PWD/scripts/note.sh edit-popup $W"; sleep 1
printf '#!/usr/bin/env bash\ncp "$1" /tmp/note-out.txt\n' > /tmp/ed2.sh; chmod +x /tmp/ed2.sh
tmux -L "$SOCK" run-shell "EDITOR=/tmp/ed2.sh $PWD/scripts/note.sh edit-popup $W"; sleep 1
cmp /tmp/note-in.txt /tmp/note-out.txt && echo "ROUND-TRIP OK ($(wc -c < /tmp/note-in.txt) bytes)"
tmux -L "$SOCK" kill-server; rm -f "$STORE" /tmp/note-*.txt /tmp/ed*.sh; rm -rf "$STORE.d"
```

Expected: `ROUND-TRIP OK (~74000 bytes)` — 370x the old 200-character cap, with
tabs and indentation intact.

- [ ] **Step 3: Commit any fixes, then merge**

Follow the repo's existing pattern: feature branch, then merge to `main`. Do not
push — the user pushes.

## Self-Review

**Spec coverage:** unlimited length (Task 1 + Task 3 §4), id-in-option (Task 1),
file-per-note (Task 1), TSV keeps 3 fields (Task 1, asserted Task 3), orphan
cleanup (Task 2), no data loss for existing notes (Task 1 `seed_file` legacy
branch, Task 4), docs (Task 5), regression (Task 6). Complete.

**Placeholder scan:** no TBDs; every code step carries its actual code.

**Type consistency:** `notes_dir`/`note_path`/`valid_id`/`new_id`/`sanitize_file`/
`seed_file`/`apply_note` are named identically in Tasks 1, 2 and 3. `apply_note`
takes `<wid> <srcfile>` in every call site (`set`, `clear`, `edit-popup`).
`NEW_ID`, `DEC`, `SNAME`, `WNAME` are the globals set by `new_id`, `decode_note`
and `window_key` respectively. The removed globals `ENC` and `NOTE` have no
remaining readers — `encode_note` is deleted, `sanitize_note` is replaced.
