#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-normalization-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -D TEST_APP_ADAPTER -O -swift-version 6 -parse-as-library \
    Sources/Fluid/TextNormalization/*.swift Sources/Fluid/Services/DictationTextNormalizationService.swift \
    Tests/TextNormalization/main.swift Tests/TextNormalization/NormalizationLoadingTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$PWD"
