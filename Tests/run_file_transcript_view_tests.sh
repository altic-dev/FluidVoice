#!/bin/sh
set -eu
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
case "$task_developer_dir" in
    */Xcode*.app/Contents/Developer) ;;
    *) echo "Set DEVELOPER_DIR to an installed full Xcode before running tests." >&2; exit 1 ;;
esac
export DEVELOPER_DIR="$task_developer_dir"
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_test_dir=$(mktemp -d /tmp/fluidvoice-file-view-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -O -parse-as-library \
    "$task_repo_dir/Sources/Fluid/UI/FileTranscriptScrollView.swift" \
    "$task_repo_dir/Tests/FileTranscriptScrollViewTests.swift" \
    -o "$task_test_dir/file-view-tests"
"$task_test_dir/file-view-tests"
