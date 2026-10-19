#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
helper="${ECDICT_AUDIO_HELPER:-$project_dir/build/audio-helper/ECDICTAudioHelper}"
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 '<installed dictionary Contents/Resources directory>'" >&2
  exit 64
fi
log_path="${ECDICT_AUDIO_LOG:-$project_dir/build/audio-helper/requests.log}"
mkdir -p "$(dirname "$log_path")"
echo "Audio Helper log: $log_path"
exec "$helper" "$1" >>"$log_path" 2>&1
