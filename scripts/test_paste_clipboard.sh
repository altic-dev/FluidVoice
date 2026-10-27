#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-clipboard-tests.XXXXXX)
xcrun swiftc -O -parse-as-library Sources/Fluid/Services/PreservedPasteboardSnapshot.swift Tests/PasteClipboardTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
