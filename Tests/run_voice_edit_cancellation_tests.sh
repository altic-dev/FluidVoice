#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-voice-edit.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Exercise the production voice caller; replace only model, focus, and OS delivery.
python3 - "$task_test_dir/VoiceEdit.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/ContentView.swift').read_text()
start = source.index('    private func processRewriteWithVoiceInstruction(')
end = source.index('    private func setActiveRecordingMode(', start)
Path(sys.argv[1]).write_text('import Foundation\n@MainActor extension VoiceEditOwner {\n' + source[start:end].replace('private func', 'func', 1) + '}\n')
PY
xcrun swiftc -parse-as-library "$task_test_dir/VoiceEdit.swift" Tests/VoiceEditCancellationTests.swift -o "$task_test_dir/edit-tests"
"$task_test_dir/edit-tests"
