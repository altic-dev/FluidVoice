#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

export SWIFTLY_HOME_DIR=/tmp/swift-install/home
export SWIFTLY_BIN_DIR=/tmp/swift-install/bin
export SWIFTLY_TOOLCHAINS_DIR=/home/box/.local/share/swiftly/toolchains
export LD_LIBRARY_PATH=/tmp/swift-install/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export PATH="/tmp/swift-install/bin:/home/box/.local/share/swiftly/toolchains/6.4.2/usr/bin:$PATH"

task_test_dir=$(mktemp -d /tmp/fluidvoice-meeting-transcript-markdown.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT

# LocalAPIRouteHandler is @MainActor. On macOS the router is constructed from the
# app's main actor; Linux swiftc has no app host, so isolate the real router type
# for this compile only. The source in git is unchanged.
sed 's/^final class LocalAPIRouter/@MainActor final class LocalAPIRouter/' \
    Sources/Fluid/Services/LocalAPI/LocalAPIRouter.swift \
    > "$task_test_dir/LocalAPIRouter.swift"

swiftc -parse-as-library \
    Sources/Fluid/Services/LocalAPI/LocalAPIModels.swift \
    "$task_test_dir/LocalAPIRouter.swift" \
    Sources/Fluid/Services/LocalAPI/MeetingAPIController.swift \
    Sources/Fluid/Services/LocalAPI/MeetingLiveAPIModels.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingTranscriptExporter.swift \
    Tests/MeetingTranscriptMarkdownTests.swift \
    -o "$task_test_dir/tests"

"$task_test_dir/tests"
