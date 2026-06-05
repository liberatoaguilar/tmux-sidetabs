# Window Search/Jump Popup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `prefix + /` opens a `display-popup` that fuzzy-searches the current session's windows (icon/index/name/command/dir) and jumps to the chosen one, landing in its sidebar pane.

**Architecture:** A new `scripts/search.sh` builds the candidate list and handles the pick; `bind_keys` wires `prefix + <key>` to a popup running it when fzf is present, else to tmux's native `choose-tree`. The per-command icon map moves to a shared `scripts/icons.sh` reused by `render.sh` and `search.sh`.

**Tech Stack:** bash 3.2 (no assoc arrays / `$'\u'`), tmux 3.4 `display-popup`, fzf (optional), awk. Integration tests via `tmux -L` + `run-shell` + `capture-pane` in `tests/smoke.sh`.

---

## Context

The sidebar lists the current session's windows but has no quick "jump to the
window I'm thinking of" when there are many. This adds a fuzzy search popup.
Design approved at `docs/superpowers/specs/2026-06-05-sidetabs-search-popup-design.md`.

Decisions: current-session windows only; fzf with `choose-tree` fallback decided
at install time; `prefix + /` default via `@sidetabs-search-key`; on pick →
`select-window` + focus the target's **sidebar** pane; entry = `‹icon› ‹index›
name command dir` (all fuzzy-searchable).

**Environment:** scripts run under macOS **bash 3.2** — no associative arrays, no
`$'\u'`. Reuse `get_tmux_option`/`find_sidetab_pane` (`scripts/helpers.sh`), the
content-pane reduction (active non-sidetab pane via `list-panes -s`, as in
`render.sh`'s `CMD_MAP`), and the `respawn-pane -k` + `capture-pane` test patterns.

**Test note:** scripts call bare `tmux`, which only targets the test server when
run via `tmux -L "$SOCKET" run-shell "..."` (that sets `$TMUX`). `run-shell`
(no `-b`) is synchronous, so for stdout-producing test hooks we redirect to a temp
file inside the run-shell command and read it back.

## File structure

- `scripts/icons.sh` — **new**; `ICON_*` glyph vars + `icon_for <command>` (sets global `ICON`). Extracted from `render.sh`.
- `scripts/render.sh` — source `icons.sh`; drop inline `ICON_*`; `get_icon` becomes a thin wrapper over `icon_for`.
- `scripts/search.sh` — **new**; candidate list + pick logic, with `SIDETABS_SEARCH_LIST` / `SIDETABS_SEARCH_PICK` test hooks.
- `scripts/variables.sh` — `DEFAULT_SEARCH_KEY="/"`.
- `sidetabs.tmux` — install-time fzf check + search binding in `bind_keys`.
- `scripts/uninstall.sh` — unbind the search key.
- `tests/smoke.sh` — list-mode, pick-mode, binding assertions.
- `README.md` — document `@sidetabs-search-key` + the feature.

---

## Task 1: Extract the icon map to `scripts/icons.sh`

**Files:**
- Create: `scripts/icons.sh`
- Modify: `scripts/render.sh`
- Test: `tests/smoke.sh` (existing icon test must still pass — behavior-preserving)

- [ ] **Step 1: Create `scripts/icons.sh`**

```bash
#!/usr/bin/env bash
# Shared per-command Nerd Font icon map, used by render.sh (sidebar rows) and
# search.sh (popup list). Glyph bytes are printf'd (bash 3.2: no $'\u'). Exact
# glyphs are tweakable.
ICON_EDITOR="$(printf '\xee\x98\xab')"  # U+E62B  vim/editor
ICON_NODE="$(printf '\xee\x9c\x98')"    # U+E718  node/js
ICON_PYTHON="$(printf '\xee\x98\x86')"  # U+E606  python
ICON_RUBY="$(printf '\xee\x9c\xb9')"    # U+E739  ruby
ICON_GO="$(printf '\xee\x98\xa7')"      # U+E627  go
ICON_RUST="$(printf '\xee\x9e\xa8')"    # U+E7A8  rust
ICON_GIT="$(printf '\xee\x9c\x82')"     # U+E702  git
ICON_DOCKER="$(printf '\xee\x9e\xb0')"  # U+E7B0  docker/containers
ICON_DB="$(printf '\xee\x9c\x86')"      # U+E706  database
ICON_REMOTE="$(printf '\xef\x83\x82')"  # U+F0C2  ssh/cloud
ICON_PAGER="$(printf '\xef\x80\xad')"   # U+F02D  pager/book
ICON_LOGS="$(printf '\xef\x83\xb6')"    # U+F0F6  logs/file-text
ICON_BUILD="$(printf '\xef\x82\xad')"   # U+F0AD  make/wrench
ICON_SHELL="$(printf '\xef\x84\xa0')"   # U+F120  shell/terminal
ICON_DEFAULT="$(printf '\xef\x84\x91')" # U+F111  default (filled circle)

