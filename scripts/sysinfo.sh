#!/usr/bin/env bash
# Compact system info for the tmux status bar (macOS), with Nerd Font icons:
#   U+F0E4 (tachometer) load · U+F2DB (microchip) memory% · U+F0A0 (hdd) disk%
# Referenced from the status line via #(...). Always prints something; never errors.

ICON_LOAD="$(printf '\xef\x83\xa4')"   # U+F0E4
ICON_MEM="$(printf '\xef\x8b\x9b')"    # U+F2DB
ICON_DISK="$(printf '\xef\x82\xa0')"   # U+F0A0
SEP="$(printf '\xee\x82\xb1')"         # U+E0B1 thin powerline separator

load="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
[ -z "$load" ] && load="?"

mem="?"
pagesize="$(sysctl -n hw.pagesize 2>/dev/null)"
total="$(sysctl -n hw.memsize 2>/dev/null)"
if [ -n "$pagesize" ] && [ -n "$total" ] && [ "$total" -gt 0 ]; then
    vms="$(vm_stat 2>/dev/null)"
    field() { printf '%s\n' "$vms" | awk -v k="$1" 'index($0,k){ for(i=1;i<=NF;i++){ gsub(/\./,"",$i); if($i ~ /^[0-9]+$/){ print $i; exit } } }'; }
    active="$(field 'Pages active:')";            : "${active:=0}"
    wired="$(field 'Pages wired down:')";         : "${wired:=0}"
    comp="$(field 'occupied by compressor:')";    : "${comp:=0}"
    used=$(( (active + wired + comp) * pagesize ))
    [ "$used" -gt 0 ] && mem="$(( used * 100 / total ))%"
fi

# Disk usage of the writable data volume (falls back to /).
disk="$(df -h /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $5}')"
[ -z "$disk" ] && disk="$(df -h / 2>/dev/null | awk 'NR==2{print $5}')"
[ -z "$disk" ] && disk="?"

printf '%s %s %s %s %s %s %s %s' \
    "$ICON_LOAD" "$load" "$SEP" "$ICON_MEM" "$mem" "$SEP" "$ICON_DISK" "$disk"
