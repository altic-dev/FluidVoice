#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_FILE="${PROJECT_DIR}/Fluid.xcodeproj"
SCHEME="Fluid"
DESTINATION="platform=macOS"
BUILD_DIR="${PROJECT_DIR}/build"

usage() {
    echo "Usage: ./build.new.sh [-i] [-l] [dev|release|clean]"
    echo "Options:"
    echo "  -i    Install built app into /Applications"
    echo "  -l    Launch app after build (or after install if -i is set)"
    echo "Profiles:"
    echo "  dev      Debug, incremental build for development"
    echo "  release  Optimized build for production/release"
    echo "  clean    Delete generated build artifacts"
}

INSTALL_APP=0
LAUNCH_APP=0
PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i)
            INSTALL_APP=1
            ;;
        -l)
            LAUNCH_APP=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        dev|release|clean)
            if [[ -n "${PROFILE}" ]]; then
                echo "Only one profile may be provided."
                usage
                exit 1
            fi
            PROFILE="$1"
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [[ -z "${PROFILE}" ]]; then
    usage
    exit 1
fi

case "${PROFILE}" in
    dev)
        CONFIGURATION="Debug"
        SWIFT_COMPILATION_MODE="incremental"
        ;;
    release)
        CONFIGURATION="Release"
        SWIFT_COMPILATION_MODE="wholemodule"
        ;;
    clean)
        rm -rf "${BUILD_DIR}"
        echo "Deleted build artifacts: ${BUILD_DIR}"
        exit 0
        ;;
    *)
        echo "Unknown profile: ${PROFILE}"
        echo "Valid profiles: dev, release, clean"
        exit 1
        ;;
esac

CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
CODE_SIGNING_REQUIRED="${CODE_SIGNING_REQUIRED:-NO}"

mkdir -p "${BUILD_DIR}"

xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" \
    build \
    CONFIGURATION_BUILD_DIR="${BUILD_DIR}" \
    SWIFT_COMPILATION_MODE="${SWIFT_COMPILATION_MODE}" \
    CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED}" \
    CODE_SIGNING_REQUIRED="${CODE_SIGNING_REQUIRED}"

if [[ "${CONFIGURATION}" == "Debug" ]]; then
    APP_PATH="${BUILD_DIR}/FluidVoice Debug.app"
else
    APP_PATH="${BUILD_DIR}/FluidVoice.app"
fi

echo "App bundle: ${APP_PATH}"

if [[ "${INSTALL_APP}" == "1" ]]; then
    APP_NAME="$(basename "${APP_PATH}")"
    INSTALL_PATH="/Applications/${APP_NAME}"
    rsync -a --delete "${APP_PATH}/" "${INSTALL_PATH}/"
    APP_PATH="${INSTALL_PATH}"
    echo "Installed app bundle: ${APP_PATH}"
fi

if [[ "${LAUNCH_APP}" == "1" ]]; then
    open -n "${APP_PATH}"
    echo "Launched app bundle: ${APP_PATH}"
fi
