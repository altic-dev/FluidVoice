#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-history-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Compile the production record and history mapping without pulling in the
# unrelated file-transcript/chat stores and their app dependencies.
sed '/^extension FileTranscriptionEntry/,$d' \
    Sources/Fluid/Persistence/Search/SearchIndexRecord.swift > "$task_test_dir/HistorySearchRecord.swift"
xcrun swiftc -O -parse-as-library \
    Sources/Fluid/Persistence/Search/HistorySearchRevision.swift \
    "$task_test_dir/HistorySearchRecord.swift" \
    Sources/Fluid/Persistence/TranscriptionHistoryDatabase.swift \
    Sources/Fluid/Persistence/TranscriptionHistoryStore.swift \
    Tests/HistoryPersistenceBoundaryTests.swift \
    -lsqlite3 -o "$task_test_dir/history-tests"
# These weak imports resolve to null on early macOS 27.2 betas even though
# their OS version passes the SDK's availability check.
xcrun nm -u "$task_test_dir/history-tests" > "$task_test_dir/imports.txt"
if grep -Eq '\$s10Foundation4DateV2(ge|le)oiy' "$task_test_dir/imports.txt"; then
    echo "FAIL: history imports Foundation Date >= / <= symbols missing on early macOS 27.2 betas" >&2
    exit 1
fi
echo "PASS: history does not import unavailable Foundation Date >= / <= symbols"
"$task_test_dir/history-tests"
