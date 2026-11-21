#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc is not on PATH. Install a Swift toolchain and re-run this script with a plain swiftc."
    exit 1
fi
task_test_dir=$(mktemp -d /tmp/fluidvoice-english-spelling.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
swiftc -parse-as-library \
    Sources/Fluid/Persistence/EnglishSpellingPreference.swift \
    Tests/EnglishSpellingPreferenceTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
