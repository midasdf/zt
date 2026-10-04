#!/bin/sh
set -eu

binary=${1:-zig-out/bin/zt}
bundle=${2:-zig-out/zt.app}
version=$(sed -n 's/.*\.version = "\([0-9][0-9.]*\)".*/\1/p' build.zig.zon)
if [ -z "$version" ]; then
    echo "Run this script from the zt repository root" >&2
    exit 1
fi

if [ ! -x "$binary" ]; then
    echo "Build zt first: zig build -Doptimize=ReleaseFast" >&2
    exit 1
fi

mkdir -p "$bundle/Contents/MacOS"
cp "$binary" "$bundle/Contents/MacOS/zt"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>zt</string>
    <key>CFBundleIdentifier</key><string>io.github.midasdf.zt</string>
    <key>CFBundleName</key><string>zt</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$bundle"
echo "Created $bundle"
