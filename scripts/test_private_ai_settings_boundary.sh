#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-fi-boundary.XXXXXX)
xcrun swiftc -parse-as-library \
    Sources/Fluid/UI/AISettings/PrivateAISettingsSession.swift \
    Sources/Fluid/UI/AISettings/PrivateAIModelPresentation.swift \
    Sources/Fluid/UI/AISettings/PrivateAISettingsController.swift \
    Tests/PrivateAISettingsControllerDoubles.swift \
    Tests/PrivateAISettingsBoundaryTests.swift \
    -o "$task_test_dir/boundary-tests"
"$task_test_dir/boundary-tests"
