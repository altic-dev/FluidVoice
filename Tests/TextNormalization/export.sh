#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "Usage: sh Tests/TextNormalization/export.sh /absolute/path/to/new-directory" >&2
    exit 2
fi
case "$1" in
    /*) task_export_dir="$1" ;;
    *) echo "Use an absolute destination path." >&2; exit 2 ;;
esac
if [ -e "$task_export_dir" ] || [ -L "$task_export_dir" ]; then
    echo "Destination already exists; refusing to overwrite it." >&2
    exit 2
fi
mkdir -p "$task_export_dir/Sources/Fluid" "$task_export_dir/Tests/TextNormalization"
cp -R Sources/Fluid/TextNormalization "$task_export_dir/Sources/Fluid/"
cp Tests/TextNormalization/fixtures.json Tests/TextNormalization/main.swift Tests/TextNormalization/run.sh Tests/TextNormalization/export.sh Tests/TextNormalization/README.md "$task_export_dir/Tests/TextNormalization/"
cp Tests/TextNormalization/README.md "$task_export_dir/README.md"
# The exported core has no app adapter; its runner exercises the same portable fixtures.
sed -e 's/ -D TEST_APP_ADAPTER//' \
    -e 's@ Sources/Fluid/Services/DictationTextNormalizationService.swift@@' \
    -e 's@ Tests/TextNormalization/NormalizationLoadingTests.swift@@' \
    Tests/TextNormalization/run.sh > "$task_export_dir/Tests/TextNormalization/run.sh"
cd "$task_export_dir"
shasum -a 256 Sources/Fluid/TextNormalization/*.swift Sources/Fluid/TextNormalization/Resources/*.json \
    Tests/TextNormalization/fixtures.json Tests/TextNormalization/main.swift Tests/TextNormalization/run.sh Tests/TextNormalization/export.sh README.md Tests/TextNormalization/README.md > MANIFEST.sha256
echo "Exported code, catalog, and tests to $task_export_dir"
