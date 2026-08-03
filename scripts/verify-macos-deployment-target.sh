#!/bin/bash
set -euo pipefail

# This script verifies that all Mach-O binaries in an app bundle
# have a minimum macOS deployment target of 14.0 or lower.

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_app_bundle>"
    exit 1
fi

APP_BUNDLE="$1"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: App bundle not found at $APP_BUNDLE"
    exit 1
fi

echo "Verifying deployment targets for: $APP_BUNDLE"

FAILED=0
MAX_ALLOWED_MAJOR=14

# Find all Mach-O files
# We look for files with 'file' command to be robust.
while read -r FILE; do
    # Skip files that are clearly not binaries (e.g., .plist, .strings, .png)
    case "$FILE" in
        *.plist|*.strings|*.png|*.icns|*.json|*.txt|*.h|*.modulemap) continue ;;
    esac

    # Check if it's a Mach-O file
    if file "$FILE" | grep -q "Mach-O"; then
        echo "Checking: $FILE"

        # Extract minimum OS version using vtool
        MIN_OS=$(vtool -show-build "$FILE" 2>/dev/null | grep "minos" | awk '{print $2}' | head -n 1)

        if [ -z "$MIN_OS" ]; then
            # Try otool as fallback for older formats
            MIN_OS=$(otool -l "$FILE" 2>/dev/null | grep -A 3 "LC_VERSION_MIN_MACOSX" | grep "version" | awk '{print $2}' | head -n 1)
        fi

        if [ -n "$MIN_OS" ]; then
            echo "  Minimum OS: $MIN_OS"
            MAJOR_VERSION=$(echo "$MIN_OS" | cut -d. -f1)
            if [ "$MAJOR_VERSION" -gt "$MAX_ALLOWED_MAJOR" ]; then
                echo "  FAILED: Minimum OS $MIN_OS exceeds macOS $MAX_ALLOWED_MAJOR"
                FAILED=1
            fi
        else
            echo "  Warning: Could not determine minimum OS for $FILE"
        fi
    fi
done < <(find "$APP_BUNDLE" -type f)

if [ $FAILED -ne 0 ]; then
    echo "Verification FAILED: One or more binaries require macOS > $MAX_ALLOWED_MAJOR"
    exit 1
else
    echo "Verification PASSED: All binaries are compatible with macOS $MAX_ALLOWED_MAJOR"
fi
