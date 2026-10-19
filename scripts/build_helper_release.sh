#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
version="${VERSION:-1.0.0}"
stage="$root/dist/helper"
archive="$root/dist/ECDICTAudioHelper-v$version-macos.zip"
dictionary_archive="$root/dist/ECDICT-macOS-Dictionary-v$version.zip"

/bin/rm -rf "$stage"
/bin/mkdir -p "$stage"

UNIVERSAL=1 "$script_dir/build_audio_helper.sh" "$stage/ECDICTAudioHelper" >/dev/null
/usr/bin/ditto --noextattr --norsrc "$root/packaging/helper/run-helper.sh" "$stage/run-helper.sh"
/usr/bin/ditto --noextattr --norsrc "$root/packaging/helper/install-helper.sh" "$stage/install-helper.sh"
/usr/bin/ditto --noextattr --norsrc "$root/packaging/helper/uninstall-helper.sh" "$stage/uninstall-helper.sh"
/usr/bin/ditto --noextattr --norsrc "$root/packaging/helper/README.txt" "$stage/README.txt"
chmod +x "$stage/run-helper.sh" "$stage/install-helper.sh" "$stage/uninstall-helper.sh"

# Archive the contents of the staging directory (no extra parent folder).
/usr/bin/ditto -c -k --sequesterRsrc "$stage" "$archive"

if [[ -f "$dictionary_archive" ]]; then
  (cd "$root/dist" && /usr/bin/shasum -a 256 \
    "$(basename "$dictionary_archive")" "$(basename "$archive")" > SHA256SUMS.txt)
else
  (cd "$root/dist" && /usr/bin/shasum -a 256 "$(basename "$archive")" > SHA256SUMS.txt)
fi

/usr/bin/lipo -info "$stage/ECDICTAudioHelper"
/bin/ls -lh "$archive"
(cd "$root/dist" && /bin/cat SHA256SUMS.txt)
