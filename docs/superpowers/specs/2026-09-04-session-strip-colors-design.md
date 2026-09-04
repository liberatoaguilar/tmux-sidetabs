# Session strip colors + durable flag colors

Date: 2026-09-04
Status: approved design, not yet implemented

## Problem

Two gaps, one shared root.

1. **Sessions have no color.** The bottom bar renders one pill per session, but a
   pill can only be red (bell), blue (current) or grey (everything else). With ten
   sessions there is no way to mark one.
2. **Window flag colors do not survive a restart.** `flag_cycle.sh` and
   `flag_set.sh` write only a tmux window user-option, and tmux-resurrect does not
   save user options. `README.md:293` states it plainly: *"Flag colors have no
   durable record and still reset with the server."*

The shared root is that both live in volatile tmux options with no durable record —
the same problem notes and timers already solved, twice, with the same pattern.

A third, smaller problem is folded in because it is the same code: the session strip
currently lives outside this repo, in `~/.tmux.conf`'s `status-left` plus
`~/.config/tmux/strip-pills.sh`, and **nothing invokes `strip-pills.sh`**. The conf's
own comment promises hooks that the conf never installs, so `@strip_next` is
maintained only by whatever was set live in a running server. That is why the
separator style changes across restarts.

## Goals

- A per-session color, set from the sidebar, visible in the bottom strip.
- Window and session colors survive a resurrect/continuum restart.
- The strip becomes plugin-owned, tested, and versioned.
- Classic powerline separators: the solid arrow (`>==>`) at every real color
  boundary, a thin chevron on a same-background join.
- The strip degrades gracefully as it runs out of width.

## Non-goals

- Multi-session switching UI (still deferred, see roadmap).
- Collapsing grouped sessions into one pill.
- Fixing the `awk -v` backslash wart in `note.sh` / `timer_restore.sh` (new code
  avoids it; the existing sites are left alone).
- Per-client width when two clients share one session (narrowest wins).

## Decisions

Settled during design review. Recorded because several are non-obvious.

