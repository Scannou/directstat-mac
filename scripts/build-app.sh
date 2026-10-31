#!/bin/bash
# Builds build/DirectStat.app (release, ad-hoc signed).
#
# Environment:
#   VERSION=1.2.0   app version (default: latest v* tag, or 0.0.0)
#   BUILD_NUMBER=42 build number (default: number of commits)
#   UNIVERSAL=1     build for both Apple Silicon and Intel (slower)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# Both go into Info.plist as-is, so only allow plain numbers.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must look like 1.2.0, got: $VERSION" >&2
    exit 1
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "BUILD_NUMBER must be a whole number, got: $BUILD_NUMBER" >&2
    exit 1
fi

ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --product DirectStat
BIN="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)/DirectStat"
APP="build/DirectStat.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DirectStat"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DirectStat</string>
    <key>CFBundleDisplayName</key><string>DirectStat</string>
    <key>CFBundleIdentifier</key><string>dev.directstat.DirectStat</string>
    <key>CFBundleExecutable</key><string>DirectStat</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Hardened runtime: the app has Full Disk Access, so macOS must refuse to
# load code injected through DYLD_INSERT_LIBRARIES and similar.
codesign --force --options runtime --sign - "$APP"
echo "Built $APP (version $VERSION, build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/DirectStat"))"
