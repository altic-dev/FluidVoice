#!/bin/bash
# The same regression and Xcode test sequence locally and on GitHub Actions.
set -euo pipefail
cd "$(dirname "$0")/.."

task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Full Xcode is required; set DEVELOPER_DIR to an installed Xcode.app." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_result_dir="${CI_RESULT_DIR:-build/test-results/local-ci-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$task_result_dir"

task_tree_fingerprint() {
    python3 - <<'PY'
import hashlib, os, pathlib, subprocess
paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).split(b'\0')
digest = hashlib.sha256()
for raw in sorted(set(paths) - {b''}):
    path = pathlib.Path(os.fsdecode(raw))
    digest.update(raw + b'\0')
    if path.is_symlink():
        digest.update(b'link:' + os.fsencode(os.readlink(path)))
    elif path.is_file():
        digest.update(str(path.stat().st_mode & 0o777).encode() + b':')
        digest.update(path.read_bytes())
    else:
        digest.update(b'deleted')
print(digest.hexdigest())
PY
}
task_start_tree="$(task_tree_fingerprint)"
{
    git rev-parse HEAD
    echo "tree=$task_start_tree"
    sw_vers
    xcodebuild -version
} > "$task_result_dir/environment.txt"

task_phase="preflight"
trap 'task_status=$?; if [ "$task_status" != 0 ]; then echo "CI check failed: $task_phase (exit $task_status); results: $task_result_dir" >&2; fi' EXIT
run_check() {
    task_phase="$1"
    shift
    echo "Running: $task_phase"
    "$@"
}

# Fail before the suite when a signed local test host cannot be built.
if [ "${GITHUB_ACTIONS:-false}" != "true" ]; then
    task_phase="Apple Development signing preflight"
    task_signing_team="${DEVELOPMENT_TEAM:-$(python3 - <<'PYTEAM'
import pathlib, re
teams = set(re.findall(r'DEVELOPMENT_TEAM = ([A-Z0-9]+);', pathlib.Path('Fluid.xcodeproj/project.pbxproj').read_text()))
if len(teams) == 1:
    print(teams.pop())
PYTEAM
)}"
    if [ -z "$task_signing_team" ]; then
        echo "Set DEVELOPMENT_TEAM to your Apple Development signing team." >&2
        exit 1
    fi
    if ! python3 - "$task_signing_team" <<'PYCERT'
import re, subprocess, sys
identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
for label in re.findall(r'"(Apple Development:[^"\n]+|Mac Developer:[^"\n]+)"', identities):
    certificate = subprocess.run(['security', 'find-certificate', '-c', label, '-p'], capture_output=True).stdout
    subject = subprocess.run(['openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253'], input=certificate, capture_output=True).stdout.decode()
    team = re.search(r'(?:^|,)OU=([^,]+)', subject)
    if team and team.group(1) == sys.argv[1]:
        sys.exit(0)
sys.exit(1)
PYCERT
    then
        echo "No Apple Development identity with a private key matches DEVELOPMENT_TEAM=$task_signing_team. Set DEVELOPMENT_TEAM to an installed development identity's team, or configure that certificate in Xcode. Local unsigned/ad-hoc tests are not allowed." >&2
        exit 1
    fi
fi

# CI already gates this job on its Linux SwiftLint job. Local runs must perform
# that check too; formatting validation must not silently edit the tested tree.
if [ "${GITHUB_ACTIONS:-false}" != "true" ]; then
    run_check formatting swiftformat --lint --config .swiftformat Sources
    run_check lint swiftlint --strict --config .swiftlint.yml Sources Tests Package.swift
fi
run_check clipboard sh Tests/run_clipboard_backup_reproduction.sh
run_check clipboard-read-receipts sh Tests/run_paste_read_receipt_tests.sh
run_check paste-events sh Tests/run_paste_command_event_tests.sh
run_check keyboard-layouts sh Tests/run_paste_key_cache_tests.sh
run_check paste-recovery sh Tests/run_paste_recovery_policy_tests.sh
run_check accessibility-preparation sh Tests/run_dictation_accessibility_preparation_tests.sh
run_check onboarding sh Tests/run_onboarding_tests.sh
run_check release-highlights sh Tests/run_release_highlights_tests.sh
run_check history-decode sh Tests/run_history_decode_recovery_tests.sh
run_check settings-backup python3 Tests/run_settings_backup_concurrency_tests.py
run_check meeting-backup python3 Tests/run_meeting_backup_refresh_tests.py

task_phase="Xcode build and tests"
task_build_args=(test -project Fluid.xcodeproj -scheme Fluid
    -destination 'platform=macOS,arch=arm64'
    -resultBundlePath "$task_result_dir/Fluid.xcresult"
    -skip-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictationEndToEnd_whisperTiny_transcribesFixture)
# Unsigned test hosts are permitted only on GitHub Actions. Local Debug builds
# keep their Apple Development identity and existing permissions.
if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
    task_build_args+=(CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO)
else
    task_build_args+=(CODE_SIGN_IDENTITY='Apple Development' CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES "DEVELOPMENT_TEAM=$task_signing_team")
fi
if command -v xcpretty >/dev/null 2>&1; then
    xcodebuild "${task_build_args[@]}" 2>&1 | tee "$task_result_dir/xcodebuild.log" | xcpretty
else
    xcodebuild "${task_build_args[@]}" 2>&1 | tee "$task_result_dir/xcodebuild.log"
fi

task_phase="source tree verification"
if [ "$task_start_tree" != "$(task_tree_fingerprint)" ]; then
    echo "Source tree changed during validation. Rerun the gate on the final tree." >&2
    exit 1
fi
echo "PASS: complete CI sequence; tree=$task_start_tree" | tee "$task_result_dir/result.txt"
