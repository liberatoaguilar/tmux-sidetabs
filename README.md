# tmux-sidetabs

A persistent left-side window-list sidebar for tmux. Inspired by [cmux](https://cmux.com/)'s vertical tabs.

- Auto-spawns a thin pane on the left of every window.
- Lists the windows in the current session as powerline pills (` N › name flags`),
  with a session-name header on top. The active window is highlighted, a window
  with a pending bell turns red, and activity shows in yellow (nord palette).
- Each row shows a Nerd Font icon for the command running in that window's content
  pane (editor, server, shell, db, AI coding agents, …); the collapsed strip shows
  the number + icon. Toggle with `@sidetabs-icons`.
- `prefix + /` opens a fuzzy-search popup over the current session's windows
  (search by name, running command, or directory) and jumps to the one you pick.
  Uses fzf when available, otherwise tmux's built-in `choose-tree`.
- Under the active window, a cmux-style summary shows the git branch + latest
  commit subject () and the working directory(ies) of its panes (), joined
  by ` | ` when there are multiple panes. Toggle with `@sidetabs-summary`.
  (Ports are intentionally omitted; bell notifications already show as a red tab.)
- `prefix + Tab` toggles between expanded and a collapsed icon-strip.
- `C-h` (your own vim-aware binding) moves left into the sidebar; `C-l` moves back out.
- When focused inside the sidebar, `C-j` / `C-k` step to the next / previous window
  and keep focus in the sidebar so you can keep browsing.

## Screenshots

**Expanded (default):**

![Expanded sidebar — window list with session header and the active window's git/dir summary](assets/sidebar-expanded.png)

**Collapsed (`prefix + Tab`):**

![Collapsed sidebar — a narrow icon strip of window numbers](assets/sidebar-collapsed.png)

## Requirements

- tmux 3.4+ (uses `set-hook`, per-pane user options, `split-window -f`)
- bash
- TPM

## Install

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'liberatoaguilar/tmux-sidetabs'
```

Then `prefix + I` to fetch and source.

### Local development install (no GitHub)

```tmux
run-shell '/path/to/tmux-sidetabs/sidetabs.tmux'
```

## Usage

| Keys | Action |
| --- | --- |
| `prefix + Tab` | Toggle the sidetab between expanded and collapsed |
| `C-h` / `C-l` | Move into / out of the sidebar (your existing vim-style bindings) |
| `C-j` / `C-k` (in sidebar) | Next / previous window (focus stays in the sidebar) |
| `C-n` (in sidebar) | New window (prompts for a name; empty = unnamed) |
| `C-r` (in sidebar) | Rename the current window (prefilled) |
| `C-x` (in sidebar) | Kill the current window (with `y/n` confirm) |
| `M-k` / `M-j` (in sidebar) | Move the current window up / down (reorder) |
| Left-click a window row (while in the sidebar) | Switch to that window; focus stays in the sidebar so you can keep clicking (needs `@sidetabs-mouse on`; no global tmux mouse) |
| `prefix + /` | Fuzzy-search this session's windows in a popup and jump to one |
| `C-c` (in sidebar) | Cycle the current window's flag color one step forward (yellow → green → blue → purple → orange → teal → indigo → slate → none) |
| `M-c` (in sidebar) | Open the flag color **picker**: a menu of live color swatches — press `1`-`8` to jump straight to a color, `0` to clear |
| `C-t` (in sidebar) | Start / pause / resume the current window's stopwatch; counting pauses when the window loses focus (hourglass glyph ⏳ = auto-held, counting resumes on focus) |
| `M-t` (in sidebar) | Open the timer menu: adjust total time, cancel current interval, or reset the timer |
| `M-n` (in sidebar) | Edit the current window's **note** in a popup (`$EDITOR`); multi-line text is kept, save an empty buffer to clear it. Windows with a note show a sticky-note glyph  |

`C-j` / `C-k` outside the sidebar keep their normal `select-pane -D/-U` behavior
(and forward to vim when a vim-like process has focus). The window-management
keys (`C-n` `C-r` `C-x` `M-k` `M-j`) only act when the sidebar is focused —
elsewhere they pass straight through to the focused pane, so your shell's `C-r`
reverse-search, `C-n` completion, etc. are untouched.

## Configuration

| Option | Default | Purpose |
| --- | --- | --- |
| `@sidetabs-toggle-key` | `Tab` | Prefix key to toggle collapse |
| `@sidetabs-expanded-width` | `20` | Cols in expanded mode |
| `@sidetabs-collapsed-width` | `5` | Cols in collapsed mode (fits number + icon) |
| `@sidetabs-skip-nav` | `on` | `off` to leave `C-j` / `C-k` untouched |
| `@sidetabs-mouse` | `off` | `on` to click a row to switch windows while the sidebar is focused (no global tmux `mouse` needed) |
| `@sidetabs-icons` | `on` | `off` to hide the per-window command icon |
| `@sidetabs-search-key` | `/` | Prefix key to open the fuzzy window-search popup (needs fzf; falls back to `choose-tree`) |
| `@sidetabs-uninstall-key` | (unset) | Prefix key to uninstall in-session |
| `@sidetabs-summary` | `on` | `off` to hide the summary under the active window |
| `@sidetabs-active-bg` | `#88c0d0` | Active-row background (nord8) |
| `@sidetabs-active-fg` | `#2e3440` | Active-row text (nord0) |
| `@sidetabs-idle-bg` | `#4c566a` | Idle-row background (nord3) |
| `@sidetabs-fg` | `#d8dee9` | Idle-row text (nord4) |
| `@sidetabs-bell-bg` | `#bf616a` | Bell-row background (nord11) |
| `@sidetabs-bell-fg` | `#eceff4` | Bell-row text (nord6) |
| `@sidetabs-activity-fg` | `#ebcb8b` | Activity text color (nord13) |
| `@sidetabs-header-bg` | `#5e81ac` | Session-name header background (nord10) |
| `@sidetabs-header-fg` | `#2e3440` | Session-name header text (nord0) |
| `@sidetabs-summary-fg` | `#81a1c1` | Summary text color (nord9) |
| `@sidetabs-rule-fg` | `#616e88` | Divider rule color |
| `@sidetabs-flag-colors` | `#ebcb8b #a3be8c #81a1c1 #b48ead #d08770 #8fbcbb #9d7cd8 #8b95a8` | Space-separated hex colors offered by `C-c` / `M-c` (yellow, green, blue, purple, orange, teal, indigo, slate). Add or remove entries freely — the picker and the cycle both size themselves to the list. No red: the bell state owns red |
| `@sidetabs-flag-names` | `yellow green blue purple orange teal indigo slate` | Picker labels, positional against `@sidetabs-flag-colors`. A shorter list is fine — unnamed slots show their hex instead |
| `@sidetabs-flag-fg` | `#2e3440` | Flag pill text color (nord0) |
| `@sidetabs-flag-key` | `C-c` | Key to cycle the current window's flag color (set to `none` to disable — applies to every key option) |
| `@sidetabs-flag-picker-key` | `M-c` | Key to open the flag color picker menu (`none` to disable) |
| `@sidetabs-timer-key` | `C-t` | Key to start / pause the current window's timer |
| `@sidetabs-timer-menu-key` | `M-t` | Key to open the timer menu (adjust total, cancel current interval, or reset) |
| `@sidetabs-timer-autofocus` | `on` | `off` to disable auto pause/resume when window loses/gains focus |
| `@sidetabs-timer-restore` | `on` | `off` to disable re-seeding timers from the event log after a tmux-resurrect restore |
| `@sidetabs-note-key` | `M-n` | Key to open the note editor popup for the current window (`none` to disable) |
| `@sidetabs-note-icon` | (sticky note) | Glyph shown on rows that have a note. Any string works — set it to something ASCII if your font lacks Nerd Font glyphs. A multi-character icon is measured and takes its columns from the window name, so a long one leaves less room for the name |
| `@sidetabs-note-store` | `~/.local/share/tmux-sidetabs/notes.tsv` | Path to the durable note store (TSV: session, window name, note — one row per noted window; newlines in the note are stored escaped as `\n`, so a row is always one line) |
| `@sidetabs-agent-status` | `on` | `off` stops any new agent signal being raised **and** hides any that is already showing (see [Agent status](#agent-status)) — the agent-side hooks can stay installed, they just stop costing anything. Flipping it off mid-turn is safe: a row that was lit at the time goes quiet immediately, and visiting the tab still clears the stored state |
| `@sidetabs-agent-done-fg` | `#a3be8c` | Color of the ✓ glyph on a finished agent's row (nord14) |
| `@sidetabs-timer-log` | `~/.local/share/tmux-sidetabs/timelog.tsv` | Path to the timer event log (TSV: timestamp, event type, interval start, interval duration, total, session, window, window_id, cwd; events are `start` / `resume` / `pause` / `auto-pause` / `auto-resume` / `adjust` / `cancel` / `reset` / `restore`) |

Example:

```tmux
set -g @sidetabs-expanded-width 24
set -g @sidetabs-toggle-key 'b'
set -g @sidetabs-active-bg '#a3be8c'
```

## Agent status

Coding agents (Claude Code, codex, opencode) run inside a pane. Point their tool
hooks at `scripts/agent_status.sh` and the sidebar tells you, at a glance, which
tabs are busy, which are waiting on you, and which are done:

| Sidebar shows | State | Meaning |
| --- | --- | --- |
| spinner + elapsed on the row (`⠹ 4m`) | `working` | the agent is off doing something |
| the whole row goes **bell-red** | `attention` | the agent is blocked on you (permission prompt, question) |
| a green ✓ on the row | `done` | the agent finished its turn |

Nothing is installed for you — wiring is deliberately on your side, in the
agent's own config. Replace `<plugin>` with the absolute path to your clone.

### Claude Code

In `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "<plugin>/scripts/agent_status.sh working" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "<plugin>/scripts/agent_status.sh attention" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "<plugin>/scripts/agent_status.sh done" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "<plugin>/scripts/agent_status.sh clear" }] }
    ]
  }
}
```

`matcher` is omitted throughout: none of these four events is tool-scoped.
`PreToolUse` is **deliberately not wired** — it fires on every single tool call,
so it would spend a process per tool to re-assert a state that `UserPromptSubmit`
already set. `UserPromptSubmit` is what makes `working` possible at all: it is
the only signal that says "a turn just started".

### codex

In `~/.codex/config.toml`:

```toml
notify = ["<plugin>/scripts/agent_status.sh", "codex-notify"]
```

codex appends its JSON payload as the last argument; the `codex-notify` mode
parses it without a `jq` dependency (bash's own regex over the `"type"` field).
It maps `agent-turn-complete` → `done` and any approval/permission/confirm-shaped
type → `attention`; **anything it does not recognize is a silent no-op**, because
a wrong signal is worse than no signal. codex has no "turn started" notification,
so codex tabs generally show `done` and `attention` but never the `working`
spinner.

Extra arguments of your own in that array are fine — they are ignored, never
mistaken for a target. The pane is taken from `$TMUX_PANE`; pass
`"--pane", "%3"` only if you need to override it.

### opencode

No adapter code is needed — a plugin/event hook that execs the same CLI works.
Map session-idle to `done` and any permission/ask event to `attention`:

```bash
<plugin>/scripts/agent_status.sh done
<plugin>/scripts/agent_status.sh attention
```

### Semantics worth knowing

- **The pane is the unit of truth, the window is what you see.** Each pane keeps
  its own state; the row shows the *worst* state in the window
  (`attention` > `working` > `done`). Two agents in one window, one asking for
  permission and one grinding, shows red.
- **Visiting a tab consumes the signal**, exactly like a bell: switching to a
  window — or just moving to another of its panes — clears `done` and `attention`
  for all of them. `working` survives a visit: it is a fact about the world, not
  a notification. That holds even when a permission prompt interrupted it, which
  is the common case — answering the prompt puts the tab back to `working`, on
  its original clock, for the rest of the turn.
- **A signal raised on the tab you are already looking at never lights up**,
  again like a bell, which tmux never raises on the current window: you were
  there when it happened, so `done` and `attention` are consumed the instant
  they arrive. (Only with a client attached — nobody attached means nobody
  looking.) `working` still shows, since it is not a notification.
- **Elapsed time doesn't restart on re-assertion.** Re-asserting the same state
  keeps the original clock (and skips the redraw entirely), so an agent that
  fires `working` on every prompt costs nothing and the row's elapsed keeps
  answering "how long has it been like this".
- **A signal cannot outlive its pane.** If the pane holding it goes away — you
  kill it, the agent crashes, the shell exits — the row is re-derived from the
  panes that are still there. An agent that dies without its `SessionEnd`/`Stop`
  hook firing cannot leave a tab spinning forever.
- **Collapsed mode shows attention only.** The red pill is a color, so it
  survives; there is no room for the spinner or the ✓.
- The whole feature switches off with `set -g @sidetabs-agent-status off` —
  including anything already on screen when you flip it.
- Invoked outside tmux, the script exits 0 in silence — safe in a shared
  `settings.json` that follows you onto machines without tmux.

## Uninstall

Either set `@sidetabs-uninstall-key` and press it, or run:

```bash
tmux run-shell '/path/to/tmux-sidetabs/scripts/uninstall.sh'
```

Then remove the plugin line from `~/.tmux.conf` and reload. (Reload restores your
original `C-h` / `C-j` / `C-k` bindings.)

## Notes

- The `C-j` / `C-k` overrides reproduce a standard vim-aware `is_vim` detection so
  that pressing them inside vim forwards to vim. `C-h` is left entirely to your own
  binding. If your `~/.tmux.conf` uses a different `is_vim` regex, set
  `@sidetabs-skip-nav off` and wire your own bindings, or edit `sidetabs.tmux`.
- Designed for tmux session continuity, not full server restarts — sidetab panes
  and their markers do not survive `kill-server`.
- `@sidetabs-mouse on` does **not** need tmux's global `mouse` option. The sidebar
  pane enables its own mouse reporting (the same way Claude Code and other TUIs do)
  and reads its own clicks, so your terminal's native text selection in other panes
  is untouched. Because tmux only delivers mouse events to the focused pane, clicks
  register only while the sidebar is focused — the workflow is `C-h` into the
  sidebar, then click a row to jump to that window. Takes effect on the next config
  reload (or when the sidebar panes are recreated).
- **Flag colors**: `C-c` steps forward through the palette (fast when you just want
  *some* color); `M-c` opens a picker menu showing each color as a real swatch, with
  the current one marked, so you can jump straight to one with a number key. Both act
  on the same per-window state, so they're interchangeable.
- The palette is an ordered list and the window option stores an **index** into it, so
  reordering `@sidetabs-flag-colors` recolors existing flags. Append new colors at the
  end to avoid that.
- Bell notifications (red row) always outrank flag colors — a window with a pending
  bell displays in red regardless of its flag.
- **Timer behavior**: When a timer is running in a focused window, it counts only while
  that window is active (selected). Switching to another window auto-pauses the timer
  (shown with the hourglass glyph ⏳); returning to that window auto-resumes it (disable
  with `@sidetabs-timer-autofocus off`). Manually pausing with `C-t` is sticky — the
  timer will not auto-resume on focus; press `C-t` again to manually resume. Detaching
  from tmux (closing your terminal) does **not** auto-pause the timer — use the adjust
  menu (`M-t` → "adjust total…") to correct a forgotten timer. Adjust accepts: `+15m`,
  `-90`, `1:30:00` (hours:minutes:seconds), `10:00` (minutes:seconds), or a bare number
  for seconds; the total is clamped at 0.
- **Timers survive restarts** (with tmux-resurrect/continuum): live state is
  session-only, but the post-restore hook replays the timer log — the durable
  record — and re-seeds each window's total, matching windows by session +
  window *name* (ids change across restarts; renamed windows don't match, and
  with duplicate names only the lowest-indexed window is seeded). A timer that
  was running comes back auto-held and resumes when its window regains focus; a
  manual pause comes back paused; a reset timer stays gone. Each re-seed logs a
  `restore` event. Seconds between the last logged event and the server dying
  are not recoverable. Disable with `@sidetabs-timer-restore off`. Flag colors
  have no durable record and still reset with the server.
- Killing a window with a running timer silently drops the unlogged in-flight interval —
  if timing a long task, pause first to ensure it's logged.
- Timers use wall-clock time: laptop sleep counts toward elapsed time. The timer
  continues even when the sidebar is collapsed.
- **Notes**: `M-n` (sidebar focused) opens the current window's note in a popup
  running your `$EDITOR`. **Multi-line notes are preserved** — reopening the
  popup gives you the note back exactly as you wrote it. The buffer is stripped
  of control characters, spaces collapse and trim per line, blank-line runs
  squeeze to a single break, and the text is capped at 200 characters. Saving an
  empty buffer clears the note. Newlines are escape-encoded (`\` → `\\`, newline
  → `\n`) in the stored form, so the window option and the TSV store rows stay
  single-line. The row shows the note's **presence** only — a sticky-note glyph
  after the window flags, never the text — and only in expanded mode (the
  collapsed strip has no room for it). Notes survive restarts on their own: every
  edit writes through to `@sidetabs-note-store`, and the post-restore hook
  re-seeds live windows from it, matched by session + window *name* (so renaming
  a window detaches its stored note until you next edit it, and with duplicate
  names only the lowest-indexed window is seeded). A window that already has a
  note is never overwritten by a restore.

## tmux-resurrect integration

Add all three hooks to `.tmux.conf` (paths to your clone):

```tmux
set-option -g @resurrect-hook-pre-restore-all  'bash <plugin>/scripts/resurrect_pre.sh'
set-option -g @resurrect-hook-post-restore-all 'bash <plugin>/scripts/resurrect_post.sh'
set-option -g @resurrect-hook-post-save-all    'bash <plugin>/scripts/resurrect_scrub.sh'
```

pre/post suppress duplicate sidebars during a restore, adopt the restored strips
in place, move focus off the sidebar into a content pane, and restore timers and
notes.
The post-save scrub rewrites the sidebar strip lines inside the resurrect save
file (cwd -> the window's first content pane's cwd; active flag -> that pane):
without it, tmux-resurrect builds every window with `new-window -c <first
pane's cwd>` — and the strip is always pane 0 — so every restored window's
base shell would open in the sidebar's directory, focused on the strip.

## Tests

```bash
./tests/smoke.sh
```

Spins up a temporary tmux server (`tmux -L sidetab_test_$$`) and asserts sidetab
creation, auto-creation on new windows, and the collapse toggle.

The other suites cover one feature area each and run the same way — a throwaway
server on its own socket, always with `-f /dev/null` so your `~/.tmux.conf`
cannot leak in:

```bash
./tests/features_smoke.sh        # flag colors + focus-aware timers
./tests/visibility_smoke.sh      # the render loop's visibility gate
./tests/resurrect_smoke.sh       # tmux-resurrect pre/post hooks
./tests/resurrect_scrub_smoke.sh # post-save rewrite of the save file
./tests/timer_restore_smoke.sh   # re-seeding timers from the event log
./tests/notes_smoke.sh           # per-window notes + durable store
./tests/agent_status_smoke.sh    # agent status: aggregation, visit-clear, render
```
