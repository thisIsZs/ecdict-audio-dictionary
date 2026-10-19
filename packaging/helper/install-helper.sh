#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
label="com.ecdict.audio-helper"
dest="$HOME/Library/Application Support/ECDICT"
agents="$HOME/Library/LaunchAgents"
plist="$agents/$label.plist"
logs="$HOME/Library/Logs"
uid="$(id -u)"
name="ECDICT 英汉发音词典.dictionary"

resources="${1:-${ECDICT_AUDIO_RESOURCES:-}}"
if [[ -z "$resources" ]]; then
  for candidate in \
    "$HOME/Library/Dictionaries/$name/Contents/Resources" \
    "/Library/Dictionaries/$name/Contents/Resources"; do
    if [[ -f "$candidate/audio-manifest.json" ]]; then
      resources="$candidate"
      break
    fi
  done
fi

if [[ -z "$resources" || ! -f "$resources/audio-manifest.json" ]]; then
  printf '找不到已安装的词典：%s\n请先安装词典，再运行本脚本。\n' "$name" >&2
  exit 1
fi

if existing="$(/usr/sbin/lsof -nP -iTCP:17943 -sTCP:LISTEN -t 2>/dev/null)" && [[ -n "$existing" ]]; then
  printf '端口 17943 已被进程 %s 占用。\n' "$existing" >&2
  printf '请先停止它（kill %s），再运行本脚本。\n' "$existing" >&2
  exit 1
fi

mkdir -p "$dest" "$agents" "$logs"
/usr/bin/ditto --noextattr --norsrc "$here/ECDICTAudioHelper" "$dest/ECDICTAudioHelper"
/usr/bin/ditto --noextattr --norsrc "$here/run-helper.sh" "$dest/run-helper.sh"
chmod +x "$dest/ECDICTAudioHelper" "$dest/run-helper.sh"
# A browser download adds a quarantine flag; the user explicitly installed this
# helper, so clear it to avoid Gatekeeper refusing the unsigned binary.
/usr/bin/xattr -dr com.apple.quarantine "$dest" >/dev/null 2>&1 || true

cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$dest/run-helper.sh</string>
    <string>$resources</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>$logs/ECDICTAudioHelper.log</string>
  <key>StandardErrorPath</key>
  <string>$logs/ECDICTAudioHelper.log</string>
</dict>
</plist>
PLIST
chmod 644 "$plist"

launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$uid" "$plist"

printf '已安装：%s\n' "$dest"
printf '已注册：%s\n' "$plist"
printf '已启动：%s（登录时自动运行）\n' "$label"
printf '日志：%s\n' "$logs/ECDICTAudioHelper.log"
printf '验证：curl http://127.0.0.1:17943/health\n'
