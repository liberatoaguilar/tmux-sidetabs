#!/usr/bin/env bash

# Per-pane user options
SIDETAB_MARKER="@is_sidetab"
RENDER_PID_OPTION="@sidetabs_render_pid"

# Global flag (set during a tmux-resurrect restore): create_sidebar.sh stands
# down while it's "1" so the restore can't spawn duplicate sidetabs; the
# resurrect post-restore hook clears it and rebuilds clean sidebars.
RESTORING_OPTION="@sidetabs_restoring"

# Global flag, one per server generation (it dies with the server, exactly like
# the timer state it guards): "1" once a timer restore has run here. The
# client-attached fallback in sidetabs.tmux stands down while it is set, so the
# fallback and a tmux-resurrect restore never both seed the same generation.
TIMER_RESTORED_OPTION="@sidetabs_timer_restored"

# The same once-per-generation claim for FLAG colours (flag_restore.sh). Kept
# separate from the timer's flag on purpose: the two restores have independent
# master switches, so one being disabled must not make the other's fallback
# think the generation is already seeded.
FLAG_RESTORED_OPTION="@sidetabs_flag_restored"

# Global flag held for the DURATION of a flag restore (flag_restore.sh, both
# delivery paths). flag_store.sh stands down while it is "1", because the store
# is a whole-state SNAPSHOT: a sync landing between "the windows exist" and
# "their flags have been re-seeded" would record every one of them as
# legitimately unflagged and DELETE the very rows the replay was about to use.
# window-renamed[1] and session-renamed[1] both fire flag_store.sh sync, and
# either can land in that gap, so the gap has to be closed rather than hoped
# past.
#
# WHY THIS IS NOT @sidetabs_restoring. The resurrect path is already covered by
# that one (resurrect_pre.sh raises it before the restore and resurrect_post.sh
# drops it after), but it means MORE than "a flag replay is in flight":
# create_sidebar.sh also stands down while it is set, so raising it around the
# client-attached `boot` restore — which runs on an ordinary, fully-live server
# that continuum declined to restore into — would silently stop sidebars being
# created for the duration. One flag per meaning: this one says only "do not
# snapshot the flag store right now", and it is the one flag_store.sh checks
# alongside @sidetabs_restoring.
#
# flag_restore.sh clears it from a trap, so a failure, a `set -e` abort or a
# signal cannot leak it: a leaked "1" would leave write-through disabled for the
# rest of the server's life, and every flag set from then on would be lost at
# the next restart — the exact data loss this guard exists to prevent.
FLAG_RESTORING_OPTION="@sidetabs_flag_restoring"

# Per-session user options
# The session's own colour. SAME encoding as FLAG_OPTION below (a 1-based index
# into @sidetabs-flag-colors, unset = none) and the SAME palette — sessions
# deliberately do not get a second colour list, so reordering the palette
# recolours window flags and session colours alike, in one place.
#
# The name is distinct from FLAG_OPTION on purpose, and not just for clarity:
# tmux resolves #{@opt} up the pane -> window -> session -> global chain, so a
# session option NAMED @sidetabs_flag would be inherited by every unflagged
# window in the session and paint every row. A separate name is the only way
# the two can coexist. (Verified on tmux 3.6b: with @sidetabs_sflag set on a
# session, `list-windows -a -F '#{@sidetabs_sflag}'` reports it for every window
# of that session and empty for other sessions — which is exactly the
# inheritance render.sh relies on to read it for free.)
SFLAG_OPTION="@sidetabs_sflag"
COLLAPSED_OPTION="@sidetabs_collapsed"
WIDTH_OPTION="@sidetabs_width"                   # current expanded width (synced)
LAST_REFRESH_OPTION="@sidetabs_last_refresh_ms"  # debounce stamp

# Per-pane user options
ROWMAP_OPTION="@sidetabs_rowmap"  # "lineidx:window_id ..." for the bg mouse reader

# Active-tab summary cache (per-session) — avoids re-spawning git every second
# across every window's sidetab. Recompute-on-miss is idempotent, so no lock.
SUMMARY_CACHE_WIN="@sidetabs_sum_win"     # window id the cache is for
SUMMARY_CACHE_AT="@sidetabs_sum_at"       # epoch ms of last compute
SUMMARY_CACHE_GIT="@sidetabs_sum_git"     # raw "branch subject" (or empty)
SUMMARY_CACHE_DIRS="@sidetabs_sum_dirs"   # raw "~/a | ~/b" (or empty)
SUMMARY_TTL_MS="2000"

