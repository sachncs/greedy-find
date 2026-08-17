#!/usr/bin/env bash
# scripts/run_kat.sh — runs every KAT (tests/kat/*) and prints a
# one-line summary. Exits non-zero on the first failure.
#
# Usage:
#   bash scripts/run_kat.sh
#
# Re-uses the existing CMake build at ./build. Re-builds if missing.
# The bench binary is not part of this gate.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"

if [[ ! -d "${BUILD_DIR}" ]]; then
  printf "[run_kat] build/ missing; running cmake -S . -B build\n"
  cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" >&2
fi

printf "[run_kat] building KATs\n"
cmake --build "${BUILD_DIR}" --target address_kat \
                                   cache_kat \
                                   checkpoint_kat \
                                   ec_kat \
                                   field_kat \
                                   hash_kat \
                                   load_balance_kat \
                                   telemetry_kat \
                                   variant_kat >&2

printf "[run_kat] running KATs\n"
failures=0
while IFS= read -r -d '' kat; do
  name="$(basename "${kat}")"
  name="${name%.*}"
  if "${BUILD_DIR}/${name}" >/dev/null 2>&1; then
    printf "  [PASS] %s\n" "${name}"
  else
    printf "  [FAIL] %s\n" "${name}"
    failures=$((failures + 1))
  fi
done < <(find "${REPO_ROOT}/tests/kat" -maxdepth 1 -type f \
            \( -name '*.c' -o -name '*.m' \) \
            -print0 | sort -z)

if (( failures > 0 )); then
  printf "[run_kat] %d KAT(s) failed\n" "${failures}" >&2
  exit 1
fi
printf "[run_kat] all KATs passed\n"
