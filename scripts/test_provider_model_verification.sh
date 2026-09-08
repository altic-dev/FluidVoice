#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-model-verification.XXXXXX)
xcrun swiftc -parse-as-library Sources/Fluid/UI/AISettings/ProviderModelVerificationStore.swift Tests/ProviderModelVerificationStoreTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
