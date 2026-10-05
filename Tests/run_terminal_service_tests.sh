#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-terminal-service-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Match the app target's isolation settings: the timeout depends on execute()
# not blocking the actor its timer runs on.
xcrun swiftc -parse-as-library \
    -swift-version 5 \
    -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    Sources/Fluid/Services/TerminalService.swift \
    Tests/TerminalServiceTests.swift \
    -o "$task_test_dir/terminal-service-tests"
"$task_test_dir/terminal-service-tests"
