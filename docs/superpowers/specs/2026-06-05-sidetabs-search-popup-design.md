# tmux-sidetabs: window search/jump popup

**Date:** 2026-06-05
**Status:** Approved design, pending implementation plan

## Summary

A `display-popup` that fuzzy-searches the current session's windows and jumps to
the chosen one. Opened with `prefix + /` (configurable via `@sidetabs-search-key`).
Each entry shows `‹icon› ‹index› name command dir`, so you can find a window by its
name, what's running in it, or its working directory. On pick, switch to the window
and land in its sidebar pane (consistent with click-to-select). Uses fzf when
available, falling back to tmux's native `choose-tree` picker when it isn't.

## Goals

- Fuzzy-jump to any window in the **current session** by name / command / path.
- Reachable from any pane via `prefix + /` (overridable).
- On select: `select-window` + focus the target window's **sidebar** pane.
- Degrade gracefully without fzf (native `choose-tree`).
- Reuse the existing per-command icon map (no duplication).

## Non-goals (v1)

- Cross-session / all-sessions search (current session only).
- Jumping to individual panes.
- A custom TUI (we lean on fzf / choose-tree).

## Decisions (from brainstorming)

| Decision | Choice |
| --- | --- |
| Scope | Current session windows only |
| Finder | fzf if present, else `choose-tree` fallback |
| Invocation | `prefix + <key>`, default `/`, via `@sidetabs-search-key` |
| On select | Switch to window, focus its **sidebar** pane |
| Entry text | `‹icon› ‹index› name command dir` (all fuzzy-searchable) |

## Architecture

### fzf-vs-fallback is decided at install time

In `bind_keys()` (in `sidetabs.tmux`), check `command -v fzf` once when the plugin
loads:

- **fzf present:**
  `tmux bind-key "$key" display-popup -E -w 60% -h 50% -T ' windows ' "$SCRIPTS_DIR/search.sh #{session_id}"`
- **fzf absent:**
  `tmux bind-key "$key" choose-tree -Zw`

So `search.sh` only ever runs when fzf exists — it doesn't need its own fallback
branch. (Installing fzf later takes effect on the next config reload — documented.)

### `scripts/search.sh`

Invoked as the popup command with the originating `session_id` as `$1` (so it lists
the right session regardless of popup context). Steps:

1. **Build candidates.** One `tmux list-panes -s -t "$SESSION_ID"` with
   `#{window_id}\t#{pane_active}\t#{@is_sidetab}\t#{pane_current_command}\t#{pane_current_path}`,
   reduced by awk to `window_id → command<US>cwd`, choosing each window's active
   non-sidetab pane (else first non-sidetab) — the same content-pane rule used by
   `emit_summary`/render's `CMD_MAP`. Then iterate `tmux list-windows` (index, name,
   in order); for each, `icon_for "$command"` (from `icons.sh`) and emit one line:

   ```
   <window_id>\t<icon> <index>  <name>  <command>  <home-shortened cwd>
   ```

   The leading `window_id` + TAB is the parse key; fzf hides it.

2. **Pick.** Pipe candidates to
   `fzf --delimiter=$'\t' --with-nth=2 --no-sort --prompt='window> '`
   (`--with-nth=2` displays only the second field, so the `window_id` key is hidden
   but still returned in the selected line). Empty selection (Esc) → exit 0, no-op.

3. **Act.** `wid="${selected%%<TAB>*}"`; `tmux select-window -t "$wid"`; then focus
   the window's sidebar: `sp="$(find_sidetab_pane "$wid")"; [ -n "$sp" ] &&
   tmux select-pane -t "$sp"`. On exit the `-E` popup closes, revealing the target
   window with its sidebar focused.

### `scripts/icons.sh` (extraction — DRY)

Move the `ICON_*` glyph definitions and the command→glyph mapping out of
`render.sh` into a sourced `icons.sh` exposing:

- the `ICON_*` vars, and
- `icon_for <command>` — sets the global `ICON` to the mapped glyph (or the default).

`render.sh` sources `icons.sh` and its `get_icon <window_id>` becomes a thin
wrapper: look the command up in `CMD_MAP`, then call `icon_for`. `search.sh` sources
`icons.sh` and calls `icon_for` per window. One icon map, two consumers.

### Config

| Option | Default | Purpose |
| --- | --- | --- |
| `@sidetabs-search-key` | `/` | Prefix key to open the window search popup |

Read in `bind_keys()` via `get_tmux_option`, like `@sidetabs-toggle-key`.

## Data flow

```
prefix + /  ->  display-popup -E  ->  search.sh <session_id>
                                        candidates() | fzf --with-nth=2
                                          pick -> window_id
                                            select-window + select sidebar pane
                                        (exit -> popup closes -> target window shown)
no fzf:      prefix + /  ->  choose-tree -Zw   (native picker)
```

## Files touched

- `scripts/search.sh` — new popup script (candidate build + pick + act).
- `scripts/icons.sh` — new; `ICON_*` + `icon_for` extracted from `render.sh`.
- `scripts/render.sh` — source `icons.sh`; `get_icon` wraps `icon_for`; drop inline icon defs.
- `scripts/variables.sh` — `DEFAULT_SEARCH_KEY="/"`.
- `sidetabs.tmux` — install-time fzf check + search binding in `bind_keys`.
- `scripts/uninstall.sh` — unbind the search key.
- `tests/smoke.sh` — list-mode + pick-mode assertions; binding-installed assertion.
- `README.md` — document `@sidetabs-search-key` + the feature.

## Testing (headless)

The interactive fzf step can't run headlessly, so `search.sh` gets two env hooks
around it:

- `SIDETABS_SEARCH_LIST=1` → print the candidate lines and exit (skip fzf). Assert:
  one line per current-session window, each starting with a `@`-prefixed window_id
  and TAB, containing the window's name (and, for a known content command, the
  expected command text).
- `SIDETABS_SEARCH_PICK=<window_id>` → skip fzf, run the act step on that id.
  Assert: that window becomes active and the active pane is its sidetab.

Plus: assert `prefix + <key>` is bound (via `list-keys`) after load, and that the
existing icon smoke test still passes (covers the `icons.sh` extraction).

## Risks

- **Popup context:** `select-window`/`select-pane` are issued from inside the popup
  command but target the client's session via ids; verified pattern. Passing
  `session_id` as an argument avoids any popup-context ambiguity in listing.
- **fzf installed later:** binding is chosen at load; needs a reload to switch from
  the `choose-tree` fallback to fzf. Documented.
- **`icons.sh` extraction:** mechanical move; the icon smoke test guards it.
