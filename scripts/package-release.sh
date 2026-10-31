#!/bin/bash
# Builds a universal DirectStat.app and packs it into a drag-to-install disk
# image for a GitHub release.
# Usage: scripts/package-release.sh 1.2.0
# Output: dist/DirectStat-1.2.0.dmg, its .sha256, and build/release-notes.md
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/package-release.sh <version, e.g. 1.2.0>}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must look like 1.2.0, got: $VERSION" >&2
    exit 1
fi

VERSION="$VERSION" UNIVERSAL=1 ./scripts/build-app.sh

rm -rf dist
mkdir -p dist
DMG="DirectStat-$VERSION.dmg"
STAGE="build/dmg"
RW="build/DirectStat-rw.dmg"

# The disk shows the app next to a shortcut to Applications: drag one onto the other.
rm -rf "$STAGE" "$RW"
mkdir -p "$STAGE"
ditto build/DirectStat.app "$STAGE/DirectStat.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# Build writable first to flag the disk as having a custom icon, then compress.
hdiutil create -quiet -volname "DirectStat" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
MOUNT="$(hdiutil attach -nobrowse -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')"
if command -v SetFile >/dev/null; then SetFile -a C "$MOUNT"; fi
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "dist/$DMG"
rm -rf "$STAGE" "$RW"
(cd dist && shasum -a 256 "$DMG" > "$DMG.sha256")

cat > build/release-notes.md <<EOF
## Install

1. Download **$DMG** below and open it.
2. Drag **DirectStat** onto the **Applications** folder next to it.
3. Open DirectStat from Applications. The app isn't notarized, so macOS blocks the first launch:
   open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway**.
4. To scan every folder, turn on DirectStat in
   **System Settings › Privacy & Security › Full Disk Access**.

Requires macOS 15 or later. Runs natively on Apple Silicon and Intel.
EOF

echo "Packaged dist/$DMG"
cat "dist/$DMG.sha256"