# icon_for <command> — set global ICON to the mapped glyph (or the default).
icon_for() {
    case "$1" in
        vim|nvim|vi|view)                 ICON="$ICON_EDITOR" ;;
        node|nodejs|npm|npx|yarn|pnpm|bun|deno) ICON="$ICON_NODE" ;;
        python|python3|ipython|pip|pip3)  ICON="$ICON_PYTHON" ;;
        ruby|rails|irb|bundle)            ICON="$ICON_RUBY" ;;
        go|gopls)                         ICON="$ICON_GO" ;;
        cargo|rustc|rust-analyzer)        ICON="$ICON_RUST" ;;
        git|lazygit|gitui|tig)            ICON="$ICON_GIT" ;;
        docker|docker-compose|kubectl|k9s) ICON="$ICON_DOCKER" ;;
        psql|mysql|redis-cli|sqlite3|mongosh) ICON="$ICON_DB" ;;
        ssh|mosh|sshpass)                 ICON="$ICON_REMOTE" ;;
        less|more|man|bat)                ICON="$ICON_PAGER" ;;
        tail|journalctl|tailspin)         ICON="$ICON_LOGS" ;;
        make|cmake|gcc|cc|clang|gradle)   ICON="$ICON_BUILD" ;;
        bash|zsh|fish|sh|dash)            ICON="$ICON_SHELL" ;;
        *)                                ICON="$ICON_DEFAULT" ;;
    esac
}
```

- [ ] **Step 2: Source `icons.sh` in `render.sh`**

In `scripts/render.sh`, after the existing `source "$CURRENT_DIR/helpers.sh"` line
(`scripts/render.sh:20`), add:

```bash
source "$CURRENT_DIR/icons.sh"
```

- [ ] **Step 3: Remove the inline `ICON_*` block from `render.sh`**

In `scripts/render.sh`, delete the per-command icon block in the Theme section
(the comment `# Per-command icons (Nerd Font)...` plus the 15 `ICON_EDITOR`…
`ICON_DEFAULT` lines, currently `scripts/render.sh:73-89`). The base glyphs
(`ARROW`/`THIN`/`RULE`/`GIT_ICON`/`DIR_ICON`/`TAB`) stay.

- [ ] **Step 4: Slim `get_icon` to wrap `icon_for`**

In `scripts/render.sh`, replace the whole `get_icon()` function with:

```bash
# Sets global ICON for window $1 by looking up its command in CMD_MAP, then
# mapping via icon_for (scripts/icons.sh).
get_icon() {
    local e cmd=""
    for e in $CMD_MAP; do
        case "$e" in "$1:"*) cmd="${e#*:}"; break ;; esac
    done
    icon_for "$cmd"
}
```

- [ ] **Step 5: Make `icons.sh` executable-safe and syntax-check**

Run: `bash -n scripts/icons.sh && bash -n scripts/render.sh`
Expected: no output.

- [ ] **Step 6: Run smoke to confirm behavior preserved**

Run: `./tests/smoke.sh`
Expected: `ALL SMOKE TESTS PASSED` (the `icons change the sidebar rendering` test
still passes — icons still render, now via the shared map).

- [ ] **Step 7: Commit**

