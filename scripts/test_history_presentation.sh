#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-history-presentation.XXXXXX)
# Compile the real value types without starting the app or accessing user history.
sed '/^\/\/ MARK: - Transcription History Store/,$d' Sources/Fluid/Persistence/TranscriptionHistoryStore.swift > "$task_test_dir/Entry.swift"
sed '/^final nonisolated class DictationAudioHistoryStore/,$d' Sources/Fluid/Persistence/DictationAudioHistoryStore.swift > "$task_test_dir/Audio.swift"
xcrun swiftc -parse-as-library "$task_test_dir/Entry.swift" "$task_test_dir/Audio.swift" Sources/Fluid/UI/HistoryTextDiff.swift Sources/Fluid/UI/HistoryAudioAvailability.swift Sources/Fluid/UI/ModelDisplayName.swift Tests/HistoryPresentationTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
