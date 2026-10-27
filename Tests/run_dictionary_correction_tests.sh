#!/bin/sh
set -eu
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
case "$task_developer_dir" in
    */Xcode*.app/Contents/Developer) ;;
    *) echo "Set DEVELOPER_DIR to an installed full Xcode." >&2; exit 1 ;;
esac
export DEVELOPER_DIR="$task_developer_dir"
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_test_dir=$(mktemp -d /tmp/fluidvoice-correction-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -D DICTIONARY_CORRECTION_STANDALONE -parse-as-library \
    "$task_repo_dir/Sources/Fluid/Services/DictionaryCorrectionEditPolicy.swift" \
    "$task_repo_dir/Sources/Fluid/Services/AutomaticDictionaryCorrectionDetector.swift" \
    "$task_repo_dir/Tests/Standalone/DictionaryCorrectionDetectorTests.swift" \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
