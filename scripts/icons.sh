#!/usr/bin/env bash
# Shared per-command Nerd Font icon map, used by render.sh (sidebar rows) and
# search.sh (popup list). Glyph bytes are printf'd (bash 3.2: no $'\u'). Exact
# glyphs are tweakable.
ICON_EDITOR="$(printf '\xee\x98\xab')"  # U+E62B  vim/editor
ICON_NODE="$(printf '\xee\x9c\x98')"    # U+E718  node/js
ICON_PYTHON="$(printf '\xee\x98\x86')"  # U+E606  python
ICON_RUBY="$(printf '\xee\x9c\xb9')"    # U+E739  ruby
ICON_GO="$(printf '\xee\x98\xa7')"      # U+E627  go
ICON_RUST="$(printf '\xee\x9e\xa8')"    # U+E7A8  rust
ICON_GIT="$(printf '\xee\x9c\x82')"     # U+E702  git
ICON_DOCKER="$(printf '\xee\x9e\xb0')"  # U+E7B0  docker/containers
ICON_DB="$(printf '\xee\x9c\x86')"      # U+E706  database
ICON_REMOTE="$(printf '\xef\x83\x82')"  # U+F0C2  ssh/cloud
ICON_PAGER="$(printf '\xef\x80\xad')"   # U+F02D  pager/book
ICON_LOGS="$(printf '\xef\x83\xb6')"    # U+F0F6  logs/file-text
ICON_BUILD="$(printf '\xef\x82\xad')"   # U+F0AD  make/wrench
ICON_SHELL="$(printf '\xef\x84\xa0')"   # U+F120  shell/terminal
ICON_AI="$(printf '\xef\x8b\x9b')"      # U+F2DB  microchip — AI coding agents
ICON_DEFAULT="$(printf '\xef\x84\x91')" # U+F111  default (filled circle)

# icon_for <command> — set global ICON to the mapped glyph (or the default).
icon_for() {
    case "$1" in
        codex|opencode|claude|claude-code) ICON="$ICON_AI" ;;
        [0-9]*.[0-9]*.[0-9]*)             ICON="$ICON_AI" ;;  # Claude Code reports its version
        vim|nvim|vi|view)                 ICON="$ICON_EDITOR" ;;
        node|nodejs|npm|npx|yarn|pnpm|bun|deno) ICON="$ICON_NODE" ;;
        python|python3|ipython|pip|pip3)  ICON="$ICON_PYTHON" ;;
        ruby|rails|irb|bundle)            ICON="$ICON_RUBY" ;;
        go|gopls)                         ICON="$ICON_GO" ;;
        cargo|rustc|rust-analyzer)        ICON="$ICON_RUST" ;;
        git|lazygit|gitui|tig)            ICON="$ICON_GIT" ;;
        docker|docker-compose|kubectl|k9s) ICON="$ICON_DOCKER" ;;
        psql|mysql|redis-cli|sqlite3|mongosh) ICON="$ICON_DB" ;;
        ssh|mosh|sshpass)                 ICON="$ICON_REMOTE" ;;
        less|more|man|bat)                ICON="$ICON_PAGER" ;;
        tail|journalctl|tailspin)         ICON="$ICON_LOGS" ;;
        make|cmake|gcc|cc|clang|gradle)   ICON="$ICON_BUILD" ;;
        bash|zsh|fish|sh|dash)            ICON="$ICON_SHELL" ;;
        *)                                ICON="$ICON_DEFAULT" ;;
    esac
}
