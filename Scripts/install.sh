#!/bin/bash
set -euo pipefail

app_name="GitExtensionsMac"
repository="norgera/GitExtensionsMac"
install_dir="${INSTALL_DIR:-/Applications}"
destination="$install_dir/$app_name.app"

usage() {
    cat <<EOF
Usage: install.sh [path-to-$app_name.app | path-to-.dmg | path-to-.zip]

Installs $app_name into $install_dir and removes the macOS quarantine attribute.

With no argument, downloads the latest release from GitHub.
EOF
}

work_dir="$(mktemp -d)"
mount_point=""

cleanup() {
    if [[ -n "$mount_point" ]]; then
        hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || hdiutil detach "$mount_point" -force -quiet >/dev/null 2>&1 || true
        if mount | grep -qF " on $mount_point "; then
            echo "Could not detach $mount_point; leaving $work_dir in place" >&2
            return
        fi
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

mount_dmg() {
    mkdir -p "$work_dir/mount"
    hdiutil attach "$1" -nobrowse -readonly -mountpoint "$work_dir/mount" -quiet
    mount_point="$work_dir/mount"
    source_app="$mount_point/$app_name.app"
}

extract_zip() {
    ditto -x -k "$1" "$work_dir/unzipped"
    source_app="$work_dir/unzipped/$app_name.app"
}

download_latest() {
    local api="https://api.github.com/repos/$repository/releases/latest"
    local url
    url="$(curl -fsSL "$api" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -n 1 | sed 's/.*"\(https[^"]*\)"/\1/')"
    if [[ -z "$url" ]]; then
        echo "Could not find a .dmg in the latest release of $repository" >&2
        exit 1
    fi
    echo "Downloading $url" >&2
    curl -fL --progress-bar -o "$work_dir/$app_name.dmg" "$url"
    echo "$work_dir/$app_name.dmg"
}

source_path="${1:-}"
case "$source_path" in
    -h|--help) usage; exit 0 ;;
esac

if [[ -z "$source_path" ]]; then
    source_path="$(download_latest)"
fi

case "$source_path" in
    *.dmg) mount_dmg "$source_path" ;;
    *.zip) extract_zip "$source_path" ;;
    *.app|*.app/) source_app="${source_path%/}" ;;
    *) echo "Unsupported input: $source_path" >&2; usage >&2; exit 2 ;;
esac

if [[ ! -d "$source_app" ]]; then
    echo "$app_name.app not found at $source_app" >&2
    exit 1
fi

if pgrep -xq "$app_name"; then
    echo "Quitting running $app_name"
    osascript -e "tell application id \"io.github.norgera.gitextensionsmac\" to quit" >/dev/null 2>&1 || true
    sleep 1
fi

sudo_cmd=()
if [[ ! -w "$install_dir" ]] || { [[ -e "$destination" ]] && [[ ! -w "$destination" ]]; }; then
    echo "Administrator access is required to install into $install_dir"
    sudo_cmd=(sudo)
fi

echo "Installing to $destination"
"${sudo_cmd[@]+"${sudo_cmd[@]}"}" rm -rf "$destination"
"${sudo_cmd[@]+"${sudo_cmd[@]}"}" ditto "$source_app" "$destination"
"${sudo_cmd[@]+"${sudo_cmd[@]}"}" xattr -dr com.apple.quarantine "$destination" 2>/dev/null || true

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$destination/Contents/Info.plist" 2>/dev/null || echo unknown)"
echo "Installed $app_name $version"
echo "Open it with: open \"$destination\""
