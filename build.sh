#!/bin/bash

# FluidVoice Build Profile Router
# Defaults to the public OSS build, which skips private Fluid Intelligence.
#
# Usage:
#   ./build.sh                    # signed public OSS build
#   ./build.sh public             # signed public OSS build
#   ./build.sh unsigned           # unsigned public OSS build (CI/fallback)
#   ./build.sh fi                 # private FI build

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${1:-${BUILD_PROFILE:-public}}"
PRIVATE_FI_BUILD_SCRIPT="${PROJECT_DIR}/build_with_FI_incremental.sh"
DERIVED_DATA_PATH="${FLUIDVOICE_DERIVED_DATA_PATH:-${PROJECT_DIR}/DerivedData}"

resolve_development_team() {
    local identity
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | awk 'NR == 1 { identity = $0 } END { print identity }')"
    [ -n "${identity}" ] || return 0

    if [ -n "${FLUIDVOICE_DEVELOPMENT_TEAM:-}" ]; then
        printf '%s\n' "${FLUIDVOICE_DEVELOPMENT_TEAM}"
        return
    fi

    security find-certificate -c "${identity}" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -n 's/.*OU=\([^,]*\).*/\1/p'
}

resolve_development_identity_hash() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.* \([[:xdigit:]]\{40\}\) "Apple Development:[^"]*".*/\1/p' \
        | awk 'NR == 1 { print; exit }'
}

replace_with_symlink() {
    local path="$1"
    local target="$2"

    if [ -L "${path}" ] || [ -f "${path}" ]; then
        rm -f "${path}"
    elif [ -d "${path}" ]; then
        rm -R "${path}"
    elif [ -e "${path}" ]; then
        echo "Unexpected file type at ${path}" >&2
        return 1
    fi

    ln -s "${target}" "${path}"
}

