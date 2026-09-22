#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-command-models.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Keep the actual model metadata/key rules; network model fetching is unavailable in this harness.
sed '/^    \/\/ MARK: - Fetch Models from API/,$d' Sources/Fluid/Services/ModelRepository.swift > "$task_test_dir/ModelRepository.swift"
echo '}' >> "$task_test_dir/ModelRepository.swift"
xcrun swiftc -parse-as-library \
    "$task_test_dir/ModelRepository.swift" \
    Sources/Fluid/UI/ModelDisplayName.swift \
    Sources/Fluid/Views/CommandModelCatalog.swift \
    Sources/Fluid/Persistence/SettingsStore+CommandMode.swift \
    Tests/CommandModelCatalogTests.swift \
    -o "$task_test_dir/catalog-tests"
"$task_test_dir/catalog-tests"
