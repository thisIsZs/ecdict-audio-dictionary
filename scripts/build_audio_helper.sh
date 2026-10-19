#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$project_dir/build/audio-helper/ECDICTAudioHelper}"
mkdir -p "$(dirname "$output")"

# Use Apple's toolchain/SDK explicitly: a Homebrew clang on PATH may look for a
# macOS SDK that is not installed and fail to find the AVFoundation headers.
if compiler="$(/usr/bin/xcrun --find clang 2>/dev/null)"; then
  sdk="$(/usr/bin/xcrun --show-sdk-path 2>/dev/null || true)"
else
  compiler=/usr/bin/clang
  sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
fi

arch_flags=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  arch_flags=(-arch arm64 -arch x86_64)
fi

"$compiler" -O2 -fobjc-arc -isysroot "$sdk" "${arch_flags[@]}" \
  -framework Foundation -framework AVFoundation \
  "$project_dir/scripts/ECDICTAudioHelper.m" -o "$output"
echo "$output"
