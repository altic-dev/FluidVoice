#!/bin/sh
set -eu

task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
case "$task_developer_dir" in
    */Xcode*.app/Contents/Developer) ;;
    *) echo "Set DEVELOPER_DIR to an installed full Xcode before running tests." >&2; exit 1 ;;
esac
export DEVELOPER_DIR="$task_developer_dir"
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_test_dir=$(mktemp -d /tmp/fluidvoice-paste-cache-tests.XXXXXX)
xcrun swiftc -O \
    "$task_repo_dir/Sources/Fluid/Services/KeyboardLayoutSnapshotCache.swift" \
    "$task_repo_dir/Tests/PasteKeyCodeCacheRegressionTests.swift" \
    -o "$task_test_dir/paste-cache-tests"
"$task_test_dir/paste-cache-tests"
xcrun swiftc -O \
    "$task_repo_dir/Sources/Fluid/Services/PasteKeyCodeResolver.swift" \
    "$task_repo_dir/Tests/PasteKeyCodeResolverTests.swift" \
    -o "$task_test_dir/paste-resolver-tests"
"$task_test_dir/paste-resolver-tests"
xcrun swiftc -O \
    "$task_repo_dir/Sources/Fluid/Services/KeyboardLayoutSnapshotCache.swift" \
    "$task_repo_dir/Sources/Fluid/Services/RemoteDesktopKeyMap.swift" \
    "$task_repo_dir/Tests/RemoteDesktopLayoutCacheRegressionTests.swift" \
    -o "$task_test_dir/remote-layout-cache-tests"
"$task_test_dir/remote-layout-cache-tests"
if [ "${1:-}" = "--live" ]; then
    xcrun swiftc -O \
        "$task_repo_dir/Sources/Fluid/Services/KeyboardLayoutSnapshotCache.swift" \
        "$task_repo_dir/Sources/Fluid/Services/PasteKeyCodeResolver.swift" \
        "$task_repo_dir/Tests/PasteKeyCodeCacheLiveLayoutTests.swift" \
        -o "$task_test_dir/paste-live-tests"
    "$task_test_dir/paste-live-tests"
fi
