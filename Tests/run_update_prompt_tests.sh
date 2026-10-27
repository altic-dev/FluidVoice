#!/bin/sh
set -eu
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform" || { echo "Full Xcode required" >&2; exit 1; }
export DEVELOPER_DIR="$task_developer_dir"
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_test_dir=$(mktemp -d /tmp/fluidvoice-update-prompt-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc "$task_repo_dir/Sources/Fluid/Theme/FluidTypography.swift" "$task_repo_dir/Sources/Fluid/UI/UpdatePromptPresenter.swift" "$task_repo_dir/Tests/UpdatePromptTests.swift" -o "$task_test_dir/update-prompt-tests"
"$task_test_dir/update-prompt-tests"
python3 - "$task_repo_dir" <<'PYTEST'
from pathlib import Path
import sys
source = (Path(sys.argv[1]) / 'Sources/Fluid/AppDelegate.swift').read_text()
automatic = source[source.index('    private func checkForUpdatesAutomatically('):source.index('    private func showUpdateAlert(')]
assert 'SimpleUpdater.shared.checkForUpdatesAutomatically()' in automatic
assert 'checkAndUpdate(' not in automatic
for relative_path, start, end in [
    ('Sources/Fluid/UI/SettingsView.swift', 'Button("Check for Updates")', 'Button("Release Notes")'),
    ('Sources/Fluid/Services/MenuBarManager.swift', '@objc private func checkForUpdates(', '@objc private func rollbackToPreviousVersion('),
]:
    text = (Path(sys.argv[1]) / relative_path).read_text()
    update_section = text[text.index(start):text.index(end, text.index(start))]
    assert 'runModal' not in update_section, relative_path
    assert 'checkForUpdatesManually()' in update_section, relative_path
    assert 'checkAndUpdate(' not in update_section, relative_path
updater = (Path(sys.argv[1]) / 'Sources/Fluid/Services/SimpleUpdater.swift').read_text()
manual = updater[updater.index('    func checkForUpdatesManually('):updater.index('    func showAvailableUpdate(')]
assert 'startUpdateCheck(explicit: true)' in manual
assert 'checkAndUpdate(' not in manual
assert 'runModal' not in updater
assert 'self.updatePrompts.presentFloatingPrompt(' in updater
assert 'isAutomaticUpdateOffer: automatic' in updater
assert 'expectedVersion: version' in updater
assert 'self.updateDefaults.set(version, forKey: SettingsStore.UpdateKeys.snoozedUpdateVersion)' in updater
status = updater[updater.index('    func showUpdateInstallStatus('):updater.index('    private func resetUpdateOperation(')]
assert 'self.updatePrompts.dismissAll()' in status
assert 'progress.startAnimation(nil)' in status
trigger = (Path(sys.argv[1]) / 'Tests/trigger_update_ui_simulation.swift').read_text()
assert 'toggleRecording' not in trigger and 'dictation-toggle' not in trigger
print('PASS: automatic discovery and explicit confirmation remain separate; update results nonmodal; approval revalidates version; simulation trigger cannot record')
PYTEST