# Defaults (overridable via user options)
DEFAULT_EXPANDED_WIDTH="20"
DEFAULT_COLLAPSED_WIDTH="5"   # was 4; room for "N + icon" in collapsed mode
DEFAULT_TOGGLE_KEY="Tab"
DEFAULT_SKIP_NAV="on"
DEFAULT_MOUSE="off"
DEFAULT_ICONS="on"
DEFAULT_SEARCH_KEY="/"
REFRESH_DEBOUNCE_MS="100"

# Hidden-sidebar self-heal tick (seconds). Sidebars nobody is viewing block on
# a sleep this long instead of the 0.5s redraw tick; refresh.sh's USR1 wakes
# them instantly on real events, so this only bounds staleness after a missed
# signal. Keep it long — every hidden pane pays one tmux call per tick.
HIDDEN_TICK_SECS="5"

# Width-sync feedback guard. Propagating a resize to the other windows fires
# window-layout-changed -> sync_width.sh for each of them; while armed, events
# from windows OTHER than the guard owner are ignored, so propagation can't
# re-trigger itself into an oscillation. The owning (source) window stays live.
SYNC_GUARD_OPTION="@sidetabs_sync_until"  # epoch ms until which echo-sync is suppressed
SYNC_GUARD_WIN_OPTION="@sidetabs_sync_win" # window that owns the guard (stays live)
SYNC_GUARD_MS="250"

# Per-window user options (flag/timer state; interpolated in list-windows -F,
# so render reads them with zero extra tmux calls). Session-only: tmux-resurrect
# does not save user options; the timer's durable record is the TSV log.
FLAG_OPTION="@sidetabs_flag"                # 1-based index into @sidetabs-flag-colors; unset = none
TIMER_STATE_OPTION="@sidetabs_timer_state"  # "run" | "pause" | unset
TIMER_START_OPTION="@sidetabs_timer_start"  # epoch seconds when the running interval started
TIMER_ACC_OPTION="@sidetabs_timer_acc"      # accumulated seconds from completed intervals
TIMER_TAG_OPTION="@sidetabs_timer_tag"      # opaque attribution tag (customer[:project]); unset = untagged
TIMER_LAST_RESET_OPTION="@sidetabs_timer_last_reset" # ISO date of the cycle start last reset for
NOTE_OPTION="@sidetabs_note"                # free-text note; presence shows a glyph on the row

# Agent status. Coding agents (Claude Code, codex, opencode) call
# scripts/agent_status.sh from their tool hooks to mark the PANE they run in
# working | attention | done; the per-window AGGREGATE (worst state wins) is
# what render interpolates, so a two-pane window shows one honest signal.
#
# The pane options deliberately do NOT reuse the window option's name: in a
# `list-windows -F` format tmux resolves #{@opt} starting at the window's ACTIVE
# PANE, so a same-named pane option SHADOWS the window aggregate (verified on
# tmux 3.6) and the row would show the active pane's state instead of the
# aggregate. Distinct names are the only way to read the aggregate for free.
AGENT_OPTION="@sidetabs_agent"                        # window aggregate: working|attention|done
AGENT_SINCE_OPTION="@sidetabs_agent_since"            # epoch secs the aggregate state began
AGENT_PANE_OPTION="@sidetabs_agent_pane"              # per-pane truth (same closed set)
AGENT_PANE_SINCE_OPTION="@sidetabs_agent_pane_since"  # epoch secs that pane ENTERED its state
# A pane holds ONE state, so `attention` (a permission prompt mid-turn)
# overwrites `working`. These remember what it displaced, so consuming the
# attention on a visit puts `working` back — with its original clock — instead
# of leaving the tab blank for the rest of the turn.
AGENT_PANE_PREV_OPTION="@sidetabs_agent_pane_prev"
AGENT_PANE_PREV_SINCE_OPTION="@sidetabs_agent_pane_prev_since"
# Master switch, read by agent_status.sh (write path) AND by render.sh, which
# interpolates it into the same list-windows format it already runs — gating
# only writes would let "off" freeze whatever row was on screen at the time.
AGENT_STATUS_OPTION="@sidetabs-agent-status"

