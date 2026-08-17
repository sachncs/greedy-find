#!/usr/bin/env bash
# scripts/differential.sh — runs greedyfind and the find crate on
# the same target and range, then diffs the matches. Exits non-zero
# on any difference.
#
# Usage:
#   bash scripts/differential.sh
#
# Requires:
#   - ./build/greedyfind (built)
#   - find Rust crate installed (cargo install find, or
#     /path/to/find binary via FIND_BIN env var)
#   - secp256k1 EC machinery on both sides (greedyfind has it
#     bundled; the find crate uses its own k256 path).
#
# Scope: the comparison is for the *outputs* of the two tools, not
# the implementation. A differential mismatch is a real bug; a
# match does not prove the search is exhaustive, only that both
# implementations agreed on the candidates they did emit.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
GRD="${BUILD_DIR}/greedyfind"
FIND_BIN="${FIND_BIN:-find}"

if [[ ! -x "${GRD}" ]]; then
  printf "[differential] greedyfind not built at %s; abort\n" "${GRD}" >&2
  exit 1
fi

if ! command -v "${FIND_BIN}" >/dev/null 2>&1; then
  printf "[differential] find crate binary '%s' not on PATH; set " \
         "FIND_BIN to override\n" "${FIND_BIN}" >&2
  exit 1
fi

# A known small test case: d=1 (privkey), G, sweep [0, 16).
PUBKEY_HEX="0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"
RANGE_FROM="0"
RANGE_TO="16"

GRD_OUT="$(mktemp -t grd-diff.XXXXXX)"
FIND_OUT="$(mktemp -t find-diff.XXXXXX)"
trap 'rm -f "${GRD_OUT}" "${FIND_OUT}"' EXIT

"${GRD}" --pubkey "${PUBKEY_HEX}" --from "${RANGE_FROM}" --to "${RANGE_TO}" \
    >"${GRD_OUT}" 2>&1 || true
"${FIND_BIN}" --pubkey "${PUBKEY_HEX}" --from "${RANGE_FROM}" --to "${RANGE_TO}" \
    >"${FIND_OUT}" 2>&1 || true

# Both tools should print at least d=1 (j=1, V=0) in --pubkey mode.
# Compare only the match lines (lines beginning with 'MATCH ' or the
# tool's equivalent), sorted.
grd_matches="$(grep -E 'MATCH|match' "${GRD_OUT}" | sort -u || true)"
find_matches="$(grep -E 'MATCH|match' "${FIND_OUT}" | sort -u || true)"

if [[ -z "${grd_matches}" ]]; then
  printf "[differential] greedyfind produced no matches (unexpected)\n" >&2
  cat "${GRD_OUT}" >&2
  exit 1
fi

if [[ "${grd_matches}" != "${find_matches}" ]]; then
  printf "[differential] match set differs:\n" >&2
  diff <(printf "%s\n" "${grd_matches}") \
       <(printf "%s\n" "${find_matches}") >&2 || true
  exit 1
fi

printf "[differential] ok: %d unique match line(s) agreed\n" \
       "$(printf "%s\n" "${grd_matches}" | wc -l | tr -d ' ')"