| # | Decision | Rationale |
|---|---|---|
| D1 | Plugin owns the strip | Testable, versioned, and hooks wired in `sidetabs.tmux` survive a restart |
| D2 | Precedence `bell\|attention > flag > current > idle` | Same rule as sidebar window rows |
| D3 | `▎` marker only when the current session is *flagged* | An unflagged current session keeps today's look exactly |
| D4 | `M-s` picker only, no cycle key | A session color is set once; a window flag is flipped daily |
| D5 | Store is snapshot-**merge** | Self-heals renames/deletes; a closed session keeps its color for its return |
| D6 | One store file, empty middle field = session row | One lock, one restore pass |
| D7 | Sessions share `@sidetabs-flag-colors` | One palette; a second one stays backward-compatible to add later |
| D8 | Agent `attention` rolls up to the session pill | Highest-value signal in a ten-session strip |
| D9 | Session color also tints the sidebar header pill | Makes the color mean something where you actually work |
| D10 | ~~Uninstall restores nothing~~ — **superseded.** Uninstall unsets the status-line options per session | The original rationale ("a conf reload does it for free") was simply **wrong**; see [D10 was wrong](#d10-was-wrong) below |
| D11 | Strip defaults **off** | README ships TPM install instructions; a sidebar plugin must not eat your status bar |
| D12 | Fix `uninstall.sh`'s bare-name hook unset | It currently nukes tmux-ticker's `-ga` handlers |
| D13 | **Generate `status-left` in bash**, drop `#{S:}` | Kills `@strip_next` — the mechanism that goes stale across restarts |
| D14 | Solid `` at a color boundary; thin `` at a same-background join | The classic powerline rule. A solid arrow between two same-colored pills either vanishes into the surface or, inked for contrast, reads as a heavy dark wedge between pills that are the same color. **Revised** — see [D14 was revised](#d14-was-revised) |
| D15 | Debounced regenerate with a `force` escape | Matches `refresh.sh`; restore must not be dropped |
| D16 | Shrink cascade, not clipping | The bar will run out of width soon |
| D17 | **One generated string per session** | `status-left` is a per-session option; makes "current" static and the width budget accurate |
| D18 | Sacrifice order: marker → right side → left pills → names → initials → blocks | Time/date/user are already in the macOS menu bar |
| D19 | Edges are *lists* of pills, dropped one at a time, outermost first | Avoids a cliff at the edge-drop stage |
| D20 | Floor form is `▎<current> +N` | Truthful at any width; never leaves you guessing where you are |
| D21 | Bell + attention only; not activity or silence | Activity fires on any output; a bar that always blinks stops being read |
| D22 | One pill per session, grouped or not | Matches today; a collapsed group would hide a `switch-client -n` target |

## Verified tmux facts

Measured on **tmux 3.6b** (macOS arm64) against scratch sockets. These are
load-bearing; several contradict the documentation.

1. **`#{session_bell_flag}` is broken — always `0`.** Upstream
   `format_cb_session_bell_flag` has an `RB_FOREACH` whose body `return`s
   unconditionally on the first iteration, so only the lowest-index window is ever
   examined. `session_activity_flag` and `session_silence_flag` are worse: they test
   the *format target's* winlink, not the loop variable, so they merely mirror
   `#{window_*_flag}`. **Do not use any of the three.** Per-window
   `#{window_bell_flag}` is correct, and bash aggregates it.
2. `#{session_alerts}` is `<idx>` + `#` (activity) / `!` (bell) / `~` (silence),
   comma-separated, e.g. `1#!,2#,3#~`. An undocumented `#{session_alert}` (singular)
   is the clean per-session union. Neither is needed under D13.
3. **`status-left` and `status-right` are per-session options.** `set-option -t A
   status-left AAA` and `-t B ... BBB` hold independently. This is what makes D17
   possible.
4. **The argv path caps at ~16KB** ("command too long", measured in bytes — the same
   ceiling that capped notes). **`printf … | tmux source-file /dev/stdin` bypasses it
   entirely**: a 40,000-byte option value and 131KB of chained commands both applied.
5. **Cost is ~5ms per `tmux` process invocation and ~0 per command.** One chained
   invocation with 10 `set-option`s costs the same as one with a single one. Batch
   everything into one `source-file`.
6. **Truncation is a hard cut by display column** — no ellipsis, no marker. Style
   escapes do not count toward the length. A 2-column glyph that does not fit is
   dropped whole. `status-left-length` caps at 32767; client width clips
   independently.
7. Style bodies interpolate: `#[#{@opt}]` where the option holds
   `fg=black,bg=#a3be8c,bold` works, because format expansion runs *before* style
   parsing. Two traps: a `]` inside the value terminates the style early, and
   **uppercase hex corrupts under a second expansion** (`#D` is the `pane_id` alias)
   — so **always emit lowercase hex**. Not needed under D13, but the lowercase rule
   still applies to generated output.
8. `#{S:}` has no observable item or total limit (80 items, 165KB, no truncation).

## State model

Two per-entity options, same encoding, same palette:

| Option | Scope | Value |
|---|---|---|
| `@sidetabs_flag` *(exists)* | window | 1-based index into `@sidetabs-flag-colors`; unset = none |
| `@sidetabs_sflag` **(new)** | session | same |

Palette order stays API: the stored value is an index, so reordering
`@sidetabs-flag-colors` recolors existing flags, sessions included.

## Architecture: `scripts/strip.sh`

Regenerates `status-left` (and optionally `status-right`) as a literal string, once
per session, on every relevant event. There is no `#{S:}` loop and no
`@strip_next`/`@strip_first` bookkeeping — a generator knows every neighbor
directly.

```
strip.sh [force]
  1. gate on @sidetabs-session-strip == on, else exit 0
  2. debounce 100ms via @sidetabs_strip_last_ms unless $1 == force
  3. enumerate sessions in stable creation order:
       list-sessions -F '#{session_id}\t#{session_name}' | sed 's/^\$//' | sort -n
  4. aggregate state in ONE call:
       list-windows -a -F '#{session_id}\t#{window_bell_flag}\t#{@sidetabs_agent}'
     -> per session: bell = any window flagged; attention = any window == attention
  5. read @sidetabs_sflag per session (from the list-sessions format, free)
  6. per-session width budget:
       min(#{client_width}) over clients attached to that session,
       else @sidetabs-strip-assumed-width (default 200)
  7. for each session S: resolve every pill, run the cascade, emit
       set-option -t S status-left  "<literal>"
       set-option -t S status-right "<literal>"   (only if owned)
       set-option -t S status-left-length  <budget>
       set-option -t S status-right-length <budget>
     (the cascade has already fitted left + right + reserved <= budget, so
      setting each length to the full budget cannot cause them to collide)
  8. deliver ALL of it in one   printf … | tmux source-file /dev/stdin
```

Because the string for session S is only ever rendered by clients attached to S,
"is this pill the current session" is known **statically at generation time**. No
`#{?#{==:…,#{client_session}}}` conditional survives into the output.

Two clients attached to the same session with different widths: narrowest wins.

### Color resolution

Per session, first match wins:

| Condition | bg | fg | attr |
|---|---|---|---|
| bell OR agent attention | `@sidetabs-strip-bell-bg` `#bf616a` | `@sidetabs-strip-bell-fg` `#eceff4` | bold |
| `@sidetabs_sflag` set | palette[idx] | `@sidetabs-flag-fg` | bold |
| is the current session | `@sidetabs-strip-current-bg` `blue` | `black` | bold |
| otherwise | `@sidetabs-strip-idle-bg` `brightblack` | `@sidetabs-strip-idle-fg` `white` | nobold |

All emitted hex is lowercase (fact 7).

### Separator rule

Every separator is the trailing cell of the pill to its left. **Which glyph it is
depends on whether there is a color boundary there at all** — the classic
powerline rule:

- **backgrounds differ** — a real boundary: the solid `` (U+E0B0), `fg` = left
  pill's bg, `bg` = right pill's bg. Standard powerline; the arrow reads as the
  left pill's own edge cutting into the next one. **Not configurable**: there is
  one right glyph for a boundary and this is it.
- **backgrounds match** — nothing to cut: the thin `` chevron
  (`@sidetabs-strip-sep-glyph`, default U+E0B1) drawn on the shared background.
  Ink is `@sidetabs-strip-sep-fg`, whose default is the **sentinel `match`**,
  meaning *the left pill's own foreground* — a white-on-grey session pill gets a
  white-ish chevron, a black-on-cyan sysinfo pill a black-ish one. Any other
  value is a literal color applied at every same-background join.
- **last pill**: the "right pill" is the bar background
  (`@sidetabs-strip-bg`, default `black`) and the same match/differ test applies.

Both glyphs are **one display column**, so a join costs the width cascade exactly
1 either way and no stage needs to know which one it will get.

### Edge pills

Numbered options rather than a delimited list — no escaping rules, and a `#(shell |
pipeline)` in a pill can't break parsing:

```tmux
set -g @sidetabs-strip-left-1 "#(…/scripts/sysinfo.sh load)"
set -g @sidetabs-strip-left-2 "#(…/scripts/sysinfo.sh mem)"
set -g @sidetabs-strip-left-3 "#(…/scripts/sysinfo.sh disk)"
set -g @sidetabs-strip-left-1-bg cyan     # optional, per pill
set -g @sidetabs-strip-left-1-fg black
```

Scanned `1..16`, stopping at the first gap. `@sidetabs-strip-right-N` is identical.
A side with no `-1` set is **never written by the plugin** (D11), but it is still
**measured and reserved** so the strip cannot overrun content the user owns. The
measurement expands that side with `#{T:...}`, strips `#[...]` sequences, and counts
the remainder. The `#(` test must run on the **raw** value, not the expansion:
verified on 3.6b, `#(echo hi) %H:%M` expands to ` 11:36` — the job leaves no `#(`
behind, so testing the expansion would never fire. A shell command's width is
unknowable synchronously (jobs are scheduled asynchronously), so each one adds a
fixed estimate, and a numeric `@sidetabs-strip-reserve` replaces the estimate
entirely. An unowned side
is reserved but never dropped, so its stage in the cascade is skipped.

`sysinfo.sh` grows an optional argument (`load` | `mem` | `disk`, default: all three
as today) so it can be split across pills. Three invocations per `status-interval`
instead of one — about 20 forks per 5s rather than 7.

### Width cascade

Width is counted in **characters**, matching `render.sh`'s existing convention
(`${#label}`, `${label:0:avail}`), with Nerd Font glyphs counted as one column. A
CJK session name will misalign, exactly as a CJK window name does today.

A pill costs `1 + len(name) + 1 + 1` (padding, name, padding, separator); the marker
adds 1.

Stages apply in order until the total fits the budget:

| Stage | Action |
|---|---|
| 0 | Everything: marker, full names, all edge pills |
| 1 | Drop the `▎` marker (current session keeps bold + color). No-op when the current session is unflagged, since D3 means no marker was drawn |
| 2 | Drop right pills, **outermost first**, one per stage |
| 3 | Drop left pills, **outermost first**, one per stage |
| 4 | Truncate names to 12, then 8, then 6, then 4 |
| 5 | Non-current *unflagged* sessions → single initial |
| 6 | Non-current *unflagged* sessions → color block, no text |
| 7 | Floor: `▎<current session> +N`. The marker is **always** drawn here regardless of D3 — at this width it is the only thing identifying the pill |

Stages 5 and 6 never touch a flagged or bell/attention pill — the pills carrying
information you deliberately set are the last to degrade. `@sidetabs-strip-name-max`
(default `0` = no limit) applies a hard cap at stage 0 for users who want short names
unconditionally.

Regeneration is triggered by `client-resized`, so dragging a terminal across a stage
boundary will pop the clock or a sysinfo pill in and out. Accepted; no hysteresis.

## Persistence

New store, deliberately shaped like the notes store:

- Path: `@sidetabs-flag-store`, default
  `${XDG_DATA_HOME:-$HOME/.local/share}/tmux-sidetabs/flags.tsv`
- Rows, tab-separated:
  - `session_name` ⇥ `window_name` ⇥ `index` — a window flag
  - `session_name` ⇥ *(empty)* ⇥ `index` — a session color

**Snapshot-merge** (D5). On any flag change, `flag_store_sync`:

1. reads the current store into memory,
2. for every **live** session and window, sets that key's row to the live value —
   or **removes** the row if the flag is now unset (so clearing persists),
3. leaves rows for keys that are not currently live untouched,
4. writes to `${f}.tmp.$$` and `mv`s it into place, under the mkdir lock.

Consequences, accepted: stale rows are never pruned (bytes), and a *new* session
reusing an old name inherits that name's color — judged correct, not a bug.

`store_lock` / `store_unlock` (mkdir as mutex; macOS has no `flock(1)`) move from
`note.sh` into `helpers.sh`, and `note.sh` is switched to the extracted version.
`notes_smoke.sh`'s 21 sections are the regression net.

New store code uses `awk`'s `ENVIRON` rather than `-v s="$name"`, because `awk -v`
processes escape sequences and would silently fail to match a name containing a
literal `\t`. The existing sites in `note.sh` and `timer_restore.sh` keep the wart.

## Restore

`scripts/flag_restore.sh [boot]`, modelled directly on `timer_restore.sh`:

- gate: `@sidetabs-flag-restore` (default `on`)
- `boot` mode: stand down if `@sidetabs_flag_restored` is `1`, or if
  `@sidetabs_restoring` is `1`, or if the server is older than `BOOT_MAX_AGE_S`;
  claim the generation by setting `@sidetabs_flag_restored=1`
- match by **session name**, and by **(session name, window name)** for windows —
  ids do not survive a restart. First window with a given name wins.
- **never clobber a live flag**: skip any session/window that already has one
- finish with `strip.sh force`

Called from `resurrect_post.sh` immediately after `note.sh restore`, and from
`client-attached[3]` in `boot` mode for the case where tmux-continuum declines to
auto-restore.

## Wiring

New hooks in `sidetabs.tmux`, on indices free of both sidetabs and tmux-ticker:

| Hook | Runs |
|---|---|
| `session-created` | `strip.sh` |
| `session-closed` | `strip.sh` |
| `session-renamed` | `strip.sh` + `flag_store.sh sync` |
| `alert-bell` | `strip.sh` |
| `client-resized` | `strip.sh` |
| `client-session-changed[2]` | `strip.sh` |
| `client-detached[2]` | `strip.sh` |
| `client-attached[3]` | `flag_restore.sh boot` |
| `client-attached[4]` | `strip.sh` |
| `window-renamed[1]` | `flag_store.sh sync` |

`agent_status.sh` calls `strip.sh` when it raises or clears `attention`, since agent
state is invisible to tmux's own alert machinery (its own comment at
`agent_status.sh:221-226` explains why it mimics bell semantics rather than using
them).

Load order note: sidetabs loads before tmux-ticker in the user's conf, so sidetabs
claims low indices and ticker's `-ga` appends land above them. Reordering the two
plugins would shuffle indices.

### Key binding

`@sidetabs-session-flag-key`, default `M-s`, bound in `sidetabs.tmux` beside
`C-c`/`M-c` with the same `#{@is_sidetab}==1` gate and `send-keys` pass-through, and
the same `none` opt-out. It runs `session_flag_picker.sh <session_id> <client>`,
whose menu items run `session_flag_set.sh <session_id> <index|none>`.

`session_flag_set.sh` sets `@sidetabs_sflag`, calls `flag_store_sync`, then
`strip.sh force` and `refresh.sh force` (the latter for the header tint).

## Sidebar header tint (D9)

`render.sh:204-235`'s `emit_header` uses the session's flag color as the header pill
background when `@sidetabs_sflag` is set, with `@sidetabs-flag-fg` as foreground;
otherwise it keeps `@sidetabs-header-bg` / `-fg` exactly as today. The option is
added to the existing batched `READ_STATE_FMT` at `render.sh:485`, so it costs no
extra tmux call.

## `uninstall.sh` fix (D12)

Today `uninstall.sh:13-18` unsets thirteen hooks by bare name, and its own comment
records that *"Naming an array hook without an index clears EVERY index (verified on
tmux 3.6)"* — so it rips out tmux-ticker's `-ga` handlers on the five hook names the
two plugins share (`after-new-window`, `after-new-session`, `window-renamed`,
`window-layout-changed`, `session-window-changed`).

