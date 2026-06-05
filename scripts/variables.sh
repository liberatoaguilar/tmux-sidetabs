#!/usr/bin/env bash

# Per-pane user options
SIDETAB_MARKER="@is_sidetab"
RENDER_PID_OPTION="@sidetabs_render_pid"

# Per-session user options
COLLAPSED_OPTION="@sidetabs_collapsed"
WIDTH_OPTION="@sidetabs_width"                   # current expanded width (synced)
LAST_REFRESH_OPTION="@sidetabs_last_refresh_ms"  # debounce stamp

# Active-tab summary cache (per-session) — avoids re-spawning git every second
# across every window's sidetab. Recompute-on-miss is idempotent, so no lock.
SUMMARY_CACHE_WIN="@sidetabs_sum_win"     # window id the cache is for
SUMMARY_CACHE_AT="@sidetabs_sum_at"       # epoch ms of last compute
SUMMARY_CACHE_GIT="@sidetabs_sum_git"     # raw "branch subject" (or empty)
SUMMARY_CACHE_DIRS="@sidetabs_sum_dirs"   # raw "~/a | ~/b" (or empty)
SUMMARY_TTL_MS="2000"

# Defaults (overridable via user options)
DEFAULT_EXPANDED_WIDTH="20"
DEFAULT_COLLAPSED_WIDTH="4"
DEFAULT_TOGGLE_KEY="Tab"
DEFAULT_SKIP_NAV="on"
DEFAULT_MOUSE="off"
REFRESH_DEBOUNCE_MS="100"

# Width-sync feedback guard. Propagating a resize to the other windows fires
# window-layout-changed -> sync_width.sh for each of them; while armed, events
# from windows OTHER than the guard owner are ignored, so propagation can't
# re-trigger itself into an oscillation. The owning (source) window stays live.
SYNC_GUARD_OPTION="@sidetabs_sync_until"  # epoch ms until which echo-sync is suppressed
SYNC_GUARD_WIN_OPTION="@sidetabs_sync_win" # window that owns the guard (stays live)
SYNC_GUARD_MS="250"
