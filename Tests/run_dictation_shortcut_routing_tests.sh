#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-shortcut-routing-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -O -parse-as-library \
    Sources/Fluid/Services/DictationShortcutRouting.swift \
    Tests/DictationShortcutRoutingTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
