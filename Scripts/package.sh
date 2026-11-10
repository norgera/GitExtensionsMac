#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

app_name="GitExtensionsMac"
version="$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Version.xcconfig | tr -d '[:space:]')"
build="$(sed -n 's/^CURRENT_PROJECT_VERSION *= *//p' Config/Version.xcconfig | tr -d '[:space:]')"
if [[ -z "$version" || -z "$build" ]]; then
    echo "Could not read MARKETING_VERSION/CURRENT_PROJECT_VERSION from Config/Version.xcconfig" >&2
    exit 1
fi

derived_data="${PACKAGE_DERIVED_DATA:-$repository_root/.build/DerivedData}"
output_dir="${PACKAGE_OUTPUT_DIR:-$repository_root/.build/release}"
signing_identity="${SIGNING_IDENTITY:--}"

echo "Building $app_name $version ($build)"
xcodebuild build \
    -project GitExtensionsMac.xcodeproj \
    -scheme GitExtensionsMac \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO \
    "$@"

built_app="$derived_data/Build/Products/Release/$app_name.app"
built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built_app/Contents/Info.plist")"
if [[ "$built_version" != "$version" ]]; then
    echo "Built app version $built_version does not match $version" >&2
    exit 1
fi

rm -rf "$output_dir"
mkdir -p "$output_dir"
staging="$output_dir/dmg"
mkdir -p "$staging"

ditto "$built_app" "$staging/$app_name.app"
codesign --force --deep --sign "$signing_identity" "$staging/$app_name.app"
codesign --verify --deep --strict "$staging/$app_name.app"

ln -s /Applications "$staging/Applications"

zip_path="$output_dir/$app_name-$version.zip"
dmg_path="$output_dir/$app_name-$version.dmg"

ditto -c -k --keepParent "$staging/$app_name.app" "$zip_path"
hdiutil create -volname "$app_name $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg_path" >/dev/null
rm -rf "$staging"

(cd "$output_dir" && shasum -a 256 "$(basename "$dmg_path")" "$(basename "$zip_path")" > SHA256SUMS.txt)

echo
echo "Packaged $app_name $version ($build):"
echo "  $dmg_path"
echo "  $zip_path"
echo "  $output_dir/SHA256SUMS.txt"
