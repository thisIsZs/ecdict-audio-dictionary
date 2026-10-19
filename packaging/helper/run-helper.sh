#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
helper="${ECDICT_AUDIO_HELPER:-$here/ECDICTAudioHelper}"
name="ECDICT 英汉发音词典.dictionary"

resources=""
for candidate in \
  "$HOME/Library/Dictionaries/$name/Contents/Resources" \
  "/Library/Dictionaries/$name/Contents/Resources"; do
  if [[ -f "$candidate/audio-manifest.json" ]]; then
    resources="$candidate"
    break
  fi
done

if [[ -z "$resources" ]]; then
  printf '找不到已安装的词典：%s\n请先把词典装进 ~/Library/Dictionaries/。\n' "$name" >&2
  exit 1
fi
if [[ ! -x "$helper" ]]; then
  printf '找不到可执行的 Helper：%s\n' "$helper" >&2
  exit 1
fi

log="${ECDICT_AUDIO_LOG:-$HOME/Library/Logs/ECDICTAudioHelper.log}"
mkdir -p "$(dirname "$log")"
printf 'Resources: %s\nLog: %s\n' "$resources" "$log"
exec "$helper" "$resources" >>"$log" 2>&1
