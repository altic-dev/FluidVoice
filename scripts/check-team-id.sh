#!/bin/bash
# Pre-commit hook to warn about potential team ID changes
# To install: cp scripts/check-team-id.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

# Your official team ID
OFFICIAL_TEAM_ID="V4J43B279J"

# Check if project.pbxproj has been modified
if git diff --cached --name-only | grep -q "project.pbxproj"; then
  echo "⚠️  Warning: project.pbxproj is being committed"
  
  # Check for team ID changes
  if git diff --cached Fluid.xcodeproj/project.pbxproj | grep -q "DEVELOPMENT_TEAM"; then
    echo "❌ ERROR: DEVELOPMENT_TEAM changes detected in project.pbxproj"
    echo ""
    echo "Team ID changes should NOT be committed."
    echo "The official team ID is: $OFFICIAL_TEAM_ID"
    echo ""
    echo "To fix:"
    echo "  1. Unstage the file: git reset HEAD Fluid.xcodeproj/project.pbxproj"
    echo "  2. Discard team ID changes in Xcode"
    echo "  3. Stage only your intended changes"
    echo ""
    echo "To override this check (only if you're sure): git commit --no-verify"
    exit 1
  fi
fi

exit 0
