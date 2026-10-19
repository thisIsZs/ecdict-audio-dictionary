#!/bin/bash

set -euo pipefail

REPOSITORY="${ECDICT_REPOSITORY:-thisIsZs/ecdict-audio-dictionary}"
DICTIONARY_NAME="ECDICT 英汉发音词典.dictionary"
INSTALL_DIR="${ECDICT_INSTALL_DIR:-$HOME/Library/Dictionaries}"
SYSTEM_DICTIONARY="/Library/Dictionaries/$DICTIONARY_NAME"
API_URL="${ECDICT_RELEASE_API_URL:-https://api.github.com/repos/$REPOSITORY/releases/latest}"

work_dir=""

cleanup() {
    if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        /bin/rm -rf -- "$work_dir"
    fi
}

fail() {
    printf '安装失败：%s\n' "$1" >&2
    exit 1
}

# Enable the freshly installed dictionary and move it to the top of the
# Dictionary.app list. Dictionary.app is sandboxed, so it sees ~/Library/
# Dictionaries through a symlink inside its container and stores that container
# path in the ordered DCSActiveDictionaries array.
activate_dictionary() {
    local bundle="$1"
    local name
    name="$(/usr/bin/basename "$bundle")"

    local container_dir="$HOME/Library/Containers/com.apple.Dictionary/Data/Library/Dictionaries"
    local active_path="$bundle"
    if [[ -L "$container_dir" ]]; then
        active_path="$container_dir/$name"
    fi

    local plist="$HOME/Library/Preferences/com.apple.DictionaryServices.plist"
    local -a items=("$active_path")

    if [[ -f "$plist" ]]; then
        local index=0
        local existing
        while existing="$(/usr/bin/plutil -extract "DCSActiveDictionaries.$index" raw -o - "$plist" 2>/dev/null)"; do
            if [[ "$(/usr/bin/basename "$existing")" != "$name" ]]; then
                items+=("$existing")
            fi
            index=$((index + 1))
        done
    fi

    if /usr/bin/defaults write com.apple.DictionaryServices DCSActiveDictionaries \
        -array "${items[@]}" >/dev/null 2>&1; then
        printf '已自动勾选并置于第一位：%s\n' "$name"
    else
        printf '提示：自动勾选失败，请在“词典”→“设置…”中手动勾选。\n' >&2
    fi
}

# Install the local helper that makes the Look Up panel play audio. The
# dictionary and Dictionary.app work without it; only the panel needs a server.
# Set ECDICT_SKIP_HELPER=1 to skip.
install_helper() {
    if [[ "${ECDICT_SKIP_HELPER:-0}" == "1" ]]; then
        printf '已跳过 Helper（ECDICT_SKIP_HELPER=1）。\n'
        return 0
    fi

    local helper_url
    helper_url="$(/usr/bin/awk -F '"' '/browser_download_url/ && /ECDICTAudioHelper-v[0-9.]+.*\.zip/ { print $4; exit }' "$release_json")"
    if [[ -z "$helper_url" ]]; then
        printf '提示：Release 中没有 Helper 压缩包，弹窗发音需手动安装。\n' >&2
        return 0
    fi

    local helper_zip="$work_dir/helper.zip"
    local helper_dir="$work_dir/helper"
    if ! /usr/bin/curl -fL --retry 3 "$helper_url" -o "$helper_zip"; then
        printf '提示：Helper 下载失败，可稍后按 README 手动安装。\n' >&2
        return 0
    fi
    /bin/mkdir -p "$helper_dir"
    if ! /usr/bin/ditto -x -k "$helper_zip" "$helper_dir"; then
        printf '提示：Helper 解压失败，可稍后按 README 手动安装。\n' >&2
        return 0
    fi

    # Replace an existing manual/LaunchAgent instance so the new process can
    # bind port 17943.
    /bin/launchctl bootout "gui/$(/usr/bin/id -u)/com.ecdict.audio-helper" >/dev/null 2>&1 || true
    local pid comm
    pid="$(/usr/sbin/lsof -nP -iTCP:17943 -sTCP:LISTEN -t 2>/dev/null | /usr/bin/head -1 || true)"
    if [[ -n "$pid" ]]; then
        comm="$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)"
        if [[ "$comm" == *ECDICTAudioHelper* ]]; then
            /bin/kill "$pid" >/dev/null 2>&1 || true
            /bin/sleep 1
        fi
    fi

    if ! /bin/bash "$helper_dir/install-helper.sh" "$destination/Contents/Resources"; then
        printf '提示：Helper 安装失败，可稍后按 README 手动安装。\n' >&2
        return 0
    fi

    local attempt=0
    while [[ $attempt -lt 5 ]]; do
        if /usr/bin/curl -fsS --noproxy '*' --max-time 1 http://127.0.0.1:17943/health >/dev/null 2>&1; then
            printf 'Helper 已启动：http://127.0.0.1:17943\n'
            return 0
        fi
        /bin/sleep 1
        attempt=$((attempt + 1))
    done
    printf '提示：Helper 已安装，但健康检查未通过；请查看 ~/Library/Logs/ECDICTAudioHelper.log。\n' >&2
    return 0
}

