#!/usr/bin/env bash
# Compact system info for the tmux status bar (macOS): load, memory %, battery %.
# Referenced from the status line via #(...). Always prints something; never errors.

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

bat="$(pmset -g batt 2>/dev/null | grep -Eo '[0-9]+%' | head -1)"

out="LOAD ${load}  MEM ${mem}"
[ -n "$bat" ] && out="${out}  BAT ${bat}"
printf '%s' "$out"