Fix: unset only the specific indices sidetabs claims, as a static list mirroring
`sidetabs.tmux`, plus a **drift test** that greps both files and fails if the sets
disagree. A failing test is a louder alarm than a silent mismatch, and it costs less
machinery than recording claimed indices in a global option (which can itself go
stale across a plugin upgrade).

Uninstall also unbinds `@sidetabs-session-flag-key`.

## D10 was wrong

This document originally decided (D10) that uninstall should leave `status-left` /
`status-right` exactly as the plugin last set them, "because a conf reload restores
them — they come from the conf". `uninstall.sh` shipped with that reasoning written
into a comment. **It is false**, and it was verified false on tmux 3.6b:

- `status-left` is a **per-session** option, and `strip.sh` sets it per session —
  that is D17, the design's own central decision.
- A session-scoped value **completely shadows** the global one. With
  `set-option -t alpha status-left SESSION_LEFT` in force, a later
  `set -g status-left GLOBAL_LEFT` renders nothing, and
  `display-message -t alpha -p '#{status-left}'` still answers `SESSION_LEFT`.
- So a conf reload restores nothing. It rewrites a global that the leftover
  per-session value is hiding. Only `set-option -u -t <session> status-left` —
  dropping the session-scoped value so the global shows through — puts the bar back.

