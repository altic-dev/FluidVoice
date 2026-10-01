#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir=$(mktemp -d /tmp/fluidvoice-sixtydb.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -parse-as-library Sources/Fluid/Services/TranscriptionProvider.swift Sources/Fluid/Services/SixtyDBProvider.swift Tests/SixtyDBProviderTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
