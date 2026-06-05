# tmux-sidetabs: click-to-select windows (mouse support v1)

**Date:** 2026-06-05
**Status:** Approved design, pending implementation plan

## Summary

Add left-click support to the sidebar: clicking a window's row selects that
window and moves focus into the window's content pane. Works in both expanded
and collapsed modes. Opt-in via a new `@sidetabs-mouse` option (default `off`);
requires the user's own `set -g mouse on` (documented, not forced by the plugin).

This is "mouse support v1." Scroll-to-cycle, right-click action menu, and a
clickable `+ new window` row were explicitly cut from scope (YAGNI) and remain
easy follow-ups built on the same plumbing.

## Goals

- Left-click a window row in the sidebar → `select-window` + focus the target
  window's content (non-sidetab) pane. The "GUI tab" feel.
- Clicking a non-row area of the sidebar (header / rule / summary / blank) just
  focuses the sidebar pane (a convenient "enter the sidebar" affordance), never
  a no-op surprise.
- Clicks on any non-sidetab pane behave exactly as tmux's default — no
  regression to normal mouse use anywhere else.
- Off by default; zero behavior change unless the user sets `@sidetabs-mouse on`
  AND has `mouse on`.

## Non-goals (deferred follow-ups)

- Scroll wheel over the sidebar → next/previous window.
- Right-click → `display-menu` of window actions (new/rename/kill/move).
- A clickable `+ new window` row.
- Drag-to-reorder windows.
- Multi-session switching.

## Architecture

Two cooperating pieces, mirroring the existing renderer/handler split.

### The crux: row → window mapping

The sidebar layout is dynamic — the active window injects 0–2 summary lines and
a rule sits between each row — so a given window's screen row (its y-coordinate)
shifts depending on which window is active. The click handler must translate a
click's `mouse_y` into a window.

**Chosen approach: the renderer emits a rowmap.** `render.sh` already computes
the exact layout as it draws, so it is the single source of truth. On each draw
it writes a per-session option `@sidetabs_rowmap` mapping line index → window id.
The click handler just looks up `mouse_y`. No layout logic is duplicated.

Approaches rejected:

- **Handler re-derives the layout independently.** Two places that must agree on
  pixel-exact layout — the drift trap this project already avoids elsewhere.
- **`capture-pane` + parse the pill text for the window number.** Fragile under
  truncation, collapsed mode, and Nerd Font icons; slower.

### Component 1 — `render.sh` emits the rowmap

Refactor `emit_lines` so the window loops can accumulate a line counter and a map
string that survive the loop:

- Replace the piped `tmux list-windows … | while …` with process substitution
  `while … done < <(tmux list-windows …)`, so the loop body runs in the current
  shell (a piped loop runs in a subshell and its variables would be lost).
- Maintain `y` (0-based line index from the pane top) and `map` (space-separated
  `y:window_id` entries) as lines are emitted.
- Account precisely for every emitted line: the expanded-mode header (1 line),
  the collapsed-mode leading blank (1 line), the per-window rule (1 line), the
  window row itself (record `"${y}:${wid}"` here), and the 0–2 summary lines
  under the active window (count them from the captured summary output rather
  than re-deriving).
- Add `#{window_id}` to the collapsed-mode `list-windows` format (it currently
  fetches only the index).
- At the end of the loop: `set_session_option "$SESSION_ID" "$ROWMAP_OPTION" "$map"`.

The map is written on every draw regardless of whether `@sidetabs-mouse` is on.
Cost is one `set-option` per second per window — on par with the existing
per-session summary cache writes — and writing unconditionally means an
already-running renderer works the instant the binding is installed.

All sidetabs within a session render the identical session-global layout
(collapsed state, width, window list, active window, and summary are all
session-scoped or width-synced), so a single per-session option is correct;
concurrent writers store identical content (last writer wins).

### Component 2 — click binding + `scripts/click.sh`

Installed inline in `bind_keys()` (in `sidetabs.tmux`) only when
`@sidetabs-mouse` is `on` — inline rather than in a static `.conf` because the
binding interpolates `$SCRIPTS_DIR`, matching the existing `C-j`/`C-k` bindings.
The `keys.conf` pattern (which checks the *focused* pane) is not reusable here:
we must test the *moused* pane.

```tmux
bind -n MouseDown1Pane if-shell -F -t '#{mouse_pane}' '#{==:#{@is_sidetab},1}' \
  "run-shell '$SCRIPTS_DIR/click.sh #{mouse_y} #{mouse_pane}'" \
  "select-pane -t= ; send-keys -M"
```

- `-t '#{mouse_pane}'` evaluates `@is_sidetab` in the context of the pane under
  the cursor.