run_public_build() {
    local signing_mode="$1"
    local development_team
    local signing_identity_hash
    local app_path
    local ctranscribe_framework
    local ctranscribe_versions
    local ctranscribe_version_a
    local ctranscribe_version_a_binary
    local ctranscribe_version_a_resources
    local ctranscribe_current
    local ctranscribe_root_binary
    local ctranscribe_root_resources
    local entitlements_file
    local -a build_args=(
        -project Fluid.xcodeproj
        -scheme Fluid
        -configuration Debug
        -destination 'platform=macOS'
        -derivedDataPath "${DERIVED_DATA_PATH}"
        build
    )

    cd "${PROJECT_DIR}"

    if [ "${signing_mode}" = "unsigned" ]; then
        echo "Running unsigned public FluidVoice build..."
        echo "Accessibility, Screen Recording, and microphone permissions may need to be granted again after rebuilding."
        exec xcodebuild "${build_args[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
    fi

    signing_identity_hash="$(resolve_development_identity_hash)"
    development_team="$(resolve_development_team)"
    if [ -z "${development_team}" ]; then
        if [ -n "${FLUIDVOICE_DEVELOPMENT_TEAM:-}" ]; then
            printf >&2 'FLUIDVOICE_DEVELOPMENT_TEAM is set to %s, but no Apple Development signing identity was found.\n\n' \
                "${FLUIDVOICE_DEVELOPMENT_TEAM}"
            printf >&2 '%s\n\n' \
                "The team override selects an installed signing identity; it does not replace a certificate."
        else
            printf >&2 'No Apple Development signing identity was found.\n\n'
        fi

        cat >&2 <<'EOF'
For stable Accessibility permission across rebuilds, add any Apple Account in:
  Xcode > Settings > Accounts

Then open Manage Certificates and create an Apple Development certificate.

A free Personal Team is sufficient for local development. If you have multiple
teams, set FLUIDVOICE_DEVELOPMENT_TEAM to the desired 10-character Team ID.

To build without signing instead, run:
  ./build.sh unsigned

Unsigned builds may require Accessibility, Screen Recording, and microphone permissions again after rebuilding.
EOF
        exit 1
    fi

    if [ -z "${signing_identity_hash}" ]; then
        echo "Unable to resolve the Apple Development signing identity hash." >&2
        exit 1
    fi

    echo "Running signed public FluidVoice build..."
    echo "Build product: ${DERIVED_DATA_PATH}/Build/Products/Debug/FluidVoice Debug.app"
    xcodebuild "${build_args[@]}" DEVELOPMENT_TEAM="${development_team}"

    app_path="${DERIVED_DATA_PATH}/Build/Products/Debug/FluidVoice Debug.app"
    ctranscribe_framework="${app_path}/Contents/Frameworks/CTranscribe.framework"
    if [ ! -d "${app_path}" ]; then
        echo "Signed build product is missing: ${app_path}" >&2
        exit 1
    fi
    if [ ! -d "${ctranscribe_framework}" ]; then
        echo "Signed CTranscribe framework is missing: ${ctranscribe_framework}" >&2
        exit 1
    fi

    ctranscribe_versions="${ctranscribe_framework}/Versions"
    ctranscribe_version_a="${ctranscribe_versions}/A"
    ctranscribe_version_a_binary="${ctranscribe_version_a}/CTranscribe"
    ctranscribe_version_a_resources="${ctranscribe_version_a}/Resources"
    ctranscribe_current="${ctranscribe_versions}/Current"
    ctranscribe_root_binary="${ctranscribe_framework}/CTranscribe"
    ctranscribe_root_resources="${ctranscribe_framework}/Resources"
    if [ ! -d "${ctranscribe_versions}" ] || [ -L "${ctranscribe_versions}" ]; then
        echo "CTranscribe.framework has no regular Versions directory: ${ctranscribe_versions}" >&2
        exit 1
    fi
    if [ ! -d "${ctranscribe_version_a}" ] || [ -L "${ctranscribe_version_a}" ]; then
        echo "CTranscribe.framework has no regular Versions/A directory: ${ctranscribe_version_a}" >&2
        exit 1
    fi
    if [ ! -f "${ctranscribe_version_a_binary}" ] || [ -L "${ctranscribe_version_a_binary}" ]; then
        echo "CTranscribe.framework Versions/A/CTranscribe is not a regular file: ${ctranscribe_version_a_binary}" >&2
        exit 1
    fi
    if [ ! -d "${ctranscribe_version_a_resources}" ] || [ -L "${ctranscribe_version_a_resources}" ]; then
        echo "CTranscribe.framework Versions/A/Resources is not a regular directory: ${ctranscribe_version_a_resources}" >&2
        exit 1
    fi

    echo "Normalizing CTranscribe.framework layout..."
    replace_with_symlink "${ctranscribe_current}" "A"
    replace_with_symlink "${ctranscribe_root_binary}" "Versions/Current/CTranscribe"
    replace_with_symlink "${ctranscribe_root_resources}" "Versions/Current/Resources"

    echo "Re-sealing CTranscribe.framework with the resolved Apple Development identity..."
    codesign --force --sign "${signing_identity_hash}" \
        --options runtime --timestamp=none \
        --preserve-metadata=identifier,requirements,flags "${ctranscribe_framework}"

    entitlements_file="$(mktemp -t fluidvoice-entitlements)"
    if ! codesign --display --entitlements :- "${app_path}" > "${entitlements_file}" 2>/dev/null; then
        rm -f "${entitlements_file}"
        echo "Unable to read existing app entitlements: ${app_path}" >&2
        exit 1
    fi

    echo "Re-signing the app while preserving its existing entitlements..."
    if [ -s "${entitlements_file}" ]; then
        if ! codesign --force --sign "${signing_identity_hash}" \
            --options runtime --timestamp=none \
            --preserve-metadata=identifier,requirements,flags \
            --entitlements "${entitlements_file}" "${app_path}"; then
            rm -f "${entitlements_file}"
            echo "Unable to re-sign the app: ${app_path}" >&2
            exit 1
        fi
    else
        if ! codesign --force --sign "${signing_identity_hash}" \
            --options runtime --timestamp=none \
            --preserve-metadata=identifier,requirements,flags "${app_path}"; then
            rm -f "${entitlements_file}"
            echo "Unable to re-sign the app: ${app_path}" >&2
            exit 1
        fi
    fi
    rm -f "${entitlements_file}"

    echo "Verifying the signed app..."
    codesign --verify --deep --strict "${app_path}"
}

case "${PROFILE}" in
    public|oss|incremental|fast)
        run_public_build signed
        ;;
    unsigned|ci)
        run_public_build unsigned
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
        echo "Valid profiles: public/oss/incremental/fast, unsigned/ci, fi/private/dev/full"
        exit 1
        ;;
esac
