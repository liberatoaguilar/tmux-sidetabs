# tmux-sidetabs: self-mouse click-to-select (supersedes the global-mouse v1)

**Date:** 2026-06-05
**Status:** Approved design, implementing
**Supersedes:** `2026-06-05-sidetabs-mouse-click-design.md` (the tmux-binding / global-mouse approach)

## Why this replaces v1

v1 used a tmux `MouseDown1Pane` binding + a per-session rowmap. It worked but
required `set -g mouse on` — a global change that hands all drag-selection to
tmux, which the user dislikes. Investigation (and a live proof) showed tmux
forwards raw mouse escape sequences to the **focused pane's application** whenever
that app has requested mouse mode, *regardless of tmux's `mouse` option* — this is
exactly how Claude Code's mouse works inside tmux with `mouse off`.

So instead of a tmux binding, the sidebar's own process (`render.sh`) enables
mouse reporting **on itself** and reads its own clicks. No global mouse, no tmux
binding, no session rowmap.

## The one hard constraint

tmux delivers mouse events only to the **focused** pane. A sidebar is usually not
focused (you click it from a content pane). Therefore self-mouse clicks only work
**while the sidebar pane is focused**. The intended workflow:

> `C-h` into the sidebar → click any row → jump to that window; focus stays in the
> sidebar so you can keep clicking to browse.

"Click the sidebar from any pane" is impossible without global mouse and is out of
scope. This was accepted explicitly.

## Architecture

All changes are local to `render.sh` plus deletions of the v1 plumbing.

### `render.sh`

**Startup (only when `@sidetabs-mouse on`):**
- Save tty state; `stty -echo -icanon min 0 time 0` so bytes are readable
  immediately without echo.
- Enable clicks-only mouse: `printf '\e[?1000h\e[?1006h'` (normal button tracking
  + SGR extended coords). **Not** `1002`/`1003` — those add motion events we don't
  want.
- On exit (existing EXIT/INT/TERM trap, extended): restore cursor, disable mouse
  (`\e[?1000l\e[?1006l`), restore tty.

**Layout build — replace `emit_lines` with `build_lines` + `draw_lines`:**
- `build_lines` populates two **globals** in the main shell:
  - `LINES[]` — array of fully-rendered visual line strings (0-indexed = line
    index = SGR `y` − 1).
  - `ROW_WIN[]` — associative array, line-index → `window_id`, only for clickable
    window rows.
  - It uses process substitution (`done < <(tmux list-windows …)`) so the arrays
    survive the loop (a piped `while` would lose them to a subshell). Each row's
    line index is taken as `${#LINES[@]} - 1` right after appending, so indices
    stay correct across the header, rules, and the active window's 0–2 summary
    lines (appended as plain lines, no `ROW_WIN` entry).
  - `emit_header` / `emit_row` / `emit_summary` are reused unchanged, captured via
    `$(...)` into `LINES`.
- `draw_lines` homes the cursor and prints `LINES[]` with clear-to-EOL per line
  then clear-below — identical flicker-free behavior to today's `draw`.

**Main loop:**
```
while true; do
    build_lines
    draw_lines
    if mouse_on: read_mouse        # blocks up to ~1s, returns on click/timeout/USR1
    else:        sleep 1 & wait    # unchanged legacy behavior
done
```
- `read_mouse` reads one byte with `read -rsn1 -t 1`. On `ESC`, it accumulates
  until a letter terminator and matches SGR mouse `^\[<([0-9]+);([0-9]+);([0-9]+)M$`.
  A **press** with `button == 0` triggers `on_click <y>`. Release (`m`) and other
  buttons are ignored. Timeout or `USR1` (the existing immediate-redraw signal)
  just returns → redraw. Cadence is unchanged (≤1s).
- `on_click <y>`: `idx = y - 1`; `wid = ROW_WIN[idx]`; if set →
  `tmux select-window -t "$wid"` then `tmux select-pane -t "$(find_sidetab_pane "$wid")"`
  — i.e. keep focus in the **new window's sidebar** (like `sidetab_nav.sh`) so you can
  keep clicking to browse. A click on a non-row line (header/rule/summary) is a no-op.

### Deletions (v1 plumbing no longer used)
- `scripts/click.sh` — removed.
- `sidetabs.tmux` — remove the `MouseDown1Pane` binding block.
- `scripts/uninstall.sh` — remove the `MouseDown1Pane` unbind line.
- `scripts/variables.sh` — remove `ROWMAP_OPTION` (the session rowmap is gone).

### Kept
- `scripts/helpers.sh` `find_sidetab_pane` — used by `on_click` to keep focus in the
  target window's sidebar.
- `@sidetabs-mouse` option + `DEFAULT_MOUSE="off"` — now gates the self-mouse loop.

## Coordinates

SGR mouse coordinates are **1-based** and **pane-relative** (tmux presents each
pane to its app as a full terminal). So the sidebar's top line (the header) is
SGR `y = 1`, and line index `= y − 1`. This is validated by the smoke test (a
click at a known `y` must switch to the expected window); if the origin were
different the test fails.

## Testing (headless)

Clicks are injectable without a real mouse or focus:
`tmux send-keys -t <sidebar_pane> -l $'\e[<0;<x>;<y>M'` writes a synthetic SGR
click straight to `render.sh`'s stdin.

Extend `tests/smoke.sh`:
- Set `@sidetabs-mouse on` and `@sidetabs-summary off` (deterministic layout:
  line 0 header, line 1 rule, line 2 = window[0] row → SGR `y=3`, line 3 rule,
  line 4 = window[1] row → SGR `y=5`).
- Restart the sidebar render loops so they pick up the options
  (`respawn-pane -k -t <sidebar> "$PLUGIN_DIR/scripts/render.sh"`).
- Make a non-target window active, `send-keys` a click at the target row's `y`,
  assert the target window becomes active and the active pane is non-sidetab.
- Assert a click at `y=1` (header, no row) does **not** change the active window.
- Remove the v1 rowmap/click.sh/binding assertions.

## Files touched
- `scripts/render.sh` — self-mouse loop + `build_lines`/`draw_lines` + click handler.
- `scripts/variables.sh` — drop `ROWMAP_OPTION`.
- `sidetabs.tmux` — drop the binding.
- `scripts/uninstall.sh` — drop the unbind.
- `scripts/click.sh` — deleted.
- `tests/smoke.sh` — swap v1 tests for the synthetic-click test.
- `README.md` — `@sidetabs-mouse` now: focused-only click-to-select, **no global
  mouse required**; document the `C-h`-then-click workflow.

## Risks
- **Loop restructure** is the core risk: must preserve the 1s redraw cadence and
  the `USR1` immediate-redraw. `read -t 1` + the existing `trap ':' USR1` cover both.
- **No stdin spin:** a pty doesn't EOF while the pane lives; if it ever did, the
  process is exiting anyway.
- **Per-draw cost:** `build_lines` captures each line via `$()` (a few more forks
  than the single piped `emit_lines`). Negligible at sidebar scale and 1s cadence.
