#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-prompt-defaults.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Compile the real pure prompt methods without initializing the app or user defaults.
python3 - "$task_test_dir/PromptMethods.swift" <<'PY'
import pathlib, sys
source = pathlib.Path('Sources/Fluid/Persistence/SettingsStore.swift').read_text()
signatures = [
    'static func baseDictationPromptText()', 'static func legacyBaseDictationPromptText()',
    'static func defaultDictationPromptBodyText()', 'static func baseEditPromptText()', 'static func basePromptText(for mode:',
    'static func combineBasePrompt(for mode:', 'static func stripBasePrompt(for mode:',
    'static func customPromptBody(',
]
methods = []
for signature in signatures:
    start = source.index('    ' + signature)
    end = source.index('\n    }', start) + len('\n    }')
    methods.append(source[start:end])
scaffold = '''import Foundation
enum SettingsStore {
    enum PromptMode { case dictate, edit, write, rewrite
        var normalized: Self { self == .dictate ? .dictate : .edit }
    }
'''
pathlib.Path(sys.argv[1]).write_text(scaffold + '\n'.join(methods) + '\n}\n')
PY
xcrun swiftc -parse-as-library "$task_test_dir/PromptMethods.swift" Sources/Fluid/Services/DictationPromptRequest.swift Tests/DictationPromptDefaultsTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
