#!/usr/bin/env bash

# Per-pane user options
SIDETAB_MARKER="@is_sidetab"
RENDER_PID_OPTION="@sidetabs_render_pid"

# Global flag (set during a tmux-resurrect restore): create_sidebar.sh stands
# down while it's "1" so the restore can't spawn duplicate sidetabs; the
# resurrect post-restore hook clears it and rebuilds clean sidebars.
RESTORING_OPTION="@sidetabs_restoring"

# Per-session user options
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
DEFAULT_TIMER_KEY="C-t"
DEFAULT_TIMER_MENU_KEY="M-t"
DEFAULT_TIMER_AUTOFOCUS="on"   # auto pause/resume timers on tab focus
DEFAULT_TIMER_RESTORE="on"     # re-seed timers from the event log after a restore
DEFAULT_TIMER_LOG="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-sidetabs/timelog.tsv"
