#!/bin/sh
set -eu
cd "$(dirname "$0")"
SELECTED=$(xcode-select -p)
case "$SELECTED" in
  *.app/Contents/Developer) export DEVELOPER_DIR="$SELECTED" ;;
  *) export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta6.app/Contents/Developer}" ;;
esac
[ -d "$DEVELOPER_DIR/Platforms/MacOSX.platform" ] || { echo "Full Xcode required" >&2; exit 1; }
APP="$PWD/.build/FluidVoice Overlay Preview.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx13.0" Sources/*.swift -o "$APP/Contents/MacOS/OverlayPreview" -framework SwiftUI -framework AppKit
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.fluidvoice.experimental.overlay-preview</string>
<key>CFBundleName</key><string>FluidVoice Overlay Preview</string>
<key>CFBundleExecutable</key><string>OverlayPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${PREVIEW_SIGN_IDENTITY:-Apple Development: Barathwaj Anandan (XJ27RZ3HBK)}" "$APP"
printf '%s\n' "$APP"