- The ELSE branch reproduces tmux's stock `MouseDown1Pane` (`select-pane -t= ;
  send-keys -M`), so clicks on normal panes are unchanged. `MouseDrag1Pane` is
  left untouched, so click-drag text selection keeps working everywhere,
  including inside the sidebar.

`scripts/click.sh <mouse_y> <mouse_pane>`:

1. Derive `session_id` from the moused pane (`display-message -p -t`), the same
   robustness pattern `render.sh` uses — do not trust a passed-in session id.
2. Read `@sidetabs_rowmap` for that session.
3. Find the entry whose `y` equals `mouse_y`.
   - **Match** → `tmux select-window -t <window_id>`, then `tmux select-pane -t`
     the window's content pane (via the new `find_content_pane` helper).
   - **No match** (header/rule/summary/blank) → `tmux select-pane -t <mouse_pane>`
     to enter the sidebar.

### New names and helpers

- User option: **`@sidetabs-mouse`** (kebab-case, default `off`) — gates whether
  the click binding is installed.
- Internal option: **`ROWMAP_OPTION="@sidetabs_rowmap"`** (underscore style) in
  `variables.sh`, per-session.
- Helper: **`find_content_pane <window_id>`** in `helpers.sh` — returns the
  pane id of the window's content pane, preferring the active one:

  ```bash
  find_content_pane() {
      local TAB; TAB="$(printf '\t')"
      tmux list-panes -t "$1" \
          -F "#{pane_active}${TAB}#{@is_sidetab}${TAB}#{pane_id}" 2>/dev/null \
          | awk -F"$TAB" '$2 != "1"' | sort -r | head -1 | cut -d"$TAB" -f3
  }
  ```

  Uses a TAB field separator so the frequently-empty `@is_sidetab` field does not
  collapse under whitespace splitting — the same fix already used in
  `emit_summary`. `sort -r` puts the active pane (`pane_active=1`) first.

## Data flow

```
mouse click in a pane
  -> MouseDown1Pane binding
       if moused pane @is_sidetab == 1:
          run-shell click.sh <mouse_y> <mouse_pane>
            -> session_id from pane
            -> read @sidetabs_rowmap (written each draw by render.sh)
            -> y match? select-window + select content pane
               no match? select sidebar pane
       else:
          select-pane -t= ; send-keys -M   (tmux default, unchanged)
```

## Risks and verification

- **`mouse_y` origin (the one real unknown).** The design assumes `#{mouse_y}`
  for `*Pane` events is 0-based from the top of the pane, matching the line
  indices `render.sh` uses. **Verify empirically first** with a throwaway probe
  binding (e.g. bind `MouseDown1Pane` to `display-message` of `#{mouse_y}` and
  click known rows). If the origin differs, it is a constant offset applied in
  `click.sh` — not a structural change.
- **Toggling `@sidetabs-mouse`** takes effect on tmux reload, since the binding
  is installed at plugin load. Document this.
- **Overriding `MouseDown1Pane`** replaces any user customization of that one
  binding while the feature is on; the ELSE branch preserves stock behavior for
  non-sidetab panes. Documented as a requirement/limitation.
- **MouseDown vs. drag inside the sidebar.** A plain click is intercepted to
  select/enter; a drag (`MouseDrag1Pane`, untouched) can still start a copy-mode
  selection in the sidebar. Acceptable.

## Testing

Extend `tests/smoke.sh` (which already spins up a throwaway `tmux -L` server):

- After a render, assert `@sidetabs_rowmap` is non-empty and every entry matches
  `^[0-9]+:@[0-9]+$`.
- Seed a known rowmap (or read the real one), then invoke
  `click.sh <y> <sidetab_pane_id>` directly and assert (a) the expected window
  becomes active and (b) the active pane is a non-sidetab pane.
- Assert a no-match `y` leaves the sidetab pane focused.

Mouse events cannot be synthesized headlessly, so the binding's dispatch is
verified by construction (the `if-shell` condition) while `click.sh`'s logic is
tested directly.

## Documentation

- README usage table: add the click behavior.
- README configuration table: add `@sidetabs-mouse` (default `off`) and note the
  `set -g mouse on` requirement and the reload-to-toggle caveat.

## Files touched

- `scripts/render.sh` — rowmap emission; process-substitution refactor of the
  window loops; `#{window_id}` in collapsed format.
- `scripts/click.sh` — new click handler.
- `scripts/helpers.sh` — new `find_content_pane`.
- `scripts/variables.sh` — `ROWMAP_OPTION`.
- `sidetabs.tmux` — install the `MouseDown1Pane` binding when `@sidetabs-mouse on`.
- `tests/smoke.sh` — rowmap + click.sh assertions.
- `README.md` — usage + configuration docs.