```bash
git add scripts/icons.sh scripts/render.sh
git commit -m "refactor(icons): extract shared icons.sh (icon_for) from render.sh"
```

---

## Task 2: `scripts/search.sh` (candidate list + pick)

**Files:**
- Create: `scripts/search.sh`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Write the failing tests (append before the final `echo` in `tests/smoke.sh`)**

Insert immediately before `echo "ALL SMOKE TESTS PASSED"`. (Reuses `w0`/`w1` from
the active-tab block, where the windows were renamed AAA/BBB.)

```bash
# 12. search.sh list mode: one candidate line per current-session window, each
#     prefixed with its @window_id and containing the window name.
tmux -L "$SOCKET" run-shell "SIDETABS_SEARCH_LIST=1 '$PLUGIN_DIR/scripts/search.sh' main > /tmp/sl_$$ 2>&1"
slist="$(cat /tmp/sl_$$ 2>/dev/null)"; rm -f /tmp/sl_$$
ncand="$(printf '%s\n' "$slist" | grep -c '^@')"
[ "$ncand" -ge 2 ] || fail "search list expected >=2 windows, got $ncand: $slist"
printf '%s\n' "$slist" | grep -q 'AAA' || fail "search list missing window name AAA"
pass "search list-mode produced $ncand candidates"

# 13. search.sh pick mode: selecting a window switches to it and focuses its sidebar.
tmux -L "$SOCKET" select-window -t "$w1"
tmux -L "$SOCKET" run-shell "SIDETABS_SEARCH_PICK='$w0' '$PLUGIN_DIR/scripts/search.sh' main"
sleep 0.3
psel="$(tmux -L "$SOCKET" display-message -p -t main '#{window_id} #{@is_sidetab}')"
[ "${psel%% *}" = "$w0" ] || fail "search pick selected ${psel%% *}, expected $w0"
[ "${psel##* }" = "1" ] || fail "search pick didn't focus the sidebar"
pass "search pick switched to $w0 and focused its sidebar"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/smoke.sh`
Expected: FAIL at test 12 (`search.sh` doesn't exist → empty output → `ncand` is 0).

- [ ] **Step 3: Create `scripts/search.sh`**

```bash
#!/usr/bin/env bash
# Window search/jump popup body. Run inside `display-popup -E` with the
# originating session id as $1. Lists the session's windows for fzf; on pick,
# selects the window and focuses its sidebar pane.
#
# Test hooks (skip fzf):
#   SIDETABS_SEARCH_LIST=1     print candidate lines and exit
#   SIDETABS_SEARCH_PICK=<wid> act on that window id and exit
set -uo pipefail

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$CURRENT_DIR/variables.sh"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/icons.sh"

SESSION_ID="${1:-}"
[ -z "$SESSION_ID" ] && SESSION_ID="$(tmux display-message -p '#{session_id}' 2>/dev/null)"
[ -z "$SESSION_ID" ] && exit 0

TAB="$(printf '\t')"
US="$(printf '\037')"   # unit separator: packs command<US>cwd in the map

# Emit "window_id<TAB><icon> <index>  <name>  <command>  <~cwd>" per window.
candidates() {
    local map wid idx name entry cmd cwd
    # window_id -> command<US>cwd for the active non-sidetab pane (else first).
    map="$(tmux list-panes -s -t "$SESSION_ID" \
        -F "#{window_id}${TAB}#{pane_active}${TAB}#{@is_sidetab}${TAB}#{pane_current_command}${TAB}#{pane_current_path}" \
        2>/dev/null \
        | awk -F"$TAB" -v US="$US" '
            $3=="1"{next}
            { v=$4 US $5; if($2=="1"){c[$1]=v} else if(!($1 in c)){c[$1]=v} }
            END{ for(w in c) print w "\t" c[w] }')"
    while IFS="$TAB" read -r wid idx name; do
        entry="$(printf '%s\n' "$map" | awk -F"$TAB" -v w="$wid" '$1==w{print $2; exit}')"
        cmd="${entry%%${US}*}"
        cwd="${entry#*${US}}"
        [ "$cwd" = "$entry" ] && cwd=""        # no US -> no entry found
        case "$cwd" in "$HOME"/*|"$HOME") cwd="~${cwd#$HOME}" ;; esac
        icon_for "$cmd"
        printf '%s\t%s %s  %s  %s  %s\n' "$wid" "$ICON" "$idx" "$name" "$cmd" "$cwd"
    done < <(tmux list-windows -t "$SESSION_ID" \
                 -F "#{window_id}${TAB}#{window_index}${TAB}#{window_name}" 2>/dev/null)
}

# Switch to window $1 and focus its sidebar pane.
do_pick() {
    local wid="$1" sp
    [ -z "$wid" ] && return 0
    tmux select-window -t "$wid" 2>/dev/null || return 0
    sp="$(find_sidetab_pane "$wid")"
    [ -n "$sp" ] && tmux select-pane -t "$sp" 2>/dev/null || true
}

[ -n "${SIDETABS_SEARCH_LIST:-}" ] && { candidates; exit 0; }
[ -n "${SIDETABS_SEARCH_PICK:-}" ] && { do_pick "$SIDETABS_SEARCH_PICK"; exit 0; }

sel="$(candidates | fzf --delimiter="$TAB" --with-nth=2 --no-sort --prompt='window> ')"
[ -z "$sel" ] && exit 0    # Esc / no match
do_pick "${sel%%${TAB}*}"
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x scripts/search.sh`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./tests/smoke.sh`
Expected: PASS — `search list-mode produced N candidates` and `search pick switched
to @x and focused its sidebar`; ends `ALL SMOKE TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add scripts/search.sh tests/smoke.sh
git commit -m "feat(search): scripts/search.sh window candidate list + pick"
```

---

## Task 3: Bind the popup + option + uninstall

**Files:**
- Modify: `scripts/variables.sh`
- Modify: `sidetabs.tmux`
- Modify: `scripts/uninstall.sh`
- Test: `tests/smoke.sh`

- [ ] **Step 1: Write the failing test (append before the final `echo` in `tests/smoke.sh`)**

```bash
# 14. The search key is bound after load (fzf -> popup+search.sh, else choose-tree).
if command -v fzf >/dev/null 2>&1; then
  tmux -L "$SOCKET" list-keys 2>/dev/null | grep -q 'search.sh' || fail "search popup not bound (fzf path)"
  pass "search key bound to display-popup + search.sh"
else
  tmux -L "$SOCKET" list-keys 2>/dev/null | grep -q 'choose-tree' || fail "search fallback (choose-tree) not bound"
  pass "search key bound to choose-tree fallback"
fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `./tests/smoke.sh`
Expected: FAIL — `search.sh` is referenced by no binding yet (fzf present in dev env).

- [ ] **Step 3: Add the default key to `variables.sh`**

In `scripts/variables.sh`, in the `# Defaults` block, after `DEFAULT_ICONS="on"`, add:

```bash
DEFAULT_SEARCH_KEY="/"
```

- [ ] **Step 4: Install the binding in `sidetabs.tmux`**

In `bind_keys()` (in `sidetabs.tmux`), after the `uninstall_key` block and before
the `local skip_nav` line, add:

```bash
    local search_key
    search_key="$(get_tmux_option "@sidetabs-search-key" "$DEFAULT_SEARCH_KEY")"
    if [ -n "$search_key" ]; then
        # fzf if available -> fuzzy popup; otherwise tmux's native window picker.
        if command -v fzf >/dev/null 2>&1; then
            tmux bind-key "$search_key" display-popup -E -w 60% -h 50% -T ' windows ' \
                "$SCRIPTS_DIR/search.sh #{session_id}"
        else
            tmux bind-key "$search_key" choose-tree -Zw
        fi
    fi
```

- [ ] **Step 5: Unbind on uninstall**

In `scripts/uninstall.sh`, after the `uninstall_key` unbind block (before the
`for k in 'C-j' ...` loop), add:

```bash
search_key="$(get_tmux_option "@sidetabs-search-key" "$DEFAULT_SEARCH_KEY")"
[ -n "$search_key" ] && tmux unbind-key "$search_key" 2>/dev/null || true
```

- [ ] **Step 6: Run to verify it passes**

Run: `./tests/smoke.sh`
Expected: PASS — `search key bound to display-popup + search.sh`; ends `ALL SMOKE TESTS PASSED`.

- [ ] **Step 7: Commit**

```bash
git add scripts/variables.sh sidetabs.tmux scripts/uninstall.sh tests/smoke.sh
git commit -m "feat(search): bind prefix+/ to the popup (choose-tree fallback)"
```

---

## Task 4: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add `@sidetabs-search-key` to the Configuration table**

In `README.md`, in the `## Configuration` table, after the `@sidetabs-icons` row, add:

```markdown
| `@sidetabs-search-key` | `/` | Prefix key to open the fuzzy window-search popup (needs fzf; falls back to `choose-tree`) |
```

- [ ] **Step 2: Add the Usage row**

In `README.md`, in the `## Usage` table, after the left-click row, add:

```markdown
| `prefix + /` | Fuzzy-search this session's windows in a popup and jump to one |
```

- [ ] **Step 3: Add an intro bullet**

In `README.md`, after the icons bullet added previously, add:

```markdown
- `prefix + /` opens a fuzzy-search popup over the current session's windows
  (search by name, running command, or directory) and jumps to the one you pick.
  Uses fzf when available, otherwise tmux's built-in `choose-tree`.
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document @sidetabs-search-key window search popup"
```

---

## Task 5: Manual verification (interactive)

The fzf UI can't run headlessly — confirm it once live.

- [ ] **Step 1: Reload**

`tmux source-file ~/.tmux.conf` (binding installs), then restart sidebars so a fresh
render is running:
```bash
for p in $(tmux list-panes -a -F '#{pane_id} #{@is_sidetab}' | awk '$2=="1"{print $1}'); do
  tmux respawn-pane -k -t "$p" '/Users/liberatoaguilar/Desktop/Aguilabs/tmux-sidetabs/scripts/render.sh'
done
```

- [ ] **Step 2: Open and search**

Press `prefix + /`. A popup lists this session's windows with icons. Type part of a
name, a command (e.g. `node`), or a path fragment → the list narrows. Press Enter →
the session switches to that window and focus lands in its sidebar. Press Esc in the
popup → nothing changes.

- [ ] **Step 3: Fallback check (optional)**

Temporarily make fzf unfindable (e.g. `PATH=/usr/bin tmux ...`) or test on a box
without fzf: `prefix + /` should open tmux's `choose-tree` window picker instead.

---

## Self-review (against the spec)

**Spec coverage:**
- Fuzzy-jump current-session windows by name/command/path → Task 2 `candidates()` (icon+index+name+command+cwd) + fzf in Task 2 Step 3.
- `prefix + /`, configurable → Task 3 (`@sidetabs-search-key`, `DEFAULT_SEARCH_KEY`).
- On select → select-window + focus sidebar → Task 2 `do_pick` (`find_sidetab_pane`).
- fzf with choose-tree fallback, decided at install time → Task 3 Step 4.
- Reuse icon map (no duplication) → Task 1 (`icons.sh` / `icon_for`).
- Tests: list mode, pick mode, binding → Task 2 Steps 1, Task 3 Step 1; manual fzf → Task 5; README → Task 4.

**Placeholder scan:** none — every step has complete code. Glyph bytes are concrete
(unchanged from the merged icons feature).

**Consistency:** `icon_for`/`ICON`, `candidates`/`do_pick`, `SIDETABS_SEARCH_LIST`/
`SIDETABS_SEARCH_PICK`, `@sidetabs-search-key`/`DEFAULT_SEARCH_KEY`, the `\t`
field-1 `window_id` key + fzf `--with-nth=2`, and `find_sidetab_pane` are used
identically across tasks. `search.sh` sources the same `icons.sh` that `render.sh`
now uses (Task 1). bash-3.2 constraints honored (no assoc arrays; `printf` glyphs;
`case` map; awk for space-safe path handling).
```
