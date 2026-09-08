#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-provider-setup.XXXXXX)
xcrun swiftc -parse-as-library \
    Sources/Fluid/UI/AISettings/ProviderSetupDraft.swift \
    Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel+ProviderSetup.swift \
    Tests/ProviderSetupBoundaryTests.swift \
    -o "$task_test_dir/provider-tests"
"$task_test_dir/provider-tests"
