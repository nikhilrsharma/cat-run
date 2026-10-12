#!/bin/bash
set -euo pipefail

# Build a local, signed app bundle with the selected full Xcode installation.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    echo "Full Xcode is required. Set DEVELOPER_DIR to its Contents/Developer directory." >&2
    exit 1
fi

cd "$project_root"
/usr/bin/plutil -lint Resources/Info.plist Resources/CatRun.entitlements
module_cache="$project_root/.build/module-cache"
package_cache="$project_root/.build/package-cache"
/bin/mkdir -p "$module_cache" "$package_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
# This controls SwiftPM's build-manifest sandbox, not the packaged App Sandbox.
# Keep build caches in the checkout so restricted build environments can write them.
/usr/bin/xcrun swift build --disable-sandbox --cache-path "$package_cache" \
    --configuration release -debug-info-format none --product KeepAwake
binary_directory="$(/usr/bin/xcrun swift build --disable-sandbox --cache-path "$package_cache" \
    --configuration release --show-bin-path)"
build_directory="$project_root/build"
/bin/mkdir -p "$build_directory"
staging_directory="$(/usr/bin/mktemp -d "$build_directory/.package.XXXXXX")"
trap '/bin/rm -rf "$staging_directory"' EXIT
staging_app="$staging_directory/Cat Run.app"
app_path="$build_directory/Cat Run.app"

/bin/mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
/usr/bin/install -m 755 "$binary_directory/KeepAwake" "$staging_app/Contents/MacOS/KeepAwake"
/usr/bin/strip -S "$staging_app/Contents/MacOS/KeepAwake"
/usr/bin/install -m 644 Resources/Info.plist "$staging_app/Contents/Info.plist"

# Copy bundled assets, but keep signing metadata out of the resource directory.
for resource in "$project_root"/Resources/*; do
    [[ -e "$resource" ]] || continue
    case "$(/usr/bin/basename "$resource")" in
        Info.plist|CatRun.entitlements) continue ;;
    esac
    /usr/bin/ditto "$resource" "$staging_app/Contents/Resources/$(/usr/bin/basename "$resource")"
done

if [[ ! -f "$staging_app/Contents/Resources/CatRun.icns" ]]; then
    /usr/bin/xcrun swift -module-cache-path "$module_cache" scripts/generate-icon.swift \
        "$staging_directory/CatRun.iconset"
    /usr/bin/iconutil --convert icns "$staging_directory/CatRun.iconset" \
        --output "$staging_app/Contents/Resources/CatRun.icns"
fi

/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
    --entitlements Resources/CatRun.entitlements "$staging_app"
/usr/bin/codesign --verify --deep --strict "$staging_app"

# Replace only this script's generated app after the new bundle has verified.
/bin/rm -rf "$app_path"
/bin/mv "$staging_app" "$app_path"
printf '\nBuilt %s\n' "$app_path"
printf 'Local ad-hoc signature; not Developer ID signed or notarized.\n'