The mistake was reasoning about *where the value came from* (the conf) instead of
*at which scope the plugin wrote it* (the session). Every other option this plugin
touches is either global or user state, so "reload the conf" had always been a
sufficient answer before the strip existed; the strip is the first thing the plugin
writes at session scope, and the old rule was carried over without rechecking it.

It was worst exactly where it mattered most: once a conf stops setting `status-left`
at all — which is what happens when the strip takes the side over — there is nothing
left to reload *back*, so the user is stranded with the plugin's generated bar and no
obvious way out. Ticket 08's acceptance criterion ("uninstalling the plugin and
reloading the config restores the previous status line") did not hold as written.

**Corrected decision.** `uninstall.sh` unsets, in one batched `source-file` (the same
idiom `strip.sh` installs with, one fork rather than ~5ms per session):

- `status-left` and `status-left-length` on **every** session, always;
- `status-right` and `status-right-length` only when `@sidetabs-strip-right-1` is
  set — the exact condition under which `strip.sh` writes that side. Unsetting a
  side the plugin never wrote would destroy the user's own content, which is the
  one thing the reserve machinery in §5c exists to avoid;
- the plugin's own bookkeeping globals (debounce stamps, the restore claims). User
  state — flags, timers, notes, session colours — is deliberately untouched: an
  uninstall is not a delete.

