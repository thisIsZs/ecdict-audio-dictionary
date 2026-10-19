#!/bin/bash
set -euo pipefail

label="com.ecdict.audio-helper"
plist="$HOME/Library/LaunchAgents/$label.plist"
dest="$HOME/Library/Application Support/ECDICT"

launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
/bin/rm -f "$plist"
/bin/rm -rf "$dest"

printf '已停止并卸载 %s。\n' "$label"
