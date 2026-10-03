#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir=$(mktemp -d /tmp/fluidvoice-send-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -O -parse-as-library \
  Sources/Fluid/Services/DictationSendPolicy.swift \
  Sources/Fluid/Services/SpokenSendParser.swift \
  Tests/DictationSendPolicyTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