A failed `list-sessions` skips the per-session part entirely rather than
half-restoring, per the house rule that a failed operation is a no-op, never a clear.
`tests/uninstall_hooks_smoke.sh` §3 asserts all three outcomes on a scratch server.

## Configuration surface

| Option | Default | Purpose |
| --- | --- | --- |
| `@sidetabs-session-strip` | `off` | Master switch for the bottom strip |
| `@sidetabs-session-flag-key` | `M-s` | Sidebar key opening the session color picker |
| `@sidetabs-flag-store` | `…/tmux-sidetabs/flags.tsv` | Durable store for window + session colors |
| `@sidetabs-flag-restore` | `on` | Re-seed colors after a restore |
| `@sidetabs-strip-left-N` | *(unset)* | Left pill N (1..16); unset = plugin ignores that side |
| `@sidetabs-strip-right-N` | *(unset)* | Right pill N (1..16) |
| `@sidetabs-strip-left-N-bg` / `-fg` | theme | Per-pill colors |
| `@sidetabs-strip-sep-fg` | `match` | Ink for the thin separator where neighbors share a background; the sentinel `match` = the pill's own fg |
| `@sidetabs-strip-sep-glyph` | `` (U+E0B1) | Glyph for a same-background join; the boundary arrow is fixed |
| `@sidetabs-strip-current-marker` | `▎` | Marker on a flagged current session |
| `@sidetabs-strip-current-bg` | `blue` | Current-session pill background |
| `@sidetabs-strip-idle-bg` / `-fg` | `brightblack` / `white` | Unflagged pill |
| `@sidetabs-strip-bell-bg` / `-fg` | `#bf616a` / `#eceff4` | Bell / agent-attention pill |
| `@sidetabs-strip-bg` | `black` | Bar background, for the trailing arrow |
| `@sidetabs-strip-name-max` | `0` | Hard cap on session name length (0 = none) |
| `@sidetabs-strip-assumed-width` | `200` | Budget for a session with no attached client |
| `@sidetabs-strip-reserve` | `auto` | Columns to reserve for an unowned side whose width cannot be measured (a `#(shell)` in it) |

