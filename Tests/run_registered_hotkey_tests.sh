#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
developer_dir=$(xcode-select -p)
platform_dir="$developer_dir/Platforms/MacOSX.platform/Developer"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/fluidvoice-hotkeys.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc \
    -I "$platform_dir/usr/lib" -L "$platform_dir/usr/lib" \
    -F "$platform_dir/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$platform_dir/Library/Frameworks" \
    -D HOTKEY_STANDALONE_TESTS \
    "$repo_dir/Sources/Fluid/Models/HotkeyShortcut.swift" \
    "$repo_dir/Sources/Fluid/Services/RegisteredHotkeys.swift" \
    "$repo_dir/Tests/FluidDictationIntegrationTests/RegisteredHotkeysTests.swift" \
    -o "$test_dir/tests"
DYLD_FRAMEWORK_PATH="$platform_dir/Library/PrivateFrameworks" \
DYLD_LIBRARY_PATH="$platform_dir/usr/lib" "$test_dir/tests"
if [ "${1:-}" = "--live" ]; then
    xcrun swiftc \
        "$repo_dir/Sources/Fluid/Models/HotkeyShortcut.swift" \
        "$repo_dir/Sources/Fluid/Services/RegisteredHotkeys.swift" \
        "$repo_dir/Tests/RegisteredHotkeysLiveProbe.swift" \
        -o "$test_dir/live-probe"
    "$test_dir/live-probe"
fi
