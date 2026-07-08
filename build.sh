#!/bin/bash

# FluidVoice Build Profile Router
# Defaults to the public OSS build, which skips private Fluid Intelligence.
#
# Usage:
#   ./build.sh                    # public OSS build
#   ./build.sh public             # public OSS build
#   ./build.sh fi                 # private FI build

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${1:-${BUILD_PROFILE:-public}}"
PRIVATE_FI_BUILD_SCRIPT="${PROJECT_DIR}/build_with_FI_incremental.sh"

case "${PROFILE}" in
    public|oss|incremental|fast)
        echo "Running public FluidVoice build without Fluid Intelligence..."
        cd "${PROJECT_DIR}"
        exec xcodebuild -project Fluid.xcodeproj -scheme Fluid -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
        ;;
    fi|private|dev|full)
        if [ ! -x "${PRIVATE_FI_BUILD_SCRIPT}" ]; then
            echo "Private Fluid Intelligence build script is missing:"
            echo "  ${PRIVATE_FI_BUILD_SCRIPT}"
            echo "Restore the private FI build setup, then run: sh build_with_FI_incremental.sh"
            exit 1
        fi
        exec "${PRIVATE_FI_BUILD_SCRIPT}"
        ;;
    *)
        echo "Unknown build profile: ${PROFILE}"
        echo "Valid profiles: public/oss/incremental/fast, fi/private/dev/full"
        exit 1
        ;;
esac
