#!/usr/bin/env bash
# Compact system info for the tmux status bar (macOS), with Nerd Font icons:
#   U+F0E4 (tachometer) load · U+F2DB (microchip) memory% · U+F0A0 (hdd) disk%
# Referenced from the status line via #(...). Always prints something; never errors.
#
# Usage: sysinfo.sh [load|mem|disk]
#   (no argument)  print all three, joined by the thin separator — UNCHANGED
#                  from before this option existed, byte for byte, because an
#                  existing user config may already call this bare.
#   load|mem|disk  print just that one measurement (icon + value, no
#                  separator), so it can be its own edge pill instead of one
#                  opaque blob. strip.sh's left/right pills call this form —
#                  three `#(sysinfo.sh X)` invocations per status-interval
#                  instead of one bare call, which is the accepted tradeoff
#                  (about 20 forks per 5s rather than 7) for letting the
#                  shrink cascade (a later ticket) drop them one at a time.
#   anything else  same as no argument — never treated as an error.

ICON_LOAD="$(printf '\xef\x83\xa4')"   # U+F0E4
ICON_MEM="$(printf '\xef\x8b\x9b')"    # U+F2DB
ICON_DISK="$(printf '\xef\x82\xa0')"   # U+F0A0
SEP="$(printf '\xee\x82\xb1')"         # U+E0B1 thin powerline separator

print_load() {
    local load
    load="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')"
    [ -z "$load" ] && load="?"
    printf '%s %s' "$ICON_LOAD" "$load"
}

print_mem() {
    local mem="?" pagesize total vms active wired comp used
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
    printf '%s %s' "$ICON_MEM" "$mem"
}

print_disk() {
    local disk
    # Disk usage of the writable data volume (falls back to /).
    disk="$(df -h /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $5}')"
    [ -z "$disk" ] && disk="$(df -h / 2>/dev/null | awk 'NR==2{print $5}')"
    [ -z "$disk" ] && disk="?"
    printf '%s %s' "$ICON_DISK" "$disk"
}

case "${1:-}" in
    load) print_load ;;
    mem)  print_mem ;;
    disk) print_disk ;;
    # Bare call (or an unrecognized argument — this script never errors):
    # every measurement, joined exactly as it always has been. Built from the
    # SAME print_* functions the single-measurement forms use, so the two
    # paths cannot drift apart from each other.
    *)
        l="$(print_load)"; m="$(print_mem)"; d="$(print_disk)"
        printf '%s %s %s %s %s' "$l" "$SEP" "$m" "$SEP" "$d"
        ;;
esac
