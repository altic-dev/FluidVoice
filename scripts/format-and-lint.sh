#!/bin/bash
# Pre-commit hook to format and lint code
# To install: cp scripts/format-and-lint.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [ -t 1 ]; then
  RED="$(tput setaf 1)"
  YELLOW="$(tput setaf 3)"
  GREEN="$(tput setaf 2)"
  BLUE="$(tput setaf 4)"
  BOLD="$(tput bold)"
  RESET="$(tput sgr0)"
else
  RED=""; YELLOW=""; GREEN=""; BLUE=""; BOLD=""; RESET=""
fi

die() {
  echo "${RED}${BOLD}Error:${RESET} $*" >&2
  exit 1
}

ensure_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew is required to auto-install tools. Install from https://brew.sh/ or install the tools manually."
  fi
}

ensure_tool() {
  local tool="$1"
  local brew_pkg="$2"

  if command -v "$tool" >/dev/null 2>&1; then
    return 0
  fi

  if [ "${FLUIDVOICE_NO_TOOL_INSTALL:-0}" = "1" ]; then
    die "Missing dependency: '$tool' (auto-install disabled via FLUIDVOICE_NO_TOOL_INSTALL=1)."
  fi

  ensure_brew
  echo "${BLUE}${BOLD}Installing${RESET} missing dependency: ${BOLD}${tool}${RESET} (brew install ${brew_pkg})"
  brew install "$brew_pkg"

  command -v "$tool" >/dev/null 2>&1 || die "Failed to install '$tool' (brew package: '$brew_pkg')."
}

ensure_tool swiftformat swiftformat
ensure_tool swiftlint swiftlint

echo "${BLUE}${BOLD}Running SwiftFormat...${RESET}"
swiftformat --config .swiftformat Sources

# If swiftformat changed files, fail so the user can review + stage the formatting changes.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git diff --name-only -- Sources | grep -q .; then
    echo "${YELLOW}${BOLD}SwiftFormat updated files.${RESET} Please stage the changes and re-commit:"
    git diff --name-only -- Sources | sed 's/^/ - /'
    exit 1
  fi
fi

echo "${BLUE}${BOLD}Running SwiftLint...${RESET}"
tmpfile="$(mktemp -t fluidvoice-swiftlint.XXXXXX)"

trap 'rm -f "$tmpfile"' EXIT

set +e
swiftlint --strict --config .swiftlint.yml >"$tmpfile" 2>&1
swiftlint_exit=$?
set -e

if [ "$swiftlint_exit" -ne 0 ]; then
  echo "${RED}${BOLD}SwiftLint failed.${RESET}"
  echo

  # Beautify SwiftLint output: group by file, show line + severity + message, include counts.
  awk -v RED="$RED" -v YELLOW="$YELLOW" -v BOLD="$BOLD" -v RESET="$RESET" '
    BEGIN { current=""; errors=0; warnings=0; other=0 }
    function print_header(file) {
      current=file
      print BOLD file RESET
    }
    {
      # Typical SwiftLint line:
      # path/to/File.swift:12:34: error: Message...
      if (match($0, /^(.*):([0-9]+):([0-9]+): (warning|error): (.*)$/, a)) {
        file=a[1]; line=a[2]; sev=a[4]; msg=a[5]
        if (file != current) print_header(file)
        if (sev == "error") { c=RED; errors++ } else { c=YELLOW; warnings++ }
        printf("  L%s: %s%s%s: %s\n", line, c, sev, RESET, msg)
        next
      }

      # Keep any other lines (tooling errors, config issues, etc.)
      other++
      if (current != "__misc__") { print_header("__misc__"); }
      print "  " $0
    }
    END {
      print ""
      summary = sprintf("Summary: %d error(s), %d warning(s)", errors, warnings)
      if (other > 0) summary = summary sprintf(", %d other line(s)", other)
      print BOLD summary RESET > "/dev/stderr"
    }
  ' "$tmpfile"

  exit "$swiftlint_exit"
fi

echo "${GREEN}${BOLD}OK${RESET} - formatting and linting passed."
exit 0