# Flag/timer defaults (overridable via user options)
# Palette order is API: the window option stores a 1-based INDEX, so slots 1-4
# must keep their original colors or existing flags silently recolor. New colors
# append only. No red anywhere — the bell state owns red (#bf616a), and a flag
# within ~15 degrees of its hue would read as "bell". Hues are spread so
# adjacent picks stay tellable apart at pill size; slot 8 is desaturated on
# purpose ("parked/done" reads differently from any hue).
DEFAULT_FLAG_COLORS="#ebcb8b #a3be8c #81a1c1 #b48ead #d08770 #8fbcbb #9d7cd8 #8b95a8"
# Positional labels for the picker, one per color. A shorter list than the color
# list is fine — unnamed slots fall back to showing their hex.
DEFAULT_FLAG_NAMES="yellow green blue purple orange teal indigo slate"
DEFAULT_FLAG_KEY="C-c"
DEFAULT_FLAG_PICKER_KEY="M-c"
# Session colour: a PICKER ONLY, with no cycle counterpart. A window flag is
# flipped daily (hence C-c's one-press step), but a session colour is set once
# and then left alone, so stepping through the palette to reach slot 6 would be
# the wrong affordance for the only way to set it.
DEFAULT_SESSION_FLAG_KEY="M-s"
DEFAULT_TIMER_KEY="C-t"
DEFAULT_TIMER_MENU_KEY="M-t"
DEFAULT_TIMER_AUTOFOCUS="on"   # auto pause/resume timers on tab focus
DEFAULT_TIMER_RESTORE="on"     # re-seed timers from the event log after a restore
DEFAULT_TIMER_LOG="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-sidetabs/timelog.tsv"
DEFAULT_TIMER_TAGS_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-sidetabs/tags.tsv"

# Flag colours are durable too. FLAG_OPTION above dies with the server (tmux
# does not save user options, and neither does tmux-resurrect), so every
# set/clear writes through to this TSV and flag_restore.sh replays it after a
# restart, matched by session + window NAME. Three tab-separated columns:
#
#   session_name <TAB> window_name <TAB> index   -- a WINDOW flag
#   session_name <TAB>     (empty)   <TAB> index -- a SESSION colour
#
# The empty-middle-field shape holds SFLAG_OPTION, the per-session colour: the
# two states share one file, one lock and one restore pass, and can never
# collide because a window whose name is the empty string is never recorded at
# all. The store is rewritten as a whole-state SNAPSHOT on every change (see
# flag_store.sh) rather than patched row by row, which is what makes a clear
# persist and a rename self-heal.
DEFAULT_FLAG_STORE="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-sidetabs/flags.tsv"
DEFAULT_FLAG_RESTORE="on"      # re-seed flag colours from the store after a restore

# Notes. Unlike flags/timers the note text is durable on its own: every set/clear
# writes through to a TSV store keyed by (session name, window name), which
# note.sh restore replays after a server restart. The row glyph is presence-only
# — the text itself is never interpolated into a render format.
#
# The option and the store hold a note ID; the TEXT lives in its own file under
# "${store}.d/<id>". That indirection is what makes a note UNBOUNDED: tmux
# refuses any command over ~16KB ("command too long", measured in BYTES, so a
# CJK note hits it three times sooner), which capped a note kept in the option
# no matter how the cap was tuned. An id is ~11 characters, so the ceiling is
# gone. `note.sh gc` sweeps note files no store row and no live window
# references.
DEFAULT_NOTE_KEY="M-n"
DEFAULT_NOTE_ICON=$'\xef\x89\x89'   # U+F249 nerd-font sticky-note
DEFAULT_NOTE_STORE="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-sidetabs/notes.tsv"

# Agent status master switch (@sidetabs-agent-status). "off" makes every
# signal-RAISING call a no-op in one branch, before any tmux write, and makes
# render ignore any state already stored — the hooks stay installed in the
# agent's own config, they just stop costing anything. The clearing paths
# (clear/visited/reconcile) deliberately keep running while off, so a state that
# was live when the switch flipped can never get stuck.
DEFAULT_AGENT_STATUS="on"
# Done check glyph fg (@sidetabs-agent-done-fg). Nord green; the only agent
# state that adds COLOR to the row's foreground rather than recoloring the pill.
DEFAULT_AGENT_DONE_FG="#a3be8c"

# --- Session strip (scripts/strip.sh) ----------------------------------------
# The bottom status-left strip: one pill per session, coloured by what is
# actually happening in it. DEFAULT OFF, and while off strip.sh returns before
# touching a single tmux option — this plugin ships TPM install instructions,
# and a sidebar plugin must not silently eat somebody's status bar.
#
# The strip is GENERATED, not templated: strip.sh emits a literal status-left
# per session rather than a #{S:} loop, because a loop cannot see its own
# neighbours and the old workaround (per-session @strip_next options refreshed
# by hooks that lived only in a running server) went stale across every restart.
DEFAULT_SESSION_STRIP="off"
# Debounce stamp for the regenerate, the exact twin of LAST_REFRESH_OPTION.
# A burst of session churn (a resurrect restore creating eight sessions) must
# collapse into one regenerate; `strip.sh force` is the escape for the events
# that must never be dropped.
STRIP_LAST_OPTION="@sidetabs_strip_last_ms"
STRIP_DEBOUNCE_MS="100"

