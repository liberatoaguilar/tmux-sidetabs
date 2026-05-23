# tmux-sidetabs

A persistent left-side window-list sidebar for tmux. Inspired by [cmux](https://cmux.com/)'s vertical tabs.

- Auto-spawns a thin pane on the left of every window.
- Lists the windows in the current session with `▸` (active), `•` (activity), or blank markers.
- `prefix + Tab` toggles between expanded (`▸1 main`) and collapsed icon-strip (`▸1`) modes.
- `C-h` is wrapped to skip the sidetab while preserving vim split-navigation forwarding.
- When focused inside the sidetab, `C-j` / `C-k` step to the next / previous window.

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
| `C-h` | Move focus left, skipping the sidetab (forwards to vim) |
| `C-j` / `C-k` (in sidetab) | Next / previous window |

## Configuration

| Option | Default | Purpose |
| --- | --- | --- |
| `@sidetabs-toggle-key` | `Tab` | Prefix key to toggle collapse |
| `@sidetabs-expanded-width` | `20` | Cols in expanded mode |
| `@sidetabs-collapsed-width` | `4` | Cols in collapsed mode |
| `@sidetabs-skip-nav` | `on` | `off` to disable the `C-h` / `C-j` / `C-k` overrides |
| `@sidetabs-uninstall-key` | (unset) | Prefix key to uninstall in-session |

Example:

```tmux
set -g @sidetabs-expanded-width 24
set -g @sidetabs-toggle-key 'b'
```

## Uninstall

Either set `@sidetabs-uninstall-key` and press it, or run:

```bash
tmux run-shell '/path/to/tmux-sidetabs/scripts/uninstall.sh'
```

Then remove the plugin line from `~/.tmux.conf` and reload. (Reload restores your
original `C-h` / `C-j` / `C-k` bindings.)

## Notes

- The `C-h` / `C-j` / `C-k` overrides reproduce a standard vim-aware `is_vim`
  detection so that pressing them inside vim forwards to vim. If your `~/.tmux.conf`
  uses a different `is_vim` regex, set `@sidetabs-skip-nav off` and wire your own
  bindings, or edit `sidetabs.tmux`.
- Designed for tmux session continuity, not full server restarts — sidetab panes
  and their markers do not survive `kill-server`.

## Tests

```bash
./tests/smoke.sh
```

Spins up a temporary tmux server (`tmux -L sidetab_test_$$`) and asserts sidetab
creation, auto-creation on new windows, and the collapse toggle.
