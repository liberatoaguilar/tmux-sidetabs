#!/usr/bin/env bash

# Per-pane user options
SIDETAB_MARKER="@is_sidetab"
RENDER_PID_OPTION="@sidetabs_render_pid"

# Per-session user options
COLLAPSED_OPTION="@sidetabs_collapsed"
WIDTH_OPTION="@sidetabs_width"                   # current expanded width (synced)
LAST_REFRESH_OPTION="@sidetabs_last_refresh_ms"  # debounce stamp

# Defaults (overridable via user options)
DEFAULT_EXPANDED_WIDTH="20"
DEFAULT_COLLAPSED_WIDTH="4"
DEFAULT_TOGGLE_KEY="Tab"
DEFAULT_SKIP_NAV="on"
REFRESH_DEBOUNCE_MS="100"
