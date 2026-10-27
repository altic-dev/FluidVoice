#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-command-cancellation.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Include the actual voice continuation and notch submit methods to cover their await boundaries.
python3 - "$task_test_dir/CommandUI.swift" <<'PYCODE'
from pathlib import Path
import sys
voice = Path('Sources/Fluid/ContentView.swift').read_text()
a = voice.index('    private func processCommandWithVoice(')
b = voice.index('    /// Capture app context', a)
notch = Path('Sources/Fluid/Views/NotchContentViews.swift').read_text()
c = notch.index('    private func submitFollowUp()')
d = notch.index('\n}\n', c)
Path(sys.argv[1]).write_text('import Foundation\n@MainActor extension VoiceCommandOwner {\n' + voice[a:b].replace('private func', 'func', 1) + '}\n@MainActor extension NotchInputOwner {\n' + notch[c:d].replace('private func', 'func', 1) + '\n}\n')
PYCODE
# Compile the entire production agent, including streaming callbacks and recursive turns.
# Only its model, terminal, UI, and UserDefaults dependencies are test doubles.
xcrun swiftc -parse-as-library \
    Sources/Fluid/Services/CommandModeService.swift \
    Sources/Fluid/Persistence/ChatHistoryStore.swift \
    Sources/Fluid/Persistence/PersistedHistory.swift \
    Tests/CommandCancellationTests.swift \
    "$task_test_dir/CommandUI.swift" \
    -o "$task_test_dir/cancellation-tests"
"$task_test_dir/cancellation-tests"
