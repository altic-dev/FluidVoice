#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-page-presentation.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
# Compile the production dashboard geometry without app/service dependencies.
sed '/^struct DashboardSetupStatus/,$d' Sources/Fluid/UI/DashboardView.swift > "$task_test_dir/DashboardLayout.swift"
xcrun swiftc -parse-as-library \
    Sources/Fluid/UI/AppNavigationState.swift \
    Sources/Fluid/Theme/Components/FluidPageLayout.swift \
    "$task_test_dir/DashboardLayout.swift" \
    Tests/PagePresentationTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