# Pill colours. Precedence is bell|attention > session colour > current > idle,
# the same rule the sidebar's window rows use.
DEFAULT_STRIP_BELL_BG="#bf616a"
DEFAULT_STRIP_BELL_FG="#eceff4"
DEFAULT_STRIP_CURRENT_BG="blue"
# NOT a user option, deliberately: the design's configuration surface lists
# @sidetabs-strip-current-bg with no -fg twin, and inventing one here would put
# an option in the code that ticket 08's README never documents.
STRIP_CURRENT_FG="black"
DEFAULT_STRIP_IDLE_BG="brightblack"
DEFAULT_STRIP_IDLE_FG="white"
# The bar's own background, which the LAST pill's arrow points into.
DEFAULT_STRIP_BG="black"
# Arrow ink where two neighbouring pills share a background. With the standard
# powerline colouring (fg = left pill's bg) such an arrow would be invisible —
# same ink as the surface it sits on — so a same-colour join gets a dark ink
# instead. U+E0B1 (the thin bar) is the usual answer and is deliberately NOT
# used: every separator in this strip is the solid U+E0B0.
DEFAULT_STRIP_SEP_FG="#2e3440"
# Marker on the CURRENT session's pill, drawn only when that session carries a
# colour of its own (@sidetabs_sflag). An uncoloured current session already
# renders in @sidetabs-strip-current-bg, which is what identifies it; a coloured
# one has given that slot away, so it needs the marker instead. U+258E, spelled
# as bytes because macOS ships bash 3.2 and $'\uXXXX' is a bash 4.2 feature.
DEFAULT_STRIP_MARKER=$'\xe2\x96\x8e'

# --- Session strip: the width cascade ----------------------------------------
# tmux truncates a status line by HARD CUT at the client edge: no ellipsis, no
# marker, and a 2-column glyph that does not fit is dropped whole. Silent
# clipping is therefore invisible to the user — you cannot tell a strip that
# ends at "proj" from one whose last three sessions fell off the edge. So the
# strip sheds detail in a fixed, announced order instead (see strip.sh section
# 6b), and these are the knobs that order runs against.

# Hard cap on a session name in the strip (@sidetabs-strip-name-max), applied at
# stage 0 INDEPENDENTLY of the cascade: 0 means no cap, and any other value
# truncates every name before the fitting even starts. For someone who wants
# short names at every width, not only at a narrow one.
DEFAULT_STRIP_NAME_MAX="0"

# Width budget for a session with NO attached client
# (@sidetabs-strip-assumed-width). A detached session's strip is still generated
# — it has to be, or attaching would show a stale one until the next event — but
# there is no client to ask how wide it is. 200 is wider than most terminals, so
# a detached session degrades only if it would be unreadable on any of them.
DEFAULT_STRIP_ASSUMED_WIDTH="200"

# Columns to reserve for a side the plugin does NOT own
# (@sidetabs-strip-reserve), when that side's width cannot be measured.
#
# The plugin always owns status-left (the session pills live there). It owns
# status-right only when @sidetabs-strip-right-1 is set; otherwise status-right
# belongs to the user (or to another plugin, or to tmux's own default) and must
# be RESERVED — reserved, never overrun and never dropped, since the cascade has
# no right to sacrifice content it did not write.
#
# Measuring it: expand that side with #{T:status-right} (which resolves #{...}
# and strftime %-specs), strip the #[...] style runs, count what is left. That
# is exact for anything static. It cannot work for a #(shell) job: ticket 06
# established empirically that those are scheduled ASYNCHRONOUSLY, and the
# expansion simply drops an unfinished job to the empty string — verified on
# 3.6b, where an option holding "#(echo hi) %H:%M" expands to " 11:36" with no
# trace of the job at all. So the presence of a job is detected on the RAW
# value, not on the expansion, and the reserve falls back to this option.
#
# "auto" (the default) = the measured width of everything that COULD be measured
# plus STRIP_JOB_RESERVE columns for each #(job) that could not — sensible
# because a status-right is usually mostly literal with one or two short jobs in
# it. A plain NUMBER overrides that estimate entirely for a side carrying a job,
# for anyone who knows exactly how wide theirs renders.
DEFAULT_STRIP_RESERVE="auto"
# Columns allowed per unmeasurable #(shell) job under "auto". Deliberately
# generous: under-reserving overruns content the user owns, while over-reserving
# only degrades our own strip one stage early.
STRIP_JOB_RESERVE="12"

# The name-truncation ladder (cascade stage 4), tried in this order. 12 keeps
# most names whole, 4 is still enough to tell "work" from "logs".
STRIP_NAME_STEPS="12 8 6 4"
