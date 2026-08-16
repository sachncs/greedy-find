#!/usr/bin/env bash
# scripts/check_toolchain.sh — verifies that the build prerequisites for
# greedyfind are present. Exits non-zero with a clear message if not.
#
# Required:
#   - macOS 14+ (Sonoma) for metal3.0 support
#   - Xcode (full install — CommandLineTools alone is insufficient)
#   - cmake >= 3.25
#
# Tested on macOS 26 with Xcode 16+. Also works on older Xcode that ships
# the metal3.0 compiler.

set -euo pipefail

GRD_RED='\033[0;31m'
GRD_YELLOW='\033[0;33m'
GRD_GREEN='\033[0;32m'
GRD_NC='\033[0m'

fail() {
  printf "${GRD_RED}[FAIL]${GRD_NC} %s\n" "$1" >&2
  exit 1
}

warn() {
  printf "${GRD_YELLOW}[WARN]${GRD_NC} %s\n" "$1" >&2
}

ok() {
  printf "${GRD_GREEN}[OK]${GRD_NC}   %s\n" "$1"
}

# 1. macOS version ----------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "greedyfind builds only on macOS (got $(uname -s))."
fi
ok "Running on macOS ($(sw_vers -productVersion))"

# 2. Xcode full install -----------------------------------------------------
# CommandLineTools alone is not sufficient — the Metal compiler ships only
# with full Xcode. Detect by looking for the Metal compiler.
if ! command -v xcrun >/dev/null 2>&1; then
  fail "xcrun not found. Install Xcode from the App Store and run
  'xcode-select --install' if needed."
fi

XCODE_PATH="$(xcode-select -p 2>/dev/null || true)"
if [[ -z "${XCODE_PATH}" || "${XCODE_PATH}" == *CommandLineTools* ]]; then
  warn "Active developer dir is CommandLineTools only: ${XCODE_PATH:-unset}"
  warn "Full Xcode is required for the Metal compiler."
fi

if ! xcrun --find metal >/dev/null 2>&1; then
  fail "'xcrun metal' not found. Install full Xcode from the App Store:
    https://apps.apple.com/app/xcode/id497799835
After install, run:
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
and re-run this script."
fi

METAL_PATH="$(xcrun --find metal)"
ok "Found Metal compiler: ${METAL_PATH}"

if ! xcrun --find metallib >/dev/null 2>&1; then
  fail "'xcrun metallib' not found. Reinstall Xcode."
fi
ok "Found metallib: $(xcrun --find metallib)"

# 3. cmake ------------------------------------------------------------------
if ! command -v cmake >/dev/null 2>&1; then
  fail "cmake not found. Install via 'brew install cmake' (requires >=3.25)."
fi

CMAKE_VERSION="$(cmake --version | head -n1 | awk '{print $3}')"
CMAKE_MAJOR="$(printf '%s' "${CMAKE_VERSION}" | cut -d. -f1)"
CMAKE_MINOR="$(printf '%s' "${CMAKE_VERSION}" | cut -d. -f2)"

if (( CMAKE_MAJOR < 3 )) || \
   (( CMAKE_MAJOR == 3 && CMAKE_MINOR < 25 )); then
  fail "cmake >= 3.25 required, found ${CMAKE_VERSION}. Upgrade via
  'brew upgrade cmake' or install a newer version."
fi
ok "cmake ${CMAKE_VERSION}"

# 4. git author -------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "${REPO_ROOT}" ]]; then
  AUTHOR_NAME="$(git config --local --get user.name || true)"
  AUTHOR_EMAIL="$(git config --local --get user.email || true)"
  if [[ "${AUTHOR_NAME}" != "sachin" || "${AUTHOR_EMAIL}" != "sachncs@gmail.com" ]]; then
    warn "Local git author not set to sachin <sachncs@gmail.com>."
    warn "Found: '${AUTHOR_NAME} <${AUTHOR_EMAIL}>'."
    warn "Fix via:"
    warn "  git config --local user.name sachin"
    warn "  git config --local user.email sachncs@gmail.com"
  else
    ok "Local git author: ${AUTHOR_NAME} <${AUTHOR_EMAIL}>"
  fi
fi

# 5. clang-format (style gate) ---------------------------------------------
if ! command -v clang-format >/dev/null 2>&1; then
  warn "clang-format not found. Style gate (Gate 2) will be skipped."
  warn "Install via 'brew install clang-format' (version >=14 recommended)."
else
  CF_VERSION="$(clang-format --version | awk '{print $3}')"
  ok "clang-format ${CF_VERSION}"
fi

printf "${GRD_GREEN}[OK]${GRD_NC} Toolchain check passed.\n"