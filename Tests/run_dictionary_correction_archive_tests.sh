#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-correction-archive.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -D DICTIONARY_ARCHIVE_STANDALONE -parse-as-library \
    Sources/Fluid/Persistence/DictionaryCorrectionArchive.swift \
    Tests/Standalone/DictionaryCorrectionArchiveTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
