#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-updater-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
    Sources/Fluid/Services/UpdateTerminationScheduler.swift \
    Tests/UpdaterTerminationBoundaryTests.swift \
    -o "$task_test_dir/termination-tests"
task_original_status=0
"$task_test_dir/termination-tests" --original > "$task_test_dir/original.log" || task_original_status=$?
cat "$task_test_dir/original.log"
test "$task_original_status" -eq 2
grep -q '^termination-stuck$' "$task_test_dir/original.log"
for task_run in 1 2 3; do
    "$task_test_dir/termination-tests" > "$task_test_dir/fixed.log"
    grep -q '^history-save-completed$' "$task_test_dir/fixed.log"
    grep -q '^termination-completed$' "$task_test_dir/fixed.log"
    echo "PASS: fixed termination run $task_run saved history and exited"
done
