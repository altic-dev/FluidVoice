#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-overlay-captions.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -parse-as-library Sources/Fluid/Theme/FluidTypography.swift Sources/Fluid/UI/OverlayCaptionView.swift Tests/OverlayCaptionTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
