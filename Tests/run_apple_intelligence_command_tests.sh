#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-apple-intelligence-command.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -parse-as-library \
    Sources/Fluid/Services/AppleIntelligenceCommandProvider.swift \
    Tests/AppleIntelligenceCommandTests.swift \
    -o "$task_test_dir/apple-intelligence-tests"
"$task_test_dir/apple-intelligence-tests"
