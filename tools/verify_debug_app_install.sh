#!/bin/zsh

set -euo pipefail

readonly installed_app="/Applications/FluidVoice Debug.app"
readonly expected_bundle_id="com.FluidApp.app"
readonly expected_team_id="A8467RRA3D"
readonly expected_identity_sha1="8A2AE80FFC8995026892FACDBBF76C4677A0117F"

if (( $# != 1 )); then
    print -u2 "usage: $0 /absolute/path/to/FluidVoice\\ Debug.app"
    exit 64
fi

readonly candidate_app="$1"
if [[ "$candidate_app" != /* || ! -d "$candidate_app" || -L "$candidate_app" ]]; then
    print -u2 "candidate must be an existing, absolute, non-symlink app bundle"
    exit 65
fi
if [[ ! -d "$installed_app" || -L "$installed_app" ]]; then
    print -u2 "installed FluidVoice Debug app is missing or is a symlink"
    exit 66
fi

if ! /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -Fq "$expected_identity_sha1"; then
    print -u2 "expected FluidVoice signing identity is not available"
    exit 67
fi

verify_strict() {
    local app="$1"
    local output
    if ! output=$(/usr/bin/codesign --verify --deep --strict --verbose=2 "$app" 2>&1); then
        print -u2 -- "$output"
        print -u2 "strict verification failed. If this is CSSMERR_TP_NOT_TRUSTED inside a restricted agent sandbox, rerun this preflight with host securityd/trustd access before changing keychain or trust settings."
        return 1
    fi
}

signature_field() {
    local app="$1"
    local field="$2"
    /usr/bin/codesign -dv --verbose=4 "$app" 2>&1 \
        | /usr/bin/sed -n "s/^${field}=//p"
}

designated_requirement() {
    /usr/bin/codesign -d -r- "$1" 2>&1 \
        | /usr/bin/sed -n 's/^designated => //p'
}

verify_strict "$candidate_app"
verify_strict "$installed_app"

readonly candidate_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate_app/Contents/Info.plist")
readonly installed_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")
readonly candidate_team_id=$(signature_field "$candidate_app" TeamIdentifier)
readonly installed_team_id=$(signature_field "$installed_app" TeamIdentifier)
readonly candidate_requirement=$(designated_requirement "$candidate_app")
readonly installed_requirement=$(designated_requirement "$installed_app")

if [[ "$candidate_bundle_id" != "$expected_bundle_id" \
    || "$installed_bundle_id" != "$expected_bundle_id" ]]; then
    print -u2 "bundle identifier mismatch"
    exit 68
fi
if [[ "$candidate_team_id" != "$expected_team_id" \
    || "$installed_team_id" != "$expected_team_id" ]]; then
    print -u2 "Team ID mismatch"
    exit 69
fi
if [[ -z "$candidate_requirement" || "$candidate_requirement" != "$installed_requirement" ]]; then
    print -u2 "designated requirement mismatch"
    exit 70
fi

print "FluidVoice Debug install preflight passed"
print "bundleIdentifier=$candidate_bundle_id"
print "teamIdentifier=$candidate_team_id"
print "candidateCDHash=$(signature_field "$candidate_app" CDHash)"
print "installedCDHash=$(signature_field "$installed_app" CDHash)"
