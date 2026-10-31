#!/bin/bash
# Rebuild only FluidVoice's bridge; preserve every pinned upstream archive member.
set -euo pipefail
cd "$(dirname "$0")/.."
selected="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! "$selected" == *.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
library=Artifacts/FluidAEC3.xcframework/macos-arm64_x86_64/libFluidAEC3-system-exact.a
shasum -a 256 -c Metadata/artifact-files.sha256
python3 - <<'VERIFY'
import hashlib, pathlib
for line in pathlib.Path('Metadata/source-files.sha256').read_text().splitlines():
    expected, path = line.split('  ', 1)
    if path not in ('BridgeSources/fluid_aec3_bridge.cc', 'BridgeSources/phase1_bridge.cc'):
        actual = hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(f'Pinned source changed: {path}')
VERIFY
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fluid-aec-bridge.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
for arch in arm64 x86_64; do
  xcrun lipo "$library" -thin "$arch" -output "$scratch/upstream-$arch.a"
  xcrun ar -d "$scratch/upstream-$arch.a" fluid_aec3_bridge.o
  mkdir -p "$scratch/$arch"
  xcrun clang++ -arch "$arch" -O2 -std=c++20 -fno-exceptions -fno-rtti \
    -fvisibility=hidden -Wno-nullability-completeness -mmacosx-version-min=15.0 \
    -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_LIBRARY_IMPL -DNDEBUG \
    -I BridgeSources -I UpstreamSources/src \
    -I UpstreamSources/src/third_party/abseil-cpp -I "UpstreamSources/generated/$arch" \
    -c BridgeSources/fluid_aec3_bridge.cc -o "$scratch/$arch/fluid_aec3_bridge.o"
  xcrun libtool -static -o "$scratch/bridge-$arch.a" \
    "$scratch/upstream-$arch.a" "$scratch/$arch/fluid_aec3_bridge.o"
done
xcrun lipo -create "$scratch/bridge-arm64.a" "$scratch/bridge-x86_64.a" -output "$scratch/universal.a"
# Test the actual replacement archive before installing it in the package.
xcrun clang++ -O2 -std=c++20 -mmacosx-version-min=15.0 -I BridgeSources \
  BridgeSources/phase1_bridge.cc "$scratch/universal.a" -framework Foundation -o "$scratch/probe"
"$scratch/probe"
cp "$scratch/universal.a" "$library"
python3 - <<'PY'
import hashlib, pathlib
for name in ('source-files.sha256', 'artifact-files.sha256'):
    manifest = pathlib.Path('Metadata') / name
    lines = []
    for line in manifest.read_text().splitlines():
        old, path = line.split('  ', 1)
        # Only these bridge inputs and its archive changed; never bless upstream drift.
        if path in ('BridgeSources/fluid_aec3_bridge.cc', 'BridgeSources/phase1_bridge.cc',
                    'Artifacts/FluidAEC3.xcframework/macos-arm64_x86_64/libFluidAEC3-system-exact.a'):
            old = hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
        lines.append(f'{old}  {path}')
    manifest.write_text('\n'.join(lines) + '\n')
PY
shasum -a 256 -c Metadata/source-files.sha256 > "$scratch/source-check.log"
shasum -a 256 -c Metadata/artifact-files.sha256
xcrun lipo -archs "$library"
