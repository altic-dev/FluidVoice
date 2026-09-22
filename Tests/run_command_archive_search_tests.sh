#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-command-archive-search.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM

# Keep production model/store, search subscription, and result-pruning code exact.
# Only index/query infrastructure is replaced; tests never touch real app defaults.
python3 - "$task_test_dir" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1])
service_path = Path("Sources/Fluid/Services/AppSearch/AppSearchService.swift")
service = service_path.read_text()

def unique_position(source, marker, path):
    count = source.count(marker)
    if count != 1:
        raise SystemExit(f"Archive search test extraction failed: expected exactly one {marker!r} in {path}; found {count}")
    return source.index(marker)

imports = "import ZeppelinEmbed\n"
unique_position(service, imports, service_path)
prefix_end = unique_position(service, "    /// Re-runs the current query. Called when the index changes under it.", service_path)
filter_start = unique_position(service, "    /// Covers both already displayed results and queries that finish after an archive.", service_path)
filter_end = unique_position(service, "    /// Score first, newest breaks ties. Rows the store no longer has are dropped.", service_path)
subscription = unique_position(service, "self.chatAvailabilitySubscription = ChatHistoryStore.shared.$sessions", service_path)
filter_method = unique_position(service, "nonisolated static func removingUnavailableChats(", service_path)
if not subscription < prefix_end < filter_start < filter_method < filter_end:
    raise SystemExit("Archive search test extraction failed: subscription/filter source order changed")

prefix = service[:prefix_end].replace(imports, "")
filter_source = service[filter_start:filter_end]
(output / "AppSearchSnapshot.swift").write_text(
    prefix
    + "    private func schedule() {}\n"
    + "    func publishForTests(_ groups: [AppSearchGroup]) { self.groups = groups }\n"
    + filter_source
    + "}\n"
)

store_path = Path("Sources/Fluid/Persistence/ChatHistoryStore.swift")
store = store_path.read_text()
unique_position(store, "final class ChatHistoryStore: ObservableObject", store_path)
unique_position(store, "private let defaults = UserDefaults.standard", store_path)
if "Foundation.UserDefaults" in store:
    raise SystemExit("Archive search test isolation failed: store bypasses the in-memory UserDefaults double")
(output / "ChatHistoryStore.swift").write_text(
    store + "\nextension ChatHistoryStore {\n"
    + "    func resetForTests(_ sessions: [ChatSession], currentChatID: String) {\n"
    + "        self.sessions = sessions\n        self.currentChatID = currentChatID\n"
    + "    }\n}\n"
)
PY

xcrun swiftc -parse-as-library \
    "$task_test_dir/AppSearchSnapshot.swift" \
    "$task_test_dir/ChatHistoryStore.swift" \
    Sources/Fluid/Persistence/Search/SearchIndexRecord.swift \
    Tests/CommandArchiveSearchTests.swift \
    -o "$task_test_dir/archive-search-tests"
"$task_test_dir/archive-search-tests"