Reused unchanged: `@sidetabs-flag-colors`, `@sidetabs-flag-names`,
`@sidetabs-flag-fg`.

## Testing

All tests follow the existing convention: `tmux -L sidetab_<tag>_$$ -f /dev/null`
(the `-f /dev/null` is mandatory — the user's `~/.tmux.conf` run-shells this plugin),
`trap cleanup EXIT` killing the server and removing temp stores, hermetic store paths
under `${TMPDIR:-/tmp}`, `fail()`/`pass()` helpers.

**`tests/strip_smoke.sh`** — asserts the generated string directly via
`show-options -t <session> -v status-left`, needing no attached client:
pill order matches session-id order; the current pill is highlighted in its *own*
session's string and not in another's; precedence bell > flag > current > idle;
agent `attention` colors the pill like a bell; a color boundary draws `` and a
same-background join draws ``, asserted by count so "an arrow somewhere" cannot
pass; the same-background ink defaults to the pill's own fg and an explicit
`@sidetabs-strip-sep-fg` overrides it; every cascade stage at forced budgets
via a `SIDETABS_STRIP_TEST_WIDTH` override; the `+N` floor; emitted hex is lowercase.

**`tests/flag_restore_smoke.sh`** — store round-trip for both row shapes; clearing a
flag removes its row; a closed session's row survives a sync; restore matches by name
after a simulated restart; restore never clobbers a live flag; a dangling/garbage
index is ignored; a session name containing a literal backslash-t still matches
(the `ENVIRON` guarantee).

**`tests/uninstall_hooks_smoke.sh`** — the drift check between `sidetabs.tmux` and
`uninstall.sh`, plus a regression asserting that a foreign `-ga` handler registered
above sidetabs' indices survives an uninstall. §3 covers the status-line restore
that supersedes D10: on a scratch server where the strip is live, uninstall must
leave every session's `status-left` unset (so the global renders again), must leave
a `status-right` it never owned exactly as it found it, and must unset one it did
own. Each assertion is made both on the session-scoped option and on
`display-message -p '#{status-left}'`, which is what a client actually renders.

## Implementation order

Three separable subsystems. Each ships and is reviewable on its own, so the
implementation plan should sequence them rather than treat this as one change.

**A. Durable flag colors** — `helpers.sh` lock extraction, `flag_store.sh`,
`flag_restore.sh`, write-through from `flag_cycle.sh` / `flag_set.sh`, the
`resurrect_post.sh` and `client-attached[3]` wiring, `flag_restore_smoke.sh`.
Depends on nothing; closes the gap `README.md:293` admits. Ships alone.

**B. Session color state** — `@sidetabs_sflag`, `session_flag_set.sh`,
`session_flag_picker.sh`, the `M-s` binding, the header tint in `render.sh`, and the
session rows in the store from A. Depends on A for persistence. Visible without the
strip, via the sidebar header.

**C. The strip** — `strip.sh`, the cascade, edge pills, `sysinfo.sh`'s argument, the
hook wiring, the `uninstall.sh` fix, `strip_smoke.sh`, `uninstall_hooks_smoke.sh`,
and the `~/.tmux.conf` cutover. Depends on B for the colors it renders.

The `uninstall.sh` fix (D12) is independent of all three and can land first if
convenient — it is a bug fix, not part of this feature.

## Known limitations

- Width is counted in characters, so CJK session names misalign (matches existing
  sidebar behavior).
- Cascade stages flap when a terminal is resized across a boundary; no hysteresis.
- Stale store rows are never pruned; a reused session name inherits an old color.
- Two clients on one session share the narrowest budget.
- Hook indices assume sidetabs loads before tmux-ticker.

## Deferred

- Hysteresis on cascade transitions.
- Per-client rather than per-session width.
- Collapsing grouped sessions.
- Fixing `awk -v` in `note.sh` and `timer_restore.sh`.
- A separate `@sidetabs-session-flag-colors` palette.

## D14 was revised

D14 originally read "solid `` everywhere; dark ink at same-color joins", and
`@sidetabs-strip-sep-fg` defaulted to `#2e3440` to keep such an arrow visible.
Rendered live, that is a row of heavy near-black filled triangles: one between
every pair of same-colored sysinfo pills, and one between every pair of adjacent
grey session pills. Nothing about those joins is a boundary, so drawing the
boundary glyph at them states something false and does it loudly.

The revision is the classic powerline rule, both halves of it. A **boundary**
still gets the solid `` in the left pill's background — that is the `>` look the
strip is built around and it is unchanged, and it is now explicitly not
configurable. A **same-background** join gets the thin `` chevron instead, on
the shared background, in an ink that belongs to the pill rather than being
foreign to it: `@sidetabs-strip-sep-fg`'s default becomes the sentinel `match`,
meaning the pill's own foreground. An explicit color still overrides it, so the
ink remains a one-line taste test.

Both glyphs occupy one display column, so nothing in the width cascade changes:
a join still costs 1.
