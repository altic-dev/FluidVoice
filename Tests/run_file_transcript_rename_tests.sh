#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Set DEVELOPER_DIR to a full Xcode before running tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-file-rename.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
# Compile the production search record without the unrelated store mappings.
sed '/^extension TranscriptionHistoryEntry/,$d' \
    Sources/Fluid/Persistence/Search/SearchIndexRecord.swift > "$task_test_dir/SearchIndexRecord.swift"
xcrun swiftc -parse-as-library \
    "$task_test_dir/SearchIndexRecord.swift" \
    Sources/Fluid/Persistence/FileTranscriptionHistoryStore.swift \
    Sources/Fluid/Persistence/PersistedHistory.swift \
    Tests/FileTranscriptRenameTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
