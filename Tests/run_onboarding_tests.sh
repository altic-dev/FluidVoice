#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-onboarding-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
run_case() {
    task_case_name="$1"
    shift
    xcrun swiftc -O -parse-as-library "$@" "Tests/$task_case_name.swift" -o "$task_test_dir/$task_case_name"
    "$task_test_dir/$task_case_name"
}
run_case OnboardingAISetupControllerTests Sources/Fluid/Services/OnboardingAISetupController.swift
run_case OnboardingPolishPracticeTests Sources/Fluid/Services/OnboardingPolishPractice.swift
run_case OnboardingDictationOutputPolicyTests Sources/Fluid/Services/OnboardingDictationOutputPolicy.swift
run_case PrivateAIHardwareRecommendationTests Sources/Fluid/Services/PrivateAIHardwareRecommendation.swift
