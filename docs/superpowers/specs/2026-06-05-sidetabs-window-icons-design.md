# tmux-sidetabs: per-window command icons (richer rows)

**Date:** 2026-06-05
**Status:** Approved design, pending implementation plan

## Summary

Add a Nerd Font icon to each window row, derived from the command running in that
window's content pane — so the sidebar shows *what each window is* at a glance
(editor / server / shell / db / …), cmux-style. Expanded rows get a leading icon
before the name; the collapsed strip shows the window number plus the icon. Gated
by a new `@sidetabs-icons` option (default `on`). No pane-count indicator (cut as
YAGNI).

## Goals

- Expanded row: `‹N› │ <icon> name flags` — a per-window icon before the name.
- Collapsed strip: `‹N›<icon>` — number then icon.
- Icon reflects the window's **content**, correct even while you're browsing the
  sidebar (when that window's active pane is the sidetab itself).
- Opt-out via `@sidetabs-icons off` (restores today's plain rows).
- No new external dependencies (the plugin already requires a Nerd Font).

## Non-goals (v1)

- Pane-count indicator.
- User-configurable icon map (a `@sidetabs-icon-map` override can come later).
- Per-command color coding.

## Behavior

### Expanded
```
 session ›
 ─────────────────
 1 │ ✎ editor *
 2 │ ⚙ server
 3 │ ❯ shell  Z
 4 │ ⚙ logs
```
The icon + a trailing space (2 display columns) sit between the `│` thin separator
and the name. The name truncates ~2 columns sooner than today; flags (`*-Z`) are
unchanged.

### Collapsed
```
 1✎
 2⚙
 3❯
 4⚙
```
Number then icon. This needs ~5 columns, so **`@sidetabs-collapsed-width` default
goes 4 → 5**. Two-digit window numbers (10+) may clip the icon at width 5; the
option is user-tunable, and this is acceptable for v1.

## Icon source

The icon must reflect a window's **content pane**, not the sidebar. When you `C-h`
into a sidebar, that window's *active* pane becomes the sidetab (command `bash`),
which would otherwise mislabel the window.

Approach: once per draw, run a single session-wide pane query
```
tmux list-panes -s -t "$SESSION_ID" \
  -F "#{window_id}<TAB>#{pane_active}<TAB>#{@is_sidetab}<TAB>#{pane_current_command}"
```
and reduce it (awk) to a `window_id → command` map, choosing for each window its
**active non-sidetab pane**, falling back to the first non-sidetab pane. This is
the same content-pane selection rule `emit_summary` already uses. One extra tmux
call per draw — on par with the existing per-draw queries.

Icons update within the normal ≤1s redraw (and immediately on the `USR1` refresh),
so they track command changes live.

## Icon map

A built-in `command → glyph` associative array in `render.sh`, plus a default
glyph for anything unmapped. Representative entries (Nerd Font glyphs; exact
codepoints chosen at implementation):

| Commands | Meaning |
| --- | --- |
| `vim` `nvim` `vi` `view` | editor |
| `node` `npm` `npx` `yarn` `pnpm` `bun` `deno` | JS runtime |
| `python` `python3` `ipython` `pip` | python |
| `ruby` `rails` `irb` | ruby |
| `go` `gopls` | go |
| `cargo` `rustc` | rust |
| `git` `lazygit` `gitui` | git |
| `docker` `docker-compose` `kubectl` `k9s` | containers |
| `ssh` `mosh` | remote |
| `psql` `mysql` `redis-cli` `sqlite3` | database |
| `less` `more` `man` `bat` | pager |
| `tail` `journalctl` | logs |
| `make` `cmake` `gcc` `cc` | build |
| `bash` `zsh` `fish` `sh` | shell |
| *(anything else)* | default glyph |

Lookup is exact match on the basename of `pane_current_command`. v1 keeps this
table in-code (not a tmux option).

## Rendering changes (`render.sh`)

- **`build_lines`:** before the window loop, build `CMD_FOR` (a `window_id →
  command` map) from the single `list-panes -s` call. In the loop, compute the
  icon once per window (`icon="$(icon_for "${CMD_FOR[$wid]:-}")"`) and pass it to
  `emit_row`. Skip all of this when `@sidetabs-icons` is `off` (pass an empty
  icon).
- **`icon_for <command>`:** returns the mapped glyph or the default. Pure lookup,
  no subprocess.
- **`emit_row`:** gains an `icon` parameter. Expanded: after the `│ ` it prints
  `<icon> ` (when non-empty) before the name; the used-width math adds the icon's
  columns so truncation still lands correctly. Collapsed: prints the number then
  the icon (when non-empty). When `icon` is empty, output is byte-identical to
  today.
- The icon's display width is treated as 1 column + 1 trailing space = 2 columns
  for the width math (Nerd Font private-use glyphs render single-width).

## Configuration

| Option | Default | Purpose |
| --- | --- | --- |
| `@sidetabs-icons` | `on` | `off` to hide per-window command icons |
| `@sidetabs-collapsed-width` | `5` (was 4) | wider so collapsed `N + icon` fits |

`render.sh` reads `@sidetabs-icons` **once at startup** into an `ICONS_ON`
variable — the same pattern as `@sidetabs-summary` (`summary_on`), the colors, and
`@sidetabs-mouse` (`MOUSE_ON`). Toggling it therefore takes effect on the next
config reload or when the sidebar panes are recreated (consistent with the other
display options), not mid-loop.

## Testing (`tests/smoke.sh`, headless)

`capture-pane -p` renders a pane's visible text, so icons are assertable without a
real terminal:
- Start a window whose content pane runs a known command (e.g. `vim`); with
  `@sidetabs-icons on`, `capture-pane -p` the sidebar and assert its row contains
  the mapped editor glyph.
- A window running a plain shell shows the shell glyph (or default).
- With `@sidetabs-icons off`, assert the sidebar row contains the name but **not**
  the glyph (today's format).
- Existing rows/collapse/mouse assertions must still pass (icon defaults on, so
  update any exact-match assertions that would now include a glyph).

## Files touched
- `scripts/render.sh` — icon map, `icon_for`, `CMD_FOR` build, `emit_row` icon arg + width math.
- `scripts/variables.sh` — `DEFAULT_ICONS="on"`; bump `DEFAULT_COLLAPSED_WIDTH` to `5`.
- `tests/smoke.sh` — icon on/off assertions.
- `README.md` — document `@sidetabs-icons`, the new collapsed-width default, and the icon row.

## Risks
- **Glyph width:** if a chosen glyph renders double-width in some terminals, the
  width math is off by one for that row. Mitigation: pick single-width Nerd Font
  private-use glyphs; the truncation guard already clamps, so worst case is a
  slightly short name, not a broken layout.
- **`list-panes -s` cost:** one extra call per draw; negligible at sidebar scale
  and the 1s cadence. Can be folded into the summary cache later if needed.
- **Collapsed clipping at width 5** for 2-digit window numbers — accepted; tunable.