command -v curl >/dev/null 2>&1 || fail "系统中找不到 curl。"
command -v ditto >/dev/null 2>&1 || fail "系统中找不到 ditto。"
command -v shasum >/dev/null 2>&1 || fail "系统中找不到 shasum。"

[[ "$(uname -s)" == "Darwin" ]] || fail "此安装脚本仅支持 macOS。"
[[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != "/" ]] || fail "安装目录不安全。"
if [[ "$INSTALL_DIR" != "/Library/Dictionaries" && -d "$SYSTEM_DICTIONARY" ]]; then
    fail "检测到系统级旧版 $SYSTEM_DICTIONARY。macOS 可能优先加载它；请改用最新 Release 中的 PKG 覆盖更新。"
fi

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ecdict-install.XXXXXX")"
trap cleanup EXIT INT TERM

release_json="$work_dir/release.json"
checksum_file="$work_dir/SHA256SUMS.txt"
archive_file="$work_dir/dictionary.zip"
extract_dir="$work_dir/extracted"

printf '正在获取 ECDICT 最新版本信息…\n'
/usr/bin/curl -fsSL --retry 3 \
    -H 'Accept: application/vnd.github+json' \
    "$API_URL" -o "$release_json" \
    || fail "无法连接 GitHub Releases。"

zip_url="$(/usr/bin/awk -F '"' '/browser_download_url/ && /ECDICT-macOS-Dictionary-v[0-9.]+\.zip/ { print $4; exit }' "$release_json")"
checksum_url="$(/usr/bin/awk -F '"' '/browser_download_url/ && /SHA256SUMS\.txt/ { print $4; exit }' "$release_json")"

[[ -n "$zip_url" ]] || fail "最新版 Release 中没有找到 macOS ZIP。"
[[ -n "$checksum_url" ]] || fail "最新版 Release 中没有找到 SHA256SUMS.txt。"

zip_name="${zip_url##*/}"

printf '正在下载 %s…\n' "$zip_name"
/usr/bin/curl -fL --retry 3 "$zip_url" -o "$archive_file" \
    || fail "词典下载失败。"
/usr/bin/curl -fsSL --retry 3 "$checksum_url" -o "$checksum_file" \
    || fail "校验文件下载失败。"

expected_hash="$(/usr/bin/awk -v name="$zip_name" '$2 == name { print $1; exit }' "$checksum_file")"
actual_hash="$(/usr/bin/shasum -a 256 "$archive_file" | /usr/bin/awk '{ print $1 }')"

[[ -n "$expected_hash" ]] || fail "校验文件中没有 $zip_name。"
[[ "$actual_hash" == "$expected_hash" ]] || fail "SHA-256 校验失败，文件可能不完整。"

printf 'SHA-256 校验通过。\n'
/bin/mkdir -p "$extract_dir"
/usr/bin/ditto -x -k "$archive_file" "$extract_dir" \
    || fail "ZIP 解压失败。"

dictionary_path="$(/usr/bin/find "$extract_dir" -maxdepth 2 -type d -name "$DICTIONARY_NAME" -print -quit)"
[[ -n "$dictionary_path" ]] || fail "ZIP 中没有找到完整的 .dictionary 文件夹。"

/bin/mkdir -p "$INSTALL_DIR"
destination="$INSTALL_DIR/$DICTIONARY_NAME"

if [[ -e "$destination" ]]; then
    backup_dir="$INSTALL_DIR/ECDICT Backups"
    timestamp="$(/bin/date '+%Y%m%d-%H%M%S')"
    backup_path="$backup_dir/ECDICT 英汉发音词典-$timestamp.dictionary"
    /bin/mkdir -p "$backup_dir"
    /bin/mv "$destination" "$backup_path"
    printf '旧版本已备份到：%s\n' "$backup_path"
fi

/usr/bin/ditto --noextattr --norsrc "$dictionary_path" "$destination" \
    || fail "无法复制词典到 $INSTALL_DIR。"
/usr/bin/touch "$INSTALL_DIR"
if [[ "${ECDICT_SKIP_RESTART:-0}" != "1" ]]; then
    /usr/bin/killall -9 LookupViewService >/dev/null 2>&1 || true
    /usr/bin/killall -9 com.apple.DictionaryServiceHelper >/dev/null 2>&1 || true
    /usr/bin/killall Dictionary >/dev/null 2>&1 || true
    # Wait for Dictionary to finish writing its own preferences; otherwise it
    # could overwrite the activation we are about to perform.
    for _ in 1 2 3; do
        /usr/bin/pgrep -x Dictionary >/dev/null 2>&1 || break
        /bin/sleep 1
    done
fi

activate_dictionary "$destination"
install_helper

printf '\n安装完成：%s\n' "$destination"
printf '请重新打开“词典”App，进入“设置…”（Command-,）确认：\n'
printf '  1. “%s”已勾选并位于第一位；\n' "$DICTIONARY_NAME"
printf '  2. 至少再勾选一本 macOS 系统自带词典；\n'
printf '  3. 搜索 apple 确认释义与发音可以正常显示。\n'
