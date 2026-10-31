#!/bin/sh
set -eu
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
case "$task_developer_dir" in
    */Xcode*.app/Contents/Developer) ;;
    *) echo "Set DEVELOPER_DIR to an installed full Xcode." >&2; exit 1 ;;
esac
export DEVELOPER_DIR="$task_developer_dir"
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_test_dir=$(mktemp -d /tmp/fluidvoice-dictionary-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -D DICTIONARY_EXPERIMENT_STANDALONE -O -parse-as-library \
    "$task_repo_dir/Sources/Fluid/Services/ParakeetSpeechModelCatalog.swift" \
    "$task_repo_dir/Sources/Fluid/Services/DictionaryCorrectionEditPolicy.swift" \
    "$task_repo_dir/Sources/Fluid/Services/DictionaryExperimentalMatcher.swift" \
    "$task_repo_dir/Sources/Fluid/Services/DictionaryNegativeExamples.swift" \
    "$task_repo_dir/Sources/Fluid/Services/DictionaryLearningEvidence.swift" \
    "$task_repo_dir/Tests/Standalone/DictionaryMatcherExperimentTests.swift" \
    -o "$task_test_dir/tests"
"$task_test_dir/tests" "$@"
