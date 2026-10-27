#!/bin/sh
set -eu

task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
case "$task_developer_dir" in
    */Xcode*.app/Contents/Developer) ;;
    *) echo "Set DEVELOPER_DIR to an installed full Xcode before running tests." >&2; exit 1 ;;
esac
export DEVELOPER_DIR="$task_developer_dir"
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_test_dir=$(mktemp -d /tmp/fluidvoice-idle-unloader-tests.XXXXXX)
xcrun swiftc -O -parse-as-library \
    "$task_repo_dir/Sources/Fluid/Services/PrivateAIIdleUnloader.swift" \
    "$task_repo_dir/Tests/PrivateAIIdleUnloaderTests.swift" \
    -o "$task_test_dir/idle-unloader-tests"
"$task_test_dir/idle-unloader-tests"
