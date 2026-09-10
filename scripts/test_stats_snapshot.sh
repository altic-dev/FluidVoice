#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-stats-snapshot.XXXXXX)
sed '/^\/\/ MARK: - Transcription History Store/,$d' Sources/Fluid/Persistence/TranscriptionHistoryStore.swift > "$task_test_dir/Entry.swift"
sed '/^final nonisolated class DictationAudioHistoryStore/,$d' Sources/Fluid/Persistence/DictationAudioHistoryStore.swift > "$task_test_dir/Audio.swift"
xcrun swiftc -parse-as-library "$task_test_dir/Entry.swift" "$task_test_dir/Audio.swift" Sources/Fluid/UI/StatsSnapshot.swift Sources/Fluid/UI/StatsSnapshotStore.swift Tests/StatsSnapshotStoreFixtures.swift Tests/StatsSnapshotTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
