#!/bin/bash

# MedVoice Build Profile Router
# Routes to profile scripts.
#
# Usage:
#   ./build.sh                    # default dev path (build_dev.sh)
#   ./build.sh dev                # same as above
#   ./build.sh full               # same as above
#   ./build.sh incremental        # fast local loop (build_incremental.sh)
#   CREATE_DMG=1 ./build.sh full  # build + embed frameworks + create DMG
#   ./build.sh dmg                # release build + embed frameworks + create DMG
#   BUILD_PROFILE=incremental ./build.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${1:-${BUILD_PROFILE:-dev}}"

case "${PROFILE}" in
    dev|full)
        exec "${PROJECT_DIR}/build_dev.sh"
        ;;
    dmg)
        CONFIGURATION="${CONFIGURATION:-Release}" \
        CREATE_DMG="${CREATE_DMG:-1}" \
        INSTALL_APP="${INSTALL_APP:-0}" \
        LAUNCH_APP="${LAUNCH_APP:-0}" \
        exec "${PROJECT_DIR}/build_dev.sh"
        ;;
    incremental|fast)
        exec "${PROJECT_DIR}/build_incremental.sh"
        ;;
    *)
        echo "Unknown build profile: ${PROFILE}"
        echo "Valid profiles: dev, full, dmg, incremental (or fast)"
        exit 1
        ;;
esac